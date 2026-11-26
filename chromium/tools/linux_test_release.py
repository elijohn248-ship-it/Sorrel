#!/usr/bin/env python3
"""Prepare a signed Linux test update locally or explicitly publish a reviewed candidate."""
import argparse
import base64
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
from zipfile import BadZipFile, ZipFile

# Python's isolated mode omits the script directory.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from package_linux_test import (
    DOWNLOAD_ROOT, FEED, FEED_NAME, FEED_TAG, IDENTITY, MAX_BUILD, NAME,
    PACKAGE_FILE, REPOSITORY, RESOURCES,
)

WORKFLOW = ".github/workflows/linux-test-updater.yml"
ARTIFACT = "Birch Chromium Test for Zorin and Ubuntu"
PUBLIC_KEY = RESOURCES / "update-public-key.pem"
SIGNER = Path(__file__).with_name("linux-update-sign.swift")
LOCAL_CONFIG = Path.home() / ".config/sorrel"
TOKEN = LOCAL_CONFIG / "github-token"
DEFAULT_KEY = LOCAL_CONFIG / "linux-test-update-signing-key"
API = f"https://api.github.com/repos/{REPOSITORY}"
UPLOADS = f"https://uploads.github.com/repos/{REPOSITORY}/releases"
PENDING_FEED = "updates-linux-test.pending.json"
MAX_PACKAGE = 1024**3
MAX_FEED = 16 * 1024
HEX_SHA = r"[0-9a-f]{40}"
HEX_DIGEST = r"[0-9a-f]{64}"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def whole_number(value, limit):
    return type(value) is int and 0 < value <= limit


def canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def unique_fields(pairs):
    obj = dict(pairs)
    require(len(obj) == len(pairs), "Duplicate JSON field")
    return obj


def invalid_constant(_):
    raise ValueError("Non-JSON numeric constant")


def read_json(data):
    obj = json.loads(data, object_pairs_hook=unique_fields, parse_constant=invalid_constant)
    require(type(obj) is dict, "Expected a JSON object")
    return obj


def read_small(stream, limit=MAX_FEED):
    data = stream.read(limit + 1)
    require(len(data) <= limit, "Input exceeds its size limit")
    return data


def copy_checked(source, target=None, limit=MAX_PACKAGE):
    digest = hashlib.sha256()
    size = 0
    while block := source.read(1024 * 1024):
        size += len(block)
        require(size <= limit, "Download exceeds its size limit")
        digest.update(block)
        if target is not None:
            target.write(block)
    return size, digest.hexdigest()


def tag(build):
    return f"linux-test-{build}"


def asset_name(build):
    return f"Birch-Chromium-Test-linux-x64-{build}.deb"


class SafeRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        require(req.get_method() == "GET" and urlsplit(newurl).scheme == "https",
                "Unexpected GitHub redirect")
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is not None:
            redirected.remove_header("Authorization")
        return redirected


class GitHub:
    def __init__(self, token):
        self.token = token
        self.opener = build_opener(SafeRedirect())

    def request(self, url, *, method="GET", data=None, headers=None, authenticated=True):
        request_headers = {"User-Agent": "Birch-Linux-Test-Release"}
        if authenticated:
            require(url.startswith((API + "/", UPLOADS + "/")), "Unexpected authenticated URL")
            request_headers.update({
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
            })
        request_headers.update(headers or {})
        request = Request(url, data=data, headers=request_headers, method=method)
        return self.opener.open(request, timeout=60)

    def json(self, suffix, method="GET", obj=None, missing_ok=False):
        data = canonical(obj) if obj is not None else None
        headers = {"Content-Type": "application/json"} if data is not None else None
        try:
            with self.request(API + suffix, method=method, data=data, headers=headers) as response:
                if response.status == 204:
                    return None
                return json.loads(read_small(response, 4 * 1024**2))
        except HTTPError as error:
            if missing_ok and error.code == 404:
                return None
            raise

    def upload(self, release, file, name, content_type):
        url = f"{UPLOADS}/{release['id']}/assets?{urlencode({'name': name})}"
        with file.open("rb") as src:
            headers = {"Content-Type": content_type,
                       "Content-Length": str(file.stat().st_size)}
            with self.request(url, method="POST", data=src, headers=headers) as response:
                asset = read_json(read_small(response))
        require(asset["name"] == name and asset["state"] == "uploaded",
                f"GitHub did not accept {name}")
        return asset

    def release(self, release_tag, *, find_draft=False):
        found = self.json(f"/releases/tags/{release_tag}", missing_ok=True)
        # The tag lookup is for published releases. Recover a previous draft if
        # an upload was interrupted before it could be published.
        if found is None and find_draft:
            for page in range(1, 6):
                releases = self.json(f"/releases?per_page=100&page={page}")
                found = next((item for item in releases if item["tag_name"] == release_tag), None)
                if found is not None or len(releases) < 100:
                    break
        if found is not None:
            require(found["tag_name"] == release_tag and found["prerelease"] is True,
                    f"Release {release_tag} is not a Linux test prerelease")
        return found

    def create_release(self, release_tag, revision, title, notes, *, draft):
        return self.json("/releases", "POST", {
            "tag_name": release_tag, "target_commitish": revision,
            "name": title, "body": notes, "draft": draft, "prerelease": True,
            "make_latest": "false",
        })

    def assets(self, release):
        return {item["name"]: item for item in release["assets"]}

    def read_feed_asset(self, asset):
        with self.request(f"{API}/releases/assets/{asset['id']}",
                          headers={"Accept": "application/octet-stream"}) as response:
            return read_small(response)

    def rename(self, asset, name):
        self.json(f"/releases/assets/{asset['id']}", "PATCH", {"name": name})

    def delete(self, asset):
        self.json(f"/releases/assets/{asset['id']}", "DELETE")


def signer(*args):
    with tempfile.TemporaryDirectory(prefix="birch-linux-swift-") as cache:
        subprocess.run(["/usr/bin/swift", "-module-cache-path", cache,
                        str(SIGNER), *map(str, args)], check=True)


def config(build, revision):
    return {**IDENTITY, "build": build, "version": f"0.0.0+test.{build}",
            "revision": revision, "feed": FEED, "public_key_pem": PUBLIC_KEY.read_text()}


def manifest(expected_config, size, digest):
    payload = {field: value for field, value in expected_config.items()
               if field not in {"feed", "public_key_pem"}}
    build = expected_config["build"]
    return {**payload, "size": size, "sha256": digest,
            "url": f"{DOWNLOAD_ROOT}/{tag(build)}/{asset_name(build)}"}


def verified_envelope(data):
    envelope = read_json(data)
    require(set(envelope) == {"format", "payload", "signature"} and
            type(envelope["format"]) is int and envelope["format"] == 1,
            "Unexpected feed envelope")
    payload = base64.b64decode(envelope["payload"], validate=True)
    signature = base64.b64decode(envelope["signature"], validate=True)
    require(len(signature) == 64, "Unexpected signature size")
    with tempfile.TemporaryDirectory(prefix="birch-linux-verify-") as temporary:
        raw, sig = Path(temporary) / "payload", Path(temporary) / "signature"
        raw.write_bytes(payload)
        sig.write_bytes(signature)
        signer("verify", "--public", PUBLIC_KEY, "--input", raw, "--signature", sig)
    claims = read_json(payload)
    build, revision = claims["build"], claims["revision"]
    size, digest = claims["size"], claims["sha256"]
    require(whole_number(build, MAX_BUILD) and re.fullmatch(HEX_SHA, revision) and
            whole_number(size, MAX_PACKAGE) and re.fullmatch(HEX_DIGEST, digest),
            "Invalid signed build metadata")
    require(payload == canonical(manifest(config(build, revision), size, digest)),
            "Unexpected signed release identity")
    return claims


def deb_metadata(path, expected):
    # A Debian binary package is an ar archive. Read the two compressed tar
    # members without dpkg (the publisher runs on macOS) or extracting files.
    wanted = {
        "control.tar": {"control"},
        "data.tar": {f"opt/{NAME}/update-config.json", f"opt/{NAME}/linux-updater.py"},
    }
    texts = {}
    with path.open("rb") as src:
        require(src.read(8) == b"!<arch>\n", "Invalid Debian package")
        found = set()
        while header := src.read(60):
            require(len(header) == 60 and header[-2:] == b"`\n", "Invalid Debian archive entry")
            name = header[:16].decode("ascii").strip().rstrip("/")
            size = int(header[48:58])
            end = src.tell() + size
            require(size > 0 and end <= path.stat().st_size, "Invalid Debian archive size")
            member = name.removesuffix(".xz").removesuffix(".gz")
            if name == "debian-binary":
                require(not found and size == 4 and src.read(size) == b"2.0\n",
                        "Unsupported Debian package format")
                found.add(name)
            if member in wanted:
                prior = {"debian-binary", "control.tar"} if member == "data.tar" else {"debian-binary"}
                require(found == prior, "Invalid Debian archive member order")
                found.add(member)
                with tarfile.open(fileobj=src, mode="r|*") as archive:
                    for entry in archive:
                        entry_path = PurePosixPath(entry.name)
                        require(not entry_path.is_absolute() and ".." not in entry_path.parts,
                                "Unsafe Debian archive member path")
                        filename = str(entry_path)
                        if filename in {"opt", f"opt/{NAME}"}:
                            require(entry.isdir(), "Unsafe updater install directory type")
                        if filename not in wanted[member]:
                            continue
                        require(entry.isfile() and entry.uid == 0 and entry.gid == 0 and
                                filename not in texts and entry.mode & 0o7022 == 0,
                                "Unsafe updater metadata in Debian package")
                        if filename.endswith("linux-updater.py"):
                            require(entry.mode & 0o111 == 0o111 and entry.size > 0,
                                    "Updater file is not executable")
                            texts[filename] = ""
                        else:
                            texts[filename] = read_small(archive.extractfile(entry)).decode("utf-8")
            src.seek(end + (size % 2))
    require(found == {*wanted, "debian-binary"} and
            set(texts) == set.union(*wanted.values()), "Debian installer is missing updater files")
    require(canonical(read_json(texts[f"opt/{NAME}/update-config.json"])) == canonical(expected),
            "Installed updater configuration differs from build metadata")
    control = dict(line.split(": ", 1) for line in texts["control"].splitlines() if ": " in line)
    require(control.get("Package") == NAME and control.get("Architecture") == "amd64" and
            control.get("Version") == expected["version"], "Debian package identity mismatch")


def api_client():
    token = TOKEN.read_text().strip()
    require(bool(token), "GitHub token file is empty")
    return GitHub(token)


def prepare(args):
    require(whole_number(args.run, MAX_BUILD), "Run ID is outside the supported range")
    require(not args.out.exists(), "Candidate directory already exists")
    client = api_client()
    run = client.json(f"/actions/runs/{args.run}")
    revision = run["head_sha"]
    branch = run["head_branch"]
    require(run["id"] == args.run and run["path"] == WORKFLOW and
            run["event"] in {"push", "workflow_dispatch"} and run["status"] == "completed" and
            run["conclusion"] == "success" and run["head_repository"]["full_name"] == REPOSITORY and
            re.fullmatch(HEX_SHA, revision) and bool(branch) and
            (args.branch is None or args.branch == branch) and
            (args.revision is None or args.revision == revision),
            "Expected a successful Linux updater workflow for the requested branch and revision")
    query = urlencode({"name": ARTIFACT})
    artifacts = client.json(f"/actions/runs/{args.run}/artifacts?{query}")
    require(artifacts["total_count"] == 1 and len(artifacts["artifacts"]) == 1,
            "Expected exactly one Linux test package artifact")
    artifact = artifacts["artifacts"][0]
    require(artifact["name"] == ARTIFACT and artifact["expired"] is False and
            whole_number(artifact["id"], MAX_BUILD) and whole_number(artifact["size_in_bytes"], MAX_PACKAGE),
            "Linux test package artifact is unavailable")
    expected = config(args.run, revision)
    with tempfile.TemporaryDirectory(prefix="birch-linux-prepare-") as folder:
        scratch = Path(folder)
        public = scratch / "public.pem"
        signer("public", "--key", args.key, "--public", public)
        require(public.read_bytes() == PUBLIC_KEY.read_bytes(),
                "Linux test signing key does not match the installed public key")
        archive_path = scratch / "artifact.zip"
        print(f"Preparing build {args.run}: downloading Linux artifact ({artifact['size_in_bytes'] / 2**20:.1f} MiB)", flush=True)
        for attempt in range(3):
            # Avoid stale cached signed redirects. Only this read-only GET is
            # retried; publication mutations always require state inspection.
            download = f"{API}/actions/artifacts/{artifact['id']}/zip?fresh={time.time_ns()}"
            try:
                with client.request(download) as source, archive_path.open("wb") as target:
                    size, digest = copy_checked(source, target)
                break
            except (TimeoutError, URLError):
                if attempt == 2:
                    raise
                print("Retrying the read-only artifact download", flush=True)
                time.sleep(2 ** attempt)
        require(artifact.get("digest") == f"sha256:{digest}" and size == artifact["size_in_bytes"],
                "CI artifact download does not match GitHub's size and digest")
        package = scratch / asset_name(args.run)
        with ZipFile(archive_path) as archive:
            require(archive.namelist().count("build-info.json") == 1 and
                    archive.namelist().count(PACKAGE_FILE) == 1, "Missing or duplicate package artifact files")
            with archive.open("build-info.json") as stream:
                info = read_json(read_small(stream))
            with archive.open(PACKAGE_FILE) as source, package.open("wb") as target:
                size, digest = copy_checked(source, target)
        require(size > 0 and canonical(info) == canonical({**expected, "size": size, "sha256": digest}),
                "Artifact package does not match its CI build metadata")
        deb_metadata(package, expected)
        payload = manifest(expected, size, digest)
        raw = scratch / "manifest.json"
        raw.write_bytes(canonical(payload))
        feed = scratch / FEED_NAME
        signer("sign", "--key", args.key, "--input", raw, "--output", feed)
        require(verified_envelope(feed.read_bytes()) == payload, "Signed feed differs from candidate")
        args.out.mkdir(mode=0o700, parents=True)
        shutil.copyfile(package, args.out / package.name)
        (args.out / raw.name).write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
        (args.out / "ci.json").write_text(
            json.dumps({"branch": branch, "run": args.run, "revision": revision,
                        "artifact": artifact["id"]}, indent=2) + "\n")
        shutil.copyfile(feed, args.out / feed.name)
    print(f"Prepared Linux test build {args.run} from {revision} in {args.out}")


def verify_package(package, claims):
    require(package.name == asset_name(claims["build"]), "Unexpected package filename")
    with package.open("rb") as source:
        require(copy_checked(source) == (claims["size"], claims["sha256"]),
                "Candidate Debian package differs from signed feed")
    deb_metadata(package, config(claims["build"], claims["revision"]))


def fetch_public(client, url, read, *, retry=False):
    attempts = 6 if retry else 1
    for attempt in range(attempts):
        try:
            with client.request(url, authenticated=False) as stream:
                return read(stream)
        except HTTPError as error:
            if error.code not in {404, 502, 503} or attempt + 1 == attempts:
                raise
            time.sleep(2 ** attempt)


def publish_package(client, package, claims):
    build, revision = claims["build"], claims["revision"]
    release_tag = tag(build)
    release = client.release(release_tag, find_draft=True)
    ref = client.json(f"/git/ref/tags/{release_tag}", missing_ok=True)
    if ref is not None:
        require(ref["object"]["type"] == "commit" and ref["object"]["sha"] == revision,
                "Existing Linux test tag refers to a different commit")
    if release is None:
        release = client.create_release(
            release_tag, revision, f"Birch Chromium Test for Linux build {build}",
            "Interface test for Ubuntu 24.04 and Zorin OS 18.1. Install the .deb "
            "with Software. Uses a separate test profile with in-memory logins.",
            draft=True,
        )
    if release["draft"]:
        require(release["target_commitish"] == revision,
                "Existing build release draft refers to a different commit")
        existing = client.assets(release).get(package.name)
        if existing is None:
            existing = client.upload(release, package, package.name, "application/vnd.debian.binary-package")
        require(existing.get("digest") == f"sha256:{claims['sha256']}" and
                existing["size"] == claims["size"] and existing["state"] == "uploaded",
                "Existing draft package differs from the candidate")
        client.json(f"/releases/{release['id']}", "PATCH", {
            "draft": False, "prerelease": True, "make_latest": "false",
        })
    ref = client.json(f"/git/ref/tags/{release_tag}")
    require(ref["object"]["type"] == "commit" and ref["object"]["sha"] == revision,
            "Immutable Linux test tag refers to a different commit")
    uploaded = fetch_public(client, claims["url"], copy_checked, retry=True)
    require(uploaded == (claims["size"], claims["sha256"]),
            "Public Debian package differs from signed feed")


def publish_feed(client, file, claims):
    release = client.release(FEED_TAG)
    if release is None:
        release = client.create_release(
            FEED_TAG, claims["revision"], "Birch Chromium Test for Linux update feed",
            "Signed update metadata for the isolated Linux test package.", draft=False,
        )
    require(not release.get("immutable", False), "The Linux test feed release must allow asset updates")
    assets = client.assets(release)
    current = assets.get(FEED_NAME)
    if current is not None:
        installed = verified_envelope(client.read_feed_asset(current))
        if installed == claims:
            require(fetch_public(client, FEED, read_small, retry=True) == file.read_bytes(),
                    "The public update feed did not return the candidate")
            return
        require(installed["build"] < claims["build"], "Public feed already has this build or a newer build")
    require(PENDING_FEED not in assets, "A previous feed publish is pending; inspect the Linux test feed release")
    # The unique staging name prevents two publishers from advancing the feed
    # simultaneously. Re-read the release after reserving it: another
    # publisher might have finished since the preceding GET.
    staged = client.upload(release, file, PENDING_FEED, "application/json")
    previous = f"updates-linux-test.previous-{current['id']}.json" if current else None
    try:
        assets = client.assets(client.release(FEED_TAG))
        require(assets.get(FEED_NAME, {}).get("id") == (current or {}).get("id"),
                "The public feed changed during publishing")
        require(client.read_feed_asset(staged) == file.read_bytes(),
                "Staged public feed differs from the candidate")
        if current is not None:
            client.rename(current, previous)
        client.rename(staged, FEED_NAME)
    except Exception:
        # A request can time out after applying its rename. Check the current
        # asset names before deciding whether to restore the old feed.
        assets = client.assets(client.release(FEED_TAG))
        if FEED_NAME not in assets and previous in assets:
            client.rename(assets[previous], FEED_NAME)
        if PENDING_FEED in assets and assets[PENDING_FEED]["id"] == staged["id"]:
            client.delete(staged)
        raise
    require(fetch_public(client, FEED, read_small, retry=True) == file.read_bytes(),
            "The public update feed did not return the candidate")


def publish(args):
    with tempfile.TemporaryDirectory(prefix="birch-linux-publish-") as folder:
        feed = Path(folder) / FEED_NAME
        with (args.candidate / FEED_NAME).open("rb") as stream:
            feed.write_bytes(read_small(stream))
        claims = verified_envelope(feed.read_bytes())
        with (args.candidate / "manifest.json").open("rb") as stream:
            require(canonical(read_json(read_small(stream))) == canonical(claims),
                    "Reviewed manifest differs from the signed update feed")
        package = args.candidate / asset_name(claims["build"])
        verify_package(package, claims)
        client = api_client()
        publish_package(client, package, claims)
        publish_feed(client, feed, claims)
    print(f"Published Linux test build {claims['build']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prep = commands.add_parser("prepare", help="download and sign a successful CI artifact")
    prep.add_argument("--run", type=int, required=True)
    prep.add_argument("--branch")
    prep.add_argument("--revision")
    prep.add_argument("--key", type=Path, default=DEFAULT_KEY)
    prep.add_argument("--out", type=Path, required=True)
    prep.set_defaults(action=prepare)
    release = commands.add_parser("publish", help="publish a reviewed candidate to the Linux test feed")
    release.add_argument("--candidate", type=Path, required=True)
    release.set_defaults(action=publish)
    args = parser.parse_args()
    try:
        args.action(args)
    except HTTPError as error:
        parser.exit(1, f"Linux test release operation failed with GitHub HTTP {error.code}.\n")
    except (OSError, ValueError, KeyError, TypeError, BadZipFile, tarfile.TarError,
            subprocess.SubprocessError) as error:
        parser.exit(1, f"Linux test release operation failed: {error}\n")


if __name__ == "__main__":
    main()
