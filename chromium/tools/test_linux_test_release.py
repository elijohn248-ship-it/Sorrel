"""Release checks using synthetic packages and a local GitHub API double."""
from argparse import Namespace
import base64
import hashlib
import hmac
from io import BytesIO
import json
from pathlib import Path
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from zipfile import ZipFile

import linux_test_release as release

REVISION = "b" * 40
BRANCH = "codex/linux-test-updater"
MOCK_KEY = b"fixture signer used only on Linux"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def tar(entries):
    result = BytesIO()
    with tarfile.open(fileobj=result, mode="w:xz") as archive:
        for name, (content, mode) in entries.items():
            entry = tarfile.TarInfo(name)
            entry.mode = mode
            entry.size = len(content)
            archive.addfile(entry, BytesIO(content))
    return result.getvalue()


def ar_member(name, data):
    header = f"{name:<16}{0:<12}{0:<6}{0:<6}{100644:<8}{len(data):<10}`\n"
    return header.encode() + data + (b"\n" if len(data) % 2 else b"")


def artifact(build):
    config = release.config(build, REVISION)
    control = f"Package: {release.NAME}\nArchitecture: amd64\nVersion: {config['version']}\n"
    package = (
        b"!<arch>\n" + ar_member("debian-binary", b"2.0\n")
        + ar_member("control.tar.xz", tar({"./control": (control.encode(), 0o644)}))
        + ar_member("data.tar.xz", tar({
            f"./opt/{release.NAME}/update-config.json": (release.canonical(config), 0o644),
            f"./opt/{release.NAME}/linux-updater.py": (b"fixture", 0o755),
        }))
    )
    result = BytesIO()
    with ZipFile(result, "w") as archive:
        archive.writestr(release.PACKAGE_FILE, package)
        archive.writestr("build-info.json", release.canonical({
            **config, "sha256": digest(package), "size": len(package),
        }))
    return result.getvalue()


class FakeGitHub:
    def __init__(self):
        self.artifacts = {}
        self.releases = {}
        self.contents = {}
        self.events = []
        self.fail_promotion = False

    def json(self, path, method="GET", obj=None, missing_ok=False):
        if path.startswith("/actions/runs/"):
            build = int(path.split("/")[3])
            if "/artifacts?" in path:
                data = self.artifacts[build]
                return {"total_count": 1, "artifacts": [{
                    "id": build, "name": release.ARTIFACT, "expired": False,
                    "size_in_bytes": len(data), "digest": f"sha256:{digest(data)}",
                }]}
            return {
                "id": build, "head_sha": REVISION, "head_branch": BRANCH,
                "path": release.WORKFLOW, "event": "push", "status": "completed",
                "conclusion": "success", "head_repository": {"full_name": release.REPOSITORY},
            }
        if path.startswith("/git/ref/tags/"):
            item = self.releases.get(path.rsplit("/", 1)[1])
            if item and not item["draft"]:
                return {"object": {"type": "commit", "sha": item["target_commitish"]}}
            return None
        assert method == "PATCH" and path.startswith("/releases/")
        assert obj == {"draft": False, "prerelease": True, "make_latest": "false"}
        item = next(item for item in self.releases.values() if str(item["id"]) == path.split("/")[-1])
        item.update(obj)
        self.events.append(("published-release", item["tag_name"]))

    def request(self, url, *, authenticated=True):
        if url.startswith(release.API + "/actions/artifacts/"):
            assert authenticated
            return BytesIO(self.artifacts[int(url.split("/")[-2])])
        assert not authenticated and url.startswith(release.DOWNLOAD_ROOT + "/")
        tag, name = url.removeprefix(release.DOWNLOAD_ROOT + "/").split("/")
        self.events.append(("public-read", name))
        return BytesIO(self.read_feed_asset(self.assets(self.releases[tag])[name]))

    def release(self, tag, *, find_draft=False):
        return self.releases.get(tag)

    def create_release(self, tag, revision, title, notes, *, draft):
        item = {"id": len(self.releases) + 1, "tag_name": tag, "target_commitish": revision,
                "draft": draft, "prerelease": True, "assets": {}}
        self.releases[tag] = item
        self.events.append(("created-release", tag))
        return item

    def assets(self, item):
        return item["assets"]

    def upload(self, item, path, name, content_type):
        data = path.read_bytes()
        identifier = len(self.contents) + 1
        self.contents[identifier] = data
        asset = {"id": identifier, "name": name, "size": len(data),
                 "digest": f"sha256:{digest(data)}", "state": "uploaded"}
        assert name not in item["assets"]
        item["assets"][name] = asset
        self.events.append(("uploaded", name))
        return asset

    def read_feed_asset(self, asset):
        return self.contents[asset["id"]]

    def rename(self, asset, name):
        if self.fail_promotion and asset["name"] == release.PENDING_FEED and name == release.FEED_NAME:
            raise OSError("simulated feed rename failure")
        items = self.releases[release.FEED_TAG]["assets"]
        del items[asset["name"]]
        items[name] = {**asset, "name": name}
        self.events.append(("renamed", name))

    def delete(self, asset):
        del self.releases[release.FEED_TAG]["assets"][asset["name"]]


def mock_signer(operation, *args):
    paths = {flag: Path(value) for flag, value in zip(args[::2], args[1::2])}
    if operation == "public":
        paths["--public"].write_bytes(MOCK_KEY)
        return
    payload = paths["--input"].read_bytes()
    signature = hmac.digest(MOCK_KEY, payload, "sha512")
    if operation == "verify":
        if not hmac.compare_digest(signature, paths["--signature"].read_bytes()):
            raise ValueError("Invalid fixture signature")
        return
    assert operation == "sign"
    paths["--output"].write_bytes(release.canonical({
        "format": 1,
        "payload": base64.b64encode(payload).decode(),
        "signature": base64.b64encode(signature).decode(),
    }))


class ReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temp = tempfile.TemporaryDirectory(prefix="birch-release-tests-")
        cls.addClassCleanup(temp.cleanup)
        cls.scratch = Path(temp.name)
        cls.key = cls.scratch / "linux-test-update-signing-key"
        cls.public_key = cls.scratch / "test-public.pem"
        if sys.platform == "darwin":
            executable = cls.scratch / "signer"
            subprocess.run([
                "/usr/bin/swiftc", "-warnings-as-errors", "-module-cache-path",
                str(cls.scratch / "module-cache"), str(release.SIGNER), "-o", str(executable),
            ], check=True)
            cls.sign = staticmethod(lambda *args: subprocess.run(
                [executable, *map(str, args)], check=True, capture_output=True))
            cls.sign("init", "--key", cls.key, "--public", cls.public_key)
        else:
            cls.sign = staticmethod(mock_signer)
            cls.public_key.write_bytes(MOCK_KEY)

    def setUp(self):
        self.github = FakeGitHub()
        temp = tempfile.TemporaryDirectory(dir=self.scratch)
        self.addCleanup(temp.cleanup)
        self.folder = Path(temp.name)
        for key, value in {"PUBLIC_KEY": self.public_key, "signer": self.sign,
                           "api_client": lambda: self.github}.items():
            patcher = patch.object(release, key, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def prepare(self, build):
        self.github.artifacts[build] = artifact(build)
        directory = self.folder / str(build)
        release.prepare(Namespace(run=build, key=self.key, out=directory,
                                  branch=BRANCH, revision=REVISION))
        return directory

    def feed_build(self):
        feed = self.github.assets(self.github.release(release.FEED_TAG))[release.FEED_NAME]
        return release.verified_envelope(self.github.read_feed_asset(feed))["build"]

    @unittest.skipUnless(sys.platform == "darwin", "CryptoKit signer runs on macOS")
    def test_private_key_mode_and_no_overwrite(self):
        raw = self.key.read_bytes()
        self.assertEqual(len(raw), 32)
        self.assertEqual(stat.S_IMODE(self.key.stat().st_mode), 0o600)
        with self.assertRaises(subprocess.CalledProcessError):
            self.sign("init", "--key", self.key, "--public", self.public_key)
        self.assertEqual(self.key.read_bytes(), raw)

    def test_prepare_is_read_only_and_rejects_signature_tampering(self):
        candidate = self.prepare(101)
        self.assertEqual(self.github.events, [])
        feed = json.loads((candidate / release.FEED_NAME).read_bytes())
        signature = bytearray(base64.b64decode(feed["signature"]))
        signature[0] ^= 1
        feed["signature"] = base64.b64encode(signature).decode()
        with self.assertRaises((ValueError, subprocess.CalledProcessError)):
            release.verified_envelope(release.canonical(feed))

    def test_publish_verifies_public_package_before_promotion(self):
        candidate = self.prepare(101)
        release.publish(Namespace(candidate=candidate))
        self.assertEqual(self.feed_build(), 101)
        self.assertLess(self.github.events.index(("public-read", release.asset_name(101))),
                        self.github.events.index(("renamed", release.FEED_NAME)))
        self.assertEqual(self.github.events[-1], ("public-read", release.FEED_NAME))

    def test_public_package_mismatch_leaves_feed_untouched(self):
        old = self.prepare(101)
        new = self.prepare(102)
        release.publish(Namespace(candidate=old))
        original_request = self.github.request

        def request(url, *, authenticated=True):
            if url.endswith("/" + release.asset_name(102)):
                return BytesIO(b"unexpected package bytes")
            return original_request(url, authenticated=authenticated)

        with patch.object(self.github, "request", side_effect=request):
            with self.assertRaisesRegex(ValueError, "Public Debian package"):
                release.publish(Namespace(candidate=new))
        self.assertEqual(self.feed_build(), 101)

    def test_promotion_failure_preserves_previous_feed_and_can_retry(self):
        old = self.prepare(101)
        new = self.prepare(102)
        release.publish(Namespace(candidate=old))
        self.github.fail_promotion = True
        with self.assertRaisesRegex(OSError, "simulated"):
            release.publish(Namespace(candidate=new))
        self.assertEqual(self.feed_build(), 101)
        self.assertNotIn(release.PENDING_FEED, self.github.assets(self.github.release(release.FEED_TAG)))
        self.github.fail_promotion = False
        release.publish(Namespace(candidate=new))
        with self.assertRaisesRegex(ValueError, "newer build"):
            release.publish(Namespace(candidate=old))
        self.assertEqual(self.feed_build(), 102)

    def test_invalid_json_and_modified_reviewed_manifest_fail_closed(self):
        for data in (b'{"schema":1,"schema":2}', b'{"schema":NaN}', b'{"schema":Infinity}'):
            with self.assertRaises(ValueError):
                release.read_json(data)
        candidate = self.prepare(101)
        manifest = candidate / "manifest.json"
        modified = json.loads(manifest.read_text())
        modified["schema"] = True
        manifest.write_bytes(release.canonical(modified))
        with self.assertRaisesRegex(ValueError, "Reviewed manifest"):
            release.publish(Namespace(candidate=candidate))
        self.assertEqual(self.github.events, [])


if __name__ == "__main__":
    unittest.main()
