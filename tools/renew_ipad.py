#!/usr/bin/env python3
"""Renew only the configured, already-installed OpenDisplay iPad development app.

Default is --check. --run can refresh this app's cached profiles, build the iOS
target, install, and verify the app's launch receipt. No certificates, Mac apps,
TCC settings, or device applications are deleted. All subprocess output stays
in the private run directory; stdout contains one small status JSON object.
"""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import time

UTC = dt.timezone.utc
EXPECTED_BUNDLE = "local.xiazhibin.opendisplay.input.ios"
GENERATED_INFO = {"iOS/Info.plist", "Mac/Info.plist", "MacReceiver/Info.plist"}


class RenewalError(Exception):
    def __init__(self, reason: str, status: str = "failed"):
        super().__init__(reason)
        self.reason, self.status = reason, status


def utc(value) -> dt.datetime:
    if isinstance(value, dt.datetime):
        return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)
    result = dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("timestamp requires timezone")
    return result.astimezone(UTC)


def iso(value: dt.datetime) -> str:
    return utc(value).isoformat(timespec="seconds").replace("+00:00", "Z")


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def atomic_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def load_json(path: Path):
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


class CommandRunner:
    def run(self, argv, log: Path, timeout: int, *, cwd=None, env=None) -> tuple[int, bool]:
        """No shell; kill the command's process group after a bounded timeout."""
        with log.open("wb") as output:
            process = subprocess.Popen(argv, cwd=cwd, env=env, stdout=output,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                return process.wait(timeout=timeout), False
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
                return process.returncode, True


class Renewal:
    def __init__(self, config: dict, *, runner=None, now=None, home=None):
        self.c = dict(config)
        for key in ("source_root", "manifest_path", "derived_data", "state_root"):
            if not Path(self.c[key]).is_absolute():
                raise RenewalError("config_paths_must_be_absolute")
            self.c[key] = str(Path(self.c[key]).resolve())
        if self.c["bundle_id"] != EXPECTED_BUNDLE:
            raise RenewalError("wrong_bundle_configuration")
        if not re.fullmatch(r"[A-Z0-9]{10}", self.c["team_id"]):
            raise RenewalError("invalid_team_configuration")
        if not self.c["device_id"] or not self.c["device_udid"]:
            raise RenewalError("missing_device_identity")
        utc(self.c["initial_expiry"])
        if not re.fullmatch(r"[0-9a-f]{64}", self.c["initial_profile_sha256"]):
            raise RenewalError("invalid_initial_profile_hash")
        self.source = Path(self.c["source_root"])
        self.root = Path(self.c["state_root"])
        self.now = now or (lambda: dt.datetime.now(UTC))
        self.runner = runner or CommandRunner()
        self.home = Path(home) if home else Path.home()
        self.env = dict(os.environ)
        self.env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + self.env.get("PATH", "")
        self.env["DEVELOPMENT_TEAM"] = self.c["team_id"]
        self.run_dir: Path | None = None
        self.sequence = 0
        self.state = {}

    def identity(self) -> dict:
        return {k: self.c[k] for k in ("bundle_id", "team_id", "device_id", "device_udid")}

    def result(self, status: str, reason: str, **extra) -> dict:
        retry = self.now() + dt.timedelta(hours=1)
        result = {"status": status, "reason": reason, "checked_at": iso(self.now()),
                  "next_retry": iso(retry), **extra}
        if self.run_dir:
            result["run_dir"] = str(self.run_dir)
            atomic_json(self.run_dir / "result.json", result)
        atomic_json(self.root / "latest-result.json", result)
        if self.state:
            self.state["last_result"] = result
            atomic_json(self.root / "state.json", self.state)
        return result

    def run(self, *, execute=False, force=False) -> dict:
        self.root.mkdir(parents=True, exist_ok=True)
        os.chmod(self.root, 0o700)
        with (self.root / "renew.lock").open("a+") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return {"status": "deferred", "reason": "already_running",
                        "next_retry": iso(self.now() + dt.timedelta(hours=1))}
            try:
                return self._run(execute=execute, force=force)
            except RenewalError as error:
                return self.result(error.status, error.reason)
            except Exception as error:
                # Do not print command output, account details, or config values.
                return self.result("failed", "unexpected_" + type(error).__name__)

    def _run(self, *, execute: bool, force: bool) -> dict:
        state_path = self.root / "state.json"
        self.state = load_json(state_path) if state_path.exists() else {
            **self.identity(), "current_build": int(self.c["initial_build"]),
            "expiry": iso(utc(self.c["initial_expiry"])),
            "profile_sha256": self.c["initial_profile_sha256"]}
        if any(self.state.get(k) != v for k, v in self.identity().items()):
            raise RenewalError("state_identity_mismatch")
        pending_path = self.root / "pending.json"
        expiry = utc(self.state["expiry"])
        threshold = dt.timedelta(hours=float(self.c.get("threshold_hours", 48)))
        if not pending_path.exists() and not force and expiry - self.now() > threshold:
            return self.result("quiet_not_due", "profile_not_near_expiry", expiry=iso(expiry),
                               next_retry=iso(expiry - threshold))
        self.run_dir = self.root / "runs" / (self.now().strftime("%Y%m%dT%H%M%S%fZ") + f"-{os.getpid()}")
        self.run_dir.mkdir(parents=True, exist_ok=False)
        self.verify_manifest()
        installed = self.probe_device()
        if not pending_path.exists() and self.installed_build(installed) != int(self.state["current_build"]):
            # A separately installed feature update needs a new verified source
            # snapshot. Never overwrite it with this older frozen app merely
            # by assigning a larger build number.
            raise RenewalError("installed_build_changed_update_snapshot")
        if pending_path.exists():
            pending = load_json(pending_path)
            self.validate_pending(pending, require_remaining=False)
            stale = (self.installed_build(installed) < int(pending["build"])
                     and utc(pending["expiry"]) - self.now() <= dt.timedelta(hours=48))
            if not execute:
                return self.result("checked", "pending_stale_rebuild_required" if stale else "pending_recovery_ready", candidate_build=pending["build"],
                                   installed_build=self.installed_build(installed))
            if stale:
                # Preserve the old candidate and journal, but never let a stale
                # uninstalled candidate permanently block a fresh renewal.
                os.replace(pending_path, self.run_dir / "stale-pending.json")
            else:
                return self.finish_pending(pending, installed)
        if not execute:
            return self.result("checked", "ready_for_renewal", expiry=iso(expiry),
                               next_build=max(self.installed_build(installed), int(self.state["current_build"])) + 1)
        build = max(self.installed_build(installed), int(self.state["current_build"])) + 1
        app = self.build_candidate(build, expiry)
        pending = {**self.identity(), "version": self.c["version"], "build": build,
                   "created_at": iso(self.now()), "old_expiry": iso(expiry),
                   "app_path": str(app), "app_sha256": self.app_hash(app),
                   "profile_sha256": sha(app / "embedded.mobileprovision"),
                   "expiry": iso(utc(self.decode_profile(app / "embedded.mobileprovision")["ExpirationDate"])),
                   "source_manifest_sha256": sha(Path(self.c["manifest_path"]))}
        atomic_json(pending_path, pending)  # durable before any installation
        return self.finish_pending(pending, self.probe_device())

    def command(self, argv, label: str, timeout=45, *, required=True):
        self.sequence += 1
        log = self.run_dir / f"{self.sequence:03d}-{label}.log"
        with (self.run_dir / "commands.jsonl").open("a", encoding="utf-8") as stream:
            stream.write(json.dumps({"argv": list(map(str, argv)), "timeout": timeout,
                                     "log": log.name}, ensure_ascii=False) + "\n")
        code, timed_out = self.runner.run(list(map(str, argv)), log, timeout,
                                         cwd=self.source, env=self.env)
        if required and (code != 0 or timed_out):
            raise RenewalError(label + ("_timeout" if timed_out else "_failed"))
        return code, timed_out, log

    def device_json(self, arguments, label, *, required=True):
        destination = self.run_dir / f"{self.sequence + 1:03d}-{label}.json"
        # launch treats every token after its bundle positional as app argv.
        # Put common device options before positional arguments for every verb.
        code, timeout, _ = self.command(["/usr/bin/xcrun", "devicectl", "device", *arguments[:2],
            "--device", self.c["device_id"], "--timeout", "45", "--json-output", destination, "--quiet",
            *arguments[2:]],
            label, required=False)
        try:
            value = load_json(destination)
            good = code == 0 and not timeout and value.get("info", {}).get("outcome") == "success"
        except (OSError, ValueError):
            value, good = {}, False
        if not good:
            if required:
                raise RenewalError(label + "_unavailable", "deferred")
            return None
        return value.get("result", {})

    def verify_manifest(self):
        manifest = load_json(Path(self.c["manifest_path"]))
        if not isinstance(manifest, dict) or not manifest:
            raise RenewalError("invalid_source_manifest")
        for relative, expected in manifest.items():
            file = self.source / relative
            if Path(relative).is_absolute() or ".." in Path(relative).parts or file.is_symlink():
                raise RenewalError("unsafe_manifest_path")
            if not file.is_file() or sha(file) != expected:
                raise RenewalError("frozen_source_changed")
        for file in self.source.rglob("*"):
            relative = file.relative_to(self.source)
            if relative.parts[0] == "OpenSidecar.xcodeproj" or str(relative) in GENERATED_INFO:
                continue
            if file.is_symlink() or file.is_file() and str(relative) not in manifest:
                raise RenewalError("unmanifested_source_file")

    def probe_device(self) -> dict:
        details = self.device_json(["info", "details"], "device-details")
        properties = details.get("properties", {})
        connection = properties.get("connection", details.get("connectionProperties", {}))
        hardware = properties.get("hardware", details.get("hardwareProperties", {}))
        if details.get("identifier", "").lower() != self.c["device_id"].lower() or hardware.get("udid") != self.c["device_udid"]:
            raise RenewalError("wrong_device")
        if connection.get("transportType") != "wired" or connection.get("pairingState") != "paired" or connection.get("state", connection.get("tunnelState")) != "connected":
            raise RenewalError("usb_device_not_connected_and_paired", "deferred")
        lock = self.device_json(["info", "lockState"], "device-lock")
        self.check_device_identifier(lock)
        if lock.get("passcodeRequired") is not False or lock.get("unlockedSinceBoot") is not True:
            raise RenewalError("device_locked", "deferred")
        return self.installed_app()

    def check_device_identifier(self, value):
        if value.get("deviceIdentifier", "").lower() != self.c["device_id"].lower():
            raise RenewalError("wrong_device")

    def installed_app(self):
        result = self.device_json(["info", "apps", "--bundle-id", self.c["bundle_id"]], "installed-app")
        self.check_device_identifier(result)
        apps = result.get("apps", [])
        if len(apps) != 1 or apps[0].get("bundleIdentifier") != self.c["bundle_id"]:
            raise RenewalError("target_app_missing_or_wrong_bundle")
        if apps[0].get("builtByDeveloper") is not True or apps[0].get("version") != self.c["version"]:
            raise RenewalError("installed_app_identity_changed")
        self.installed_build(apps[0])
        return apps[0]

    @staticmethod
    def installed_build(app):
        raw = str(app.get("bundleVersion", ""))
        if not re.fullmatch(r"[0-9]+", raw):
            raise RenewalError("invalid_installed_build")
        return int(raw)

    def decode_profile(self, file: Path):
        _, _, log = self.command(["/usr/bin/security", "cms", "-D", "-i", file], "decode-profile")
        raw = log.read_bytes()
        start, end = raw.find(b"<?xml"), raw.rfind(b"</plist>")
        try:
            return plistlib.loads(raw[start:end + 8] if start >= 0 and end >= 0 else raw)
        except (ValueError, plistlib.InvalidFileException):
            raise RenewalError("invalid_profile")

    def is_target_profile(self, profile):
        entitlements = profile.get("Entitlements", {})
        return (profile.get("TeamIdentifier") == [self.c["team_id"]]
                and entitlements.get("application-identifier") == self.c["team_id"] + "." + self.c["bundle_id"]
                and entitlements.get("com.apple.developer.team-identifier") == self.c["team_id"])

    def profile_directories(self):
        return [self.home / "Library/Developer/Xcode/UserData/Provisioning Profiles",
                self.home / "Library/MobileDevice/Provisioning Profiles"]

    def cached_target_profiles(self):
        for directory in self.profile_directories():
            if not directory.is_dir():
                continue
            for file in sorted(directory.iterdir()):
                if not file.is_file() or file.is_symlink() or file.suffix not in (".mobileprovision", ".provisionprofile"):
                    continue
                try:
                    profile = self.decode_profile(file)
                except RenewalError:
                    continue  # An unreadable/unrelated profile is never moved.
                if self.is_target_profile(profile):
                    yield file, profile

    @contextlib.contextmanager
    def refreshed_profiles(self):
        moves = []
        backup = self.run_dir / "profile-backups"
        backup.mkdir()
        try:
            for index, (original, _) in enumerate(list(self.cached_target_profiles())):
                copy = backup / f"{index:03d}-{original.name}"
                shutil.copy2(original, copy)
                if sha(copy) != sha(original):
                    raise RenewalError("profile_backup_verification_failed")
                moved = backup / (copy.name + ".removed-from-cache")
                moves.append({"original": str(original), "backup": str(copy), "moved": str(moved)})
                atomic_json(self.run_dir / "profile-moves.json", moves)
                shutil.move(original, moved)
            yield
        finally:
            # Keep new valid profiles produced by Xcode. Restore old paths only
            # if no replacement exists, and never overwrite another file.
            old_hashes = {sha(Path(item["backup"])) for item in moves if Path(item["backup"]).exists()}
            replacements = [file for file, profile in self.cached_target_profiles()
                            if sha(file) not in old_hashes and utc(profile["ExpirationDate"]) > self.now()]
            if not replacements:
                for item in moves:
                    original, copy = Path(item["original"]), Path(item["backup"])
                    if not original.exists() and copy.is_file():
                        original.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(copy, original)
            atomic_json(self.run_dir / "profile-refresh-finished.json",
                        {"replacement_present": bool(replacements), "moves": moves})

    def xcode_args(self):
        return ["/usr/bin/xcrun", "xcodebuild", "-project", self.source / "OpenSidecar.xcodeproj",
                "-scheme", "OpenSidecariOS", "-configuration", "Debug", "-sdk", "iphoneos",
                "-destination", "id=" + self.c["device_udid"],
                "DEVELOPMENT_TEAM=" + self.c["team_id"]]

    def build_candidate(self, build: int, old_expiry: dt.datetime) -> Path:
        generator = shutil.which("xcodegen", path=self.env["PATH"])
        if not generator:
            raise RenewalError("xcodegen_missing")
        self.command([generator, "generate", "--spec", self.source / "project.yml"], "generate-project")
        _, _, log = self.command(self.xcode_args() + ["-showBuildSettings", "-json"], "build-settings")
        try:
            # xcodebuild may include warning/progress lines on stderr, which is
            # retained in the same complete log. Locate the actual JSON array.
            records = None
            text = log.read_text()
            for match in re.finditer(r"(?m)^\s*\[", text):
                try:
                    value, _ = json.JSONDecoder().raw_decode(text[match.end() - 1:])
                except ValueError:
                    continue
                if isinstance(value, list) and any(isinstance(item, dict) and "buildSettings" in item for item in value):
                    records = value
                    break
            if records is None:
                raise ValueError("missing build settings JSON")
            selected = [item["buildSettings"] for item in records if item.get("target") == "OpenSidecariOS"]
        except (ValueError, KeyError):
            raise RenewalError("invalid_build_settings")
        if len(selected) != 1 or selected[0].get("PRODUCT_BUNDLE_IDENTIFIER") != self.c["bundle_id"] or selected[0].get("DEVELOPMENT_TEAM") != self.c["team_id"] or selected[0].get("CODE_SIGN_STYLE") != "Automatic":
            raise RenewalError("wrong_build_signing_identity")
        derived = Path(self.c["derived_data"])
        # This scheme contains only the iOS target; showBuildSettings above
        # validates that target's effective bundle and signing identity.
        with self.refreshed_profiles():
            self.command(["/usr/bin/xcrun", "xcodebuild", "-project", self.source / "OpenSidecar.xcodeproj",
                "-scheme", "OpenSidecariOS", "-configuration", "Debug", "-sdk", "iphoneos",
                "-destination", "id=" + self.c["device_udid"], "-derivedDataPath", derived,
                "-allowProvisioningUpdates", "DEVELOPMENT_TEAM=" + self.c["team_id"],
                "MARKETING_VERSION=" + self.c["version"], "CURRENT_PROJECT_VERSION=" + str(build),
                "build"], "build-ios", timeout=900)
            products = derived / "Build/Products/Debug-iphoneos"
            matches = []
            for app in products.glob("*.app"):
                try:
                    info = plistlib.loads((app / "Info.plist").read_bytes())
                except (OSError, ValueError):
                    continue
                if info.get("CFBundleIdentifier") == self.c["bundle_id"]:
                    matches.append(app)
            if len(matches) != 1:
                raise RenewalError("built_app_not_unique")
            self.validate_app(matches[0], build, old_expiry)
            self.verify_manifest()  # build hooks must not mutate frozen inputs
            app = self.run_dir / "app" / matches[0].name
            app.parent.mkdir()
            shutil.copytree(matches[0], app, symlinks=True)
            self.validate_app(app, build, old_expiry)
            return app

    def validate_app(self, app: Path, build: int, old_expiry: dt.datetime, *, require_remaining=True):
        info = plistlib.loads((app / "Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != self.c["bundle_id"] or str(info.get("CFBundleVersion")) != str(build) or info.get("CFBundleShortVersionString") != self.c["version"]:
            raise RenewalError("candidate_bundle_identity_mismatch")
        self.command(["/usr/bin/codesign", "--verify", "--deep", "--strict", app], "verify-code-signature")
        _, _, log = self.command(["/usr/bin/codesign", "-dv", "--verbose=4", app], "signature-identity")
        signed = dict(line.split("=", 1) for line in log.read_text(errors="replace").splitlines() if "=" in line)
        if signed.get("Identifier") != self.c["bundle_id"] or signed.get("TeamIdentifier") != self.c["team_id"]:
            raise RenewalError("candidate_signature_identity_mismatch")
        profile = self.decode_profile(app / "embedded.mobileprovision")
        if not self.is_target_profile(profile) or self.c["device_udid"] not in profile.get("ProvisionedDevices", []):
            raise RenewalError("candidate_profile_identity_mismatch")
        expiry = utc(profile["ExpirationDate"])
        if expiry <= old_expiry + dt.timedelta(seconds=60) or (require_remaining and expiry - self.now() <= dt.timedelta(hours=48)):
            raise RenewalError("profile_expiry_not_extended")
        return profile

    @staticmethod
    def app_hash(app: Path) -> str:
        digest = hashlib.sha256()
        for file in sorted(app.rglob("*")):
            relative = str(file.relative_to(app)).encode()
            if file.is_symlink():
                digest.update(b"L\0" + relative + b"\0" + os.readlink(file).encode() + b"\0")
            elif file.is_file():
                digest.update(b"F\0" + relative + b"\0" + sha(file).encode() + b"\0")
        return digest.hexdigest()

    def validate_pending(self, pending, *, require_remaining=True):
        if any(pending.get(k) != v for k, v in self.identity().items()) or pending.get("version") != self.c["version"]:
            raise RenewalError("pending_identity_mismatch")
        app = Path(pending["app_path"]).resolve()
        if not app.is_relative_to(self.root / "runs") or app.suffix != ".app" or not app.is_dir():
            raise RenewalError("pending_candidate_missing_or_unsafe")
        if pending.get("source_manifest_sha256") != sha(Path(self.c["manifest_path"])) or self.app_hash(app) != pending.get("app_sha256"):
            raise RenewalError("pending_candidate_changed")
        profile = self.validate_app(app, int(pending["build"]), utc(pending["old_expiry"]),
                                    require_remaining=require_remaining)
        if sha(app / "embedded.mobileprovision") != pending.get("profile_sha256") or iso(utc(profile["ExpirationDate"])) != pending.get("expiry"):
            raise RenewalError("pending_profile_changed")

    def receipt(self, pending):
        destination = self.run_dir / f"receipt-{self.sequence + 1}.json"
        result = self.device_json(["copy", "from", "--source", "Documents/opendisplay-installation.json",
            "--destination", destination, "--domain-type", "appDataContainer",
            "--domain-identifier", self.c["bundle_id"]], "copy-receipt", required=False)
        if result is None or not destination.is_file():
            return None
        try:
            receipt = load_json(destination)
            matches = (receipt.get("bundleID") == self.c["bundle_id"]
                       and receipt.get("version") == pending["version"]
                       and str(receipt.get("build")) == str(pending["build"])
                       and receipt.get("profileSHA256") == pending["profile_sha256"]
                       and utc(receipt.get("launchedAt")) >= utc(pending["created_at"]) - dt.timedelta(seconds=60)
                       and utc(receipt.get("launchedAt")) <= self.now() + dt.timedelta(minutes=5))
            return receipt if matches else None
        except (ValueError, TypeError):
            return None

    def finish_pending(self, pending, installed):
        current, desired = self.installed_build(installed), int(pending["build"])
        self.validate_pending(pending, require_remaining=current < desired)
        if current > desired:
            raise RenewalError("installed_build_newer_than_pending")
        if current < desired:
            # Exactly one install attempt in this run. After any uncertain
            # outcome, inspect installation/launch/receipt; never retry blindly.
            pending["last_install_attempt_at"] = iso(self.now())
            atomic_json(self.root / "pending.json", pending)
            installed = self.probe_device()  # re-check cable/lock immediately before install
            if self.installed_build(installed) != current:
                raise RenewalError("installed_build_changed_before_install", "deferred")
            self.device_json(["install", "app", pending["app_path"]], "install-app", required=False)
        installed = self.probe_device()  # also prevents wireless-only launch after unplugging
        # Already installed on a previous attempt? Only launch and read back.
        self.device_json(["process", "launch", self.c["bundle_id"]], "launch-app", required=False)
        receipt = self.receipt(pending)
        if receipt is None:
            # Receipt creation is asynchronous on launch. Read once more without
            # reinstalling or relaunching; the next hourly run can also recover.
            time.sleep(1)
            receipt = self.receipt(pending)
        if receipt is None:
            reason = ("installation_unconfirmed_pending_retained" if self.installed_build(installed) != desired
                      else "launch_receipt_unconfirmed_pending_retained")
            raise RenewalError(reason)
        if self.installed_build(self.installed_app()) != desired:
            raise RenewalError("installation_unconfirmed_pending_retained")
        self.state.update({"current_build": desired, "expiry": pending["expiry"],
                           "profile_sha256": pending["profile_sha256"],
                           "last_success_at": iso(self.now()), "receipt": receipt})
        # Commit state first. A crash before archiving pending is harmless: its
        # next recovery sees this installed build and verifies without reinstall.
        atomic_json(self.root / "state.json", self.state)
        atomic_json(self.run_dir / "confirmed-receipt.json", receipt)
        os.replace(self.root / "pending.json", self.run_dir / "confirmed-pending.json")
        return self.result("renewed", "installed_and_launch_verified", build=desired, expiry=pending["expiry"])


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--run", action="store_true")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args(argv)
    if not args.config.is_absolute() or args.force and not args.run:
        parser.error("--config must be absolute; --force requires --run")
    os.umask(0o077)
    try:
        result = Renewal(load_json(args.config)).run(execute=args.run, force=args.force)
    except Exception as error:
        result = {"status": "failed", "reason": error.reason if isinstance(error, RenewalError)
                  else "invalid_configuration_" + type(error).__name__}
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 1 if result["status"] == "failed" else 0


if __name__ == "__main__":
    sys.exit(main())
