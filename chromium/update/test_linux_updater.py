"""Offline tests for the Linux test-channel updater. No privileged commands."""
import base64
import errno
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock
import urllib.request

import linux_updater as updater


def config_for(build=11, public_key=None):
    # The unsigned metadata tests only need a syntactically valid key.
    if public_key is None:
        der = bytes.fromhex("302a300506032b6570032100") + bytes(range(32))
        public_key = (
            "-----BEGIN PUBLIC KEY-----\n"
            + base64.b64encode(der).decode()
            + "\n-----END PUBLIC KEY-----\n"
        )
    return {
        **updater.IDENTITY,
        "build": build,
        "version": f"0.0.0+test.{build}",
        "revision": "a" * 40,
        "feed": updater.FEED,
        "public_key_pem": public_key,
    }


def manifest_for(package, build=12):
    return {
        **updater.IDENTITY,
        "build": build,
        "version": f"0.0.0+test.{build}",
        "revision": "b" * 40,
        "size": len(package),
        "sha256": hashlib.sha256(package).hexdigest(),
        "url": (
            f"https://github.com/{updater.REPOSITORY}/releases/download/"
            f"linux-test-{build}/Birch-Chromium-Test-linux-x64-{build}.deb"
        ),
    }


def signed_envelope(payload, signature):
    return json.dumps({
        "format": 1,
        "payload": base64.b64encode(payload).decode(),
        "signature": base64.b64encode(signature).decode(),
    }).encode()


class OfflineTest(unittest.TestCase):
    def setUp(self):
        block_network = mock.patch.object(urllib.request, "build_opener",
                                          side_effect=AssertionError("unexpected network access"))
        block_network.start()
        self.addCleanup(block_network.stop)

    def local_opener(self, bodies):
        # Unexpected URLs fail the test instead of ever touching a network.
        return mock.Mock(side_effect=lambda url: io.BytesIO(bodies[url]))


class MetadataTests(OfflineTest):
    def test_config_rejects_wrong_identity_types_and_source(self):
        valid = config_for()
        self.assertEqual(updater.validate_config(valid), valid)
        for changes in (
            {"schema": True}, {"edition": "webkit"}, {"channel": "stable"},
            {"os": "windows"}, {"arch": "arm64"}, {"package": "birch"},
            {"build": True}, {"build": 0}, {"build": 2**53}, {"revision": None},
            {"revision": "b" * 39}, {"version": "0.0.0+test.12"},
            {"feed": "https://github.com/other/feed"},
            {"public_key_pem": "not a key"},
        ):
            with self.subTest(changes=changes), self.assertRaises(updater.UpdateError):
                updater.validate_config({**valid, **changes})

    def test_rejects_malformed_or_oversized_envelopes_before_signature(self):
        verifier = mock.Mock()
        for envelope in (
            b'{"format":1,"format":1,"payload":"AA==","signature":"AA=="}',
            b'{"format":NaN,"payload":"AA==","signature":"AA=="}',
            b'{"format":true,"payload":"AA==","signature":"AA=="}',
            b'{"format":1,"payload":true,"signature":"AA=="}',
            b'{"format":1,"payload":"%%%%","signature":"AA=="}',
            signed_envelope(b"x", b"y" * 63),
            signed_envelope(b"x" * 16385, b"y" * 64),
            b" " * (updater.MAX_MANIFEST + 1),
        ):
            with self.subTest(metadata=envelope[:80]), self.assertRaises(updater.UpdateError):
                updater.manifest(envelope, config_for(), verifier=verifier)
        verifier.assert_not_called()

    def test_fetch_reads_only_manifest_limit_plus_one(self):
        response = mock.Mock(spec=io.BytesIO)
        response.read.return_value = b" " * (updater.MAX_MANIFEST + 1)
        opener = mock.Mock(return_value=mock.MagicMock())
        opener.return_value.__enter__.return_value = response
        with self.assertRaisesRegex(updater.UpdateError, "too large"):
            updater.fetch_manifest(config_for(), opener=opener)
        opener.assert_called_once_with(updater.FEED)
        response.read.assert_called_once_with(updater.MAX_MANIFEST + 1)

    def test_redirects_stay_on_the_https_allowlist(self):
        request = urllib.request.Request(updater.FEED)
        redirects = updater.Redirects()
        for forbidden in (
            "https://github.com.example.org/package.deb",
            "https://user@github.com/package.deb",
            "https://github.com@example.org/package.deb",
            "https://github.com:444/package.deb",
            "https://github.com/package.deb#fragment",
            "https://github.com/with\tspace.deb",
            "http://release-assets.githubusercontent.com/package.deb",
            "file:///tmp/package.deb",
        ):
            with self.subTest(url=forbidden), self.assertRaises(updater.UpdateError):
                redirects.redirect_request(request, None, 302, "", {}, forbidden)
        for host in ("github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"):
            url = f"https://{host}/package.deb?signed=fixture"
            with self.subTest(url=url):
                redirected = redirects.redirect_request(request, None, 302, "", {}, url)
                self.assertEqual(redirected.full_url, url)


class SignedFixture(OfflineTest):
    @classmethod
    def setUpClass(cls):
        scratch = tempfile.TemporaryDirectory(prefix="birch-update-test.")
        cls.addClassCleanup(scratch.cleanup)
        cls.root = Path(scratch.name)
        cls.signing_key = cls.root / "fixture-key.pem"
        cls.other_key = cls.root / "other-fixture-key.pem"
        try:
            for path in (cls.signing_key, cls.other_key):
                cls.openssl("genpkey", "-algorithm", "Ed25519", "-out", str(path))
            cls.public_key = cls.openssl("pkey", "-in", str(cls.signing_key), "-pubout").decode()
            cls.other_public_key = cls.openssl("pkey", "-in", str(cls.other_key), "-pubout").decode()
            cls.sign(b"Ed25519 capability probe")
        except (OSError, subprocess.CalledProcessError) as error:
            if platform.system() == "Darwin":
                raise unittest.SkipTest("system OpenSSL lacks Ed25519 signing support") from error
            raise

    @staticmethod
    def openssl(*arguments):
        return subprocess.run(
            ["/usr/bin/openssl", *arguments], check=True, capture_output=True, timeout=15,
        ).stdout

    @classmethod
    def sign(cls, payload, key=None):
        payload_path = cls.root / "payload"
        payload_path.write_bytes(payload)
        signature = cls.openssl("pkeyutl", "-sign", "-rawin", "-inkey",
                                str(key or cls.signing_key), "-in", str(payload_path))
        return signed_envelope(payload, signature)

    def installed_config(self):
        return updater.validate_config(config_for(public_key=self.public_key))

    def feed(self, data):
        return self.sign(json.dumps(data).encode())

    def run_operation(self, operation, data, package=None):
        bodies = {updater.FEED: self.feed(data)}
        if package is not None:
            bodies[data["url"]] = package
        self.urls = self.local_opener(bodies)
        read_manifest = updater.fetch_manifest
        download_package = updater.sealed_package
        with mock.patch.object(updater, "fetch_manifest",
                               side_effect=lambda config: read_manifest(config, opener=self.urls)), \
             mock.patch.object(updater, "sealed_package",
                               side_effect=lambda data: download_package(data, opener=self.urls)):
            return updater.perform(operation, self.installed_config())

class SignedTests(SignedFixture):
    def test_accepts_manifest_signed_by_installed_key(self):
        data = manifest_for(b"fixture")
        self.assertEqual(updater.manifest(self.feed(data), self.installed_config()), data)

    def test_rejects_replaced_key_corrupt_signature_and_tampered_payload(self):
        payload = json.dumps(manifest_for(b"fixture")).encode()
        valid = json.loads(self.sign(payload))
        signature = base64.b64decode(valid["signature"])
        for envelope in (
            self.sign(payload, key=self.other_key),
            signed_envelope(payload, bytes([signature[0] ^ 1]) + signature[1:]),
            signed_envelope(payload.replace(b'"size": 7', b'"size": 8'), signature),
        ):
            with self.subTest(envelope=envelope[:30]), self.assertRaisesRegex(updater.UpdateError, "signature"):
                updater.manifest(envelope, self.installed_config())

    def test_rejects_invalid_even_when_signed(self):
        data = manifest_for(b"fixture")
        for changes in (
            {"edition": "webkit"}, {"channel": "stable"}, {"arch": "arm64"},
            {"schema": True}, {"build": True}, {"build": 2**53}, {"size": True},
            {"size": updater.MAX_PACKAGE + 1}, {"sha256": "a" * 63}, {"version": "0.0.0+test.13"},
            {"url": "https://release-assets.githubusercontent.com/unbound.deb"},
            {"url": manifest_for(b"fixture", build=13)["url"]},
        ):
            with self.subTest(changes=changes), self.assertRaises(updater.UpdateError):
                updater.manifest(self.feed({**data, **changes}), self.installed_config())
        payload = json.dumps(data).encode()
        for bad in (b'{"edition":"chromium",' + payload[1:], payload.replace(b'"size": 7', b'"size": NaN')):
            with self.subTest(metadata=bad[:80]), self.assertRaises(updater.UpdateError):
                updater.manifest(self.sign(bad), self.installed_config())

    def test_check_and_old_build_never_download_or_install(self):
        for operation, build, expected in (
            ("check", 12, "available"), ("check", 11, "current"),
            ("install", 11, "current"), ("install", 10, "current"),
        ):
            with self.subTest(operation=operation, build=build), mock.patch.object(
                updater, "install_sealed", side_effect=AssertionError("unexpected system install")
            ) as install:
                result = self.run_operation(operation, manifest_for(b"fixture", build=build))
                self.assertEqual(result["status"], expected)
                self.assertEqual(result["canInstall"], expected == "available")
                self.urls.assert_called_once_with(updater.FEED)
                install.assert_not_called()


@unittest.skipUnless(platform.system() == "Linux", "Linux memfd support is required")
class SealingTests(OfflineTest):
    def test_rejects_wrong_size_or_checksum(self):
        body = b"real bytes"
        data = manifest_for(body)
        for package in (body[:-1], body + b"!", b"fake bytes"):
            with self.subTest(package=package), self.assertRaisesRegex(updater.UpdateError, "size|checksum"):
                updater.sealed_package(data, opener=self.local_opener({data["url"]: package}))

    def test_fake_installer_reads_only_immutable_bytes(self):
        body = b"verified package bytes"
        data = manifest_for(body)
        fd = updater.sealed_package(data, opener=self.local_opener({data["url"]: body}))
        self.addCleanup(os.close, fd)

        def fake_install(command, **kwargs):
            self.assertEqual(command, [
                "/usr/bin/pkexec", "--disable-internal-agent", "/usr/bin/dpkg", "--refuse-downgrade", "--install",
                f"/proc/{os.getpid()}/fd/{fd}",
            ])
            self.assertFalse(kwargs.get("shell", False))
            path = Path(command[-1])
            with tempfile.TemporaryDirectory(prefix="birch-package-swap.") as scratch:
                replacement = Path(scratch) / "replacement.deb"
                replacement.write_bytes(b"replacement package")
                with self.assertRaises(OSError):
                    replacement.replace(path)
            other_fd = os.open(path, os.O_RDWR)
            try:
                for change, arguments in (
                    (os.pwrite, (other_fd, b"changed", 0)),
                    (os.ftruncate, (other_fd, len(body) - 1)),
                    (os.ftruncate, (other_fd, len(body) + 1)),
                ):
                    with self.subTest(change=change, arguments=arguments):
                        with self.assertRaises(OSError) as refused:
                            change(*arguments)
                        self.assertEqual(refused.exception.errno, errno.EPERM)
            finally:
                os.close(other_fd)
            reader = subprocess.run(
                ["/usr/bin/cat", str(path)], check=True, capture_output=True, timeout=5,
            )
            self.assertEqual(reader.stdout, body)
            return subprocess.CompletedProcess(command, 0)

        self.assertEqual(updater.install_sealed(fd, runner=fake_install), 0)


@unittest.skipUnless(platform.system() == "Linux", "Linux memfd and dpkg-deb are required")
class SignedPackageTests(SignedFixture):
    def setUp(self):
        super().setUp()
        scratch = tempfile.TemporaryDirectory(prefix="birch-deb-test.")
        self.addCleanup(scratch.cleanup)
        self.package_root = Path(scratch.name)

    def build_deb(self, descriptor, package=None, version=None, architecture="amd64"):
        tree = self.package_root / "package"
        control = tree / "DEBIAN" / "control"
        control.parent.mkdir(parents=True, exist_ok=True)
        package = package or updater.IDENTITY["package"]
        version = version or descriptor["version"]
        control.write_text(
            f"Package: {package}\nVersion: {version}\nArchitecture: {architecture}\n"
            "Maintainer: Birch Test <test@example.org>\nDescription: Offline updater fixture\n"
        )
        metadata = tree / "opt" / "birch-chromium-test" / "update-config.json"
        metadata.parent.mkdir(parents=True, exist_ok=True)
        metadata.write_text(json.dumps(descriptor))
        target = self.package_root / "fixture.deb"
        subprocess.run(
            ["/usr/bin/dpkg-deb", "-Znone", "--root-owner-group", "--build", str(tree), str(target)],
            check=True, capture_output=True, timeout=15,
        )
        return target.read_bytes()

    def next_descriptor(self):
        return {**config_for(build=12, public_key=self.public_key), "revision": "b" * 40}

    def test_fake_install_results_close_package_and_preserve_app_and_profile(self):
        app = self.package_root / "app.fixture"
        profile = self.package_root / "profile.fixture"
        app.write_bytes(b"installed code")
        profile.write_bytes(b"saved tabs")
        package = self.build_deb(self.next_descriptor())
        data = manifest_for(package)
        run_installer = updater.install_sealed

        for exit_code, status, retry, message in (
            (126, "available", True, "not approved"),
            (127, "available", True, "not approved"),
            (2, "error", True, "reported a failure"),
            (0, "installed", False, "Quit and reopen"),
        ):
            handed_off = []

            def fake_install(fd):
                handed_off.append(fd)

                def fake_runner(command, **kwargs):
                    self.assertEqual(Path(command[-1]).read_bytes(), package)
                    return subprocess.CompletedProcess(command, exit_code)

                return run_installer(fd, runner=fake_runner)

            with self.subTest(exit_code=exit_code), mock.patch.object(
                updater, "install_sealed", side_effect=fake_install
            ) as install:
                result = self.run_operation("install", data, package)
                self.assertEqual(result["status"], status)
                self.assertEqual(result["canInstall"], retry)
                self.assertIn(message, result["message"])
                install.assert_called_once()
                self.assertEqual(self.urls.call_args_list, [mock.call(updater.FEED), mock.call(data["url"])])
                self.assertEqual(app.read_bytes(), b"installed code")
                self.assertEqual(profile.read_bytes(), b"saved tabs")
                with self.assertRaises(OSError) as closed:
                    os.fstat(handed_off[0])
                self.assertEqual(closed.exception.errno, errno.EBADF)

    def test_malformed_signed_data_archive_never_reaches_installer(self):
        package = self.build_deb(self.next_descriptor())
        # .deb uses ar. Preserve its control archive and corrupt the first tar
        # header of the uncompressed data member after the 60-byte ar header.
        data_start = package.index(b"data.tar ") + 60
        damaged = package[:data_start] + b"!" * 512 + package[data_start + 512:]
        with mock.patch.object(updater, "install_sealed",
                               side_effect=AssertionError("unexpected system install")) as install:
            with self.assertRaises((updater.UpdateError, tarfile.TarError)):
                self.run_operation("install", manifest_for(damaged), damaged)
            install.assert_not_called()

    def test_mismatched_signed_debs_never_reach_installer(self):
        descriptor = self.next_descriptor()
        for embedded, control in (
            (descriptor, {"package": "other-browser"}),
            (descriptor, {"architecture": "arm64"}),
            (descriptor, {"version": "0.0.0+test.13"}),
            ({**descriptor, "edition": "webkit"}, {}),
            ({**descriptor, "revision": "c" * 40}, {}),
            ({**descriptor, "public_key_pem": self.other_public_key}, {}),
            ({**descriptor, "build": 13, "version": "0.0.0+test.13"}, {"version": descriptor["version"]}),
        ):
            with self.subTest(embedded=embedded, control=control), mock.patch.object(
                updater, "install_sealed", side_effect=AssertionError("unexpected system install")
            ) as install:
                package = self.build_deb(embedded, **control)
                with self.assertRaises(updater.UpdateError):
                    self.run_operation("install", manifest_for(package), package)
                install.assert_not_called()


if __name__ == "__main__":
    unittest.main()
