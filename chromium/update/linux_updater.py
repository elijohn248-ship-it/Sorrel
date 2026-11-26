#!/usr/bin/python3 -I
"""Birch's Linux test-channel updater. No browser cookies or arbitrary URLs.

The signed manifest binds edition, channel, monotonic build, size and SHA-256.
The package is streamed into a sealed memfd; dpkg reads those immutable bytes
through /proc while this unprivileged process holds the descriptor open.
Only the system's normal pkexec authorization may start dpkg as root.
"""
import argparse
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import stat
import threading
import time
import signal
import subprocess
import tarfile
import tempfile
import urllib.error
import urllib.parse
import urllib.request

REPOSITORY = "elijohn248-ship-it/Sorrel"
FEED = f"https://github.com/{REPOSITORY}/releases/download/chromium-linux-test/updates-linux-test.json"
IDENTITY = {"schema": 1, "channel": "linux-test", "edition": "chromium", "os": "linux",
            "arch": "x86_64", "package": "birch-chromium-test"}
HOSTS = {"github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com",
         "github-releases.githubusercontent.com"}
MAX_PACKAGE = 1024 * 1024 * 1024
MAX_MANIFEST = 65536


class UpdateError(Exception):
    pass


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise UpdateError("Duplicate manifest key")
        result[key] = value
    return result


def parse_json(data):
    try:
        return json.loads(data, object_pairs_hook=_pairs,
                          parse_constant=lambda _: (_ for _ in ()).throw(UpdateError("Invalid number")))
    except (ValueError, UnicodeError, RecursionError) as error:
        raise UpdateError("Invalid update metadata") from error


def number(value, maximum):
    return type(value) is int and 0 < value <= maximum


def checked_url(url):
    if not isinstance(url, str) or len(url) > 4096:
        raise UpdateError("Invalid update address")
    try:
        parts = urllib.parse.urlsplit(url)
        valid = (parts.scheme == "https" and parts.hostname in HOSTS and
                 parts.port in (None, 443) and not parts.username and not parts.password and
                 not parts.fragment and not any(ord(c) < 33 for c in url))
    except ValueError:
        valid = False
    if not valid:
        raise UpdateError("Update address is outside the test channel")
    return url


class Redirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        checked_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def open_url(url):
    checked_url(url)
    # Standard OS/environment proxy behavior; no cookie jar or browser profile.
    opener = urllib.request.build_opener(Redirects())
    request = urllib.request.Request(url, headers={"User-Agent": "Birch-Linux-Test-Updater",
                                                  "Accept-Encoding": "identity"})
    return opener.open(request, timeout=30)


def public_key_ok(pem):
    if not isinstance(pem, str) or len(pem) > 256:
        return False
    try:
        body = pem.removeprefix("-----BEGIN PUBLIC KEY-----\n").removesuffix("-----END PUBLIC KEY-----\n")
        der = base64.b64decode("".join(body.split()), validate=True)
        return len(der) == 44 and der[:12] == bytes.fromhex("302a300506032b6570032100")
    except ValueError:
        return False


def validate_config(config):
    if not isinstance(config, dict) or type(config.get("schema")) is not int or any(config.get(k) != v for k, v in IDENTITY.items()):
        raise UpdateError("Wrong installed update edition")
    if not number(config.get("build"), 2**53 - 1) or config.get("feed") != FEED:
        raise UpdateError("Invalid installed update configuration")
    if config.get("version") != f"0.0.0+test.{config['build']}" or not isinstance(config.get("revision"), str) or not re.fullmatch(
            r"[0-9a-f]{40}", config.get("revision", "")) or not public_key_ok(config.get("public_key_pem")):
        raise UpdateError("Invalid installed build identity")
    return config


def verify_signature(payload, signature, public_key):
    with tempfile.TemporaryDirectory(prefix="birch-signature.") as scratch:
        root = Path(scratch)
        (root / "payload").write_bytes(payload)
        (root / "signature").write_bytes(signature)
        (root / "key.pem").write_text(public_key)
        result = subprocess.run(["/usr/bin/openssl", "pkeyutl", "-verify", "-pubin", "-rawin",
                                 "-inkey", str(root / "key.pem"), "-in", str(root / "payload"),
                                 "-sigfile", str(root / "signature")],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        if result.returncode != 0:
            raise UpdateError("The test update signature is invalid")


def manifest(envelope, config, verifier=verify_signature):
    if len(envelope) > MAX_MANIFEST:
        raise UpdateError("Update metadata is too large")
    obj = parse_json(envelope)
    if not isinstance(obj, dict) or set(obj) != {"format", "payload", "signature"} or type(obj["format"]) is not int or obj["format"] != 1:
        raise UpdateError("Unsupported signed update metadata")
    try:
        payload = base64.b64decode(obj["payload"], validate=True)
        signature = base64.b64decode(obj["signature"], validate=True)
    except (ValueError, TypeError) as error:
        raise UpdateError("Invalid signature encoding") from error
    if not payload or len(payload) > 16384 or len(signature) != 64:
        raise UpdateError("Invalid signature size")
    verifier(payload, signature, config["public_key_pem"])
    data = parse_json(payload)
    fields = set(IDENTITY) | {"build", "version", "revision", "size", "sha256", "url"}
    if not isinstance(data, dict) or set(data) != fields or any(data.get(k) != v for k, v in IDENTITY.items()):
        raise UpdateError("The update is for another edition or channel")
    if type(data["schema"]) is not int or not number(data["build"], 2**53 - 1) or not number(data["size"], MAX_PACKAGE):
        raise UpdateError("Invalid update size or build")
    if data["version"] != f"0.0.0+test.{data['build']}" or not isinstance(data["revision"], str) or not re.fullmatch(r"[0-9a-f]{40}", data["revision"]):
        raise UpdateError("Invalid update version")
    if not isinstance(data["sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", data["sha256"]):
        raise UpdateError("Invalid update checksum")
    expected = f"https://github.com/{REPOSITORY}/releases/download/linux-test-{data['build']}/Birch-Chromium-Test-linux-x64-{data['build']}.deb"
    if data["url"] != expected:
        raise UpdateError("Wrong test update package address")
    return data


def fetch_manifest(config, opener=open_url):
    with opener(config["feed"]) as response:
        return manifest(response.read(MAX_MANIFEST + 1), config)


def sealed_package(data, opener=open_url):
    if not hasattr(os, "memfd_create"):
        raise UpdateError("This Linux system does not support immutable update staging")
    fd = os.memfd_create("Birch-Linux-Test.deb", os.MFD_CLOEXEC | os.MFD_ALLOW_SEALING)
    try:
        digest = hashlib.sha256()
        count = 0
        deadline = time.monotonic() + 900
        with opener(data["url"]) as response, os.fdopen(os.dup(fd), "wb") as output:
            while True:
                block = response.read(1024 * 1024)
                if not block:
                    break
                if time.monotonic() > deadline:
                    raise UpdateError("The update download timed out")
                count += len(block)
                if count > data["size"]:
                    raise UpdateError("Downloaded update has the wrong size")
                digest.update(block)
                output.write(block)
        if count != data["size"] or digest.hexdigest() != data["sha256"]:
            raise UpdateError("Downloaded update failed its size or checksum check")
        seals = fcntl.F_SEAL_WRITE | fcntl.F_SEAL_GROW | fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_SEAL
        fcntl.fcntl(fd, fcntl.F_ADD_SEALS, seals)
        os.lseek(fd, 0, os.SEEK_SET)
        return fd
    except BaseException:
        os.close(fd)
        raise


def validate_package(fd, data, config):
    path = f"/proc/{os.getpid()}/fd/{fd}"
    result = subprocess.run(["/usr/bin/dpkg-deb", "--field", path, "Package", "Version", "Architecture"],
                            capture_output=True, timeout=30, check=False)
    if result.returncode != 0 or len(result.stdout) > 4096:
        raise UpdateError("Downloaded file is not a Debian package")
    fields = dict(line.split(": ", 1) for line in result.stdout.decode().splitlines() if ": " in line)
    if fields != {"Package": IDENTITY["package"], "Version": data["version"], "Architecture": "amd64"}:
        raise UpdateError("The Debian package identity does not match its signature")
    proc = subprocess.Popen(["/usr/bin/dpkg-deb", "--fsys-tarfile", path], stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, start_new_session=True)
    def stop_parser():
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    watchdog = threading.Timer(60, stop_parser)
    watchdog.daemon = True
    watchdog.start()
    class BoundedPipe:
        def __init__(self):
            self.count = 0
        def read(self, size):
            chunk = proc.stdout.read(size)
            self.count += len(chunk)
            if self.count > 3 * MAX_PACKAGE + 16 * 1024 * 1024:
                raise UpdateError("Expanded update package is too large")
            return chunk
    bounded = BoundedPipe()
    descriptor = None
    total = 0
    try:
        with tarfile.open(fileobj=bounded, mode="r|") as archive:
            for entry in archive:
                total += entry.size
                if total > 3 * MAX_PACKAGE or entry.size < 0:
                    raise UpdateError("Expanded update package is too large")
                name = entry.name.removeprefix("./")
                if name == "opt/birch-chromium-test/update-config.json":
                    if descriptor is not None or not entry.isfile() or entry.size > 16384:
                        raise UpdateError("Invalid package build descriptor")
                    descriptor = parse_json(archive.extractfile(entry).read(16385))
        # Drain tar padding so the producer cannot block after tar EOF.
        while bounded.read(65536):
            pass
        if proc.wait(timeout=30) != 0 or descriptor is None:
            raise UpdateError("The package has no valid Linux build descriptor")
    finally:
        watchdog.cancel()
        proc.stdout.close()
        if proc.poll() is None:
            proc.kill()
            proc.wait()
    validate_config(descriptor)
    for key in IDENTITY.keys() | {"build", "version", "revision"}:
        if descriptor[key] != data[key]:
            raise UpdateError("The package contains another build or edition")
    if descriptor["public_key_pem"] != config["public_key_pem"]:
        raise UpdateError("The package changes the trusted update key")
    os.lseek(fd, 0, os.SEEK_SET)


def install_sealed(fd, runner=subprocess.run):
    # No shell; the only elevated executable/operation is dpkg --install.
    # Keep the immutable descriptor alive until the package manager exits.
    return runner(["/usr/bin/pkexec", "--disable-internal-agent", "/usr/bin/dpkg", "--refuse-downgrade", "--install",
                   f"/proc/{os.getpid()}/fd/{fd}"], stdout=subprocess.DEVNULL,
                  stderr=subprocess.DEVNULL, check=False).returncode


def state(status, message, data=None, ready=False):
    return {"supported": True, "status": status, "message": message,
            "version": data["version"] if data else "", "build": data["build"] if data else 0,
            "canInstall": ready}


def perform(operation, config):
    data = fetch_manifest(config)
    if data["build"] <= config["build"]:
        return state("current", "This test build is up to date.")
    if operation == "check":
        return state("available", "A newer Linux test build is available.", data, True)
    fd = sealed_package(data)
    try:
        validate_package(fd, data, config)
        result = install_sealed(fd)
    finally:
        os.close(fd)
    if result == 0:
        return state("installed", "Update installed. Quit and reopen Birch to use it.", data)
    if result in (126, 127):
        return state("available", "Installation was not approved. You can try again.", data, True)
    return state("error", "The system package installer reported a failure. Your browser remains open.", data, True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=("check", "install"))
    args = parser.parse_args()
    try:
        if platform.system() != "Linux" or platform.machine() not in ("x86_64", "amd64"):
            raise UpdateError("This updater is only for Linux x64 test builds")
        config = validate_config(parse_json(Path(__file__).with_name("update-config.json").read_bytes()))
        # A process-wide advisory lock also serializes separate browser windows.
        lock_root = Path(os.environ.get("XDG_RUNTIME_DIR", tempfile.gettempdir()))
        lock = lock_root / f"birch-linux-test-update-{os.getuid()}.lock"
        fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            metadata = os.fstat(fd)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_nlink != 1:
                raise UpdateError("Unsafe updater lock")
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise UpdateError("Another update operation is already running") from error
            output = perform(args.operation, config)
        finally:
            os.close(fd)
    except urllib.error.HTTPError as error:
        output = state("idle" if error.code == 404 else "error",
                       "No Linux test update has been published yet." if error.code == 404 else "Could not retrieve the test update.")
    except (UpdateError, OSError, ValueError, subprocess.SubprocessError, tarfile.TarError) as error:
        output = state("error", str(error) if isinstance(error, UpdateError) else "The update operation could not finish.")
    print(json.dumps(output, separators=(",", ":")))


if __name__ == "__main__":
    main()
