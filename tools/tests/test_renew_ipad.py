"""Deterministic command doubles: never contact a device or touch user profiles."""
import datetime as dt
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("renew_ipad", Path(__file__).parents[1] / "renew_ipad.py")
renew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renew)


class FakeRunner:
    def __init__(self, config, now):
        self.c, self.now = config, now
        self.calls = []
        self.installed = 181
        self.device = config["device_id"]
        self.bundle = config["bundle_id"]
        self.locked = False
        self.receipt = None

    def run(self, argv, log, timeout, **kwargs):
        self.calls.append(argv)
        log.write_bytes(b"")
        if argv[0].endswith("security"):
            log.write_bytes(Path(argv[-1]).read_bytes())
        elif argv[0].endswith("codesign"):
            if "-dv" in argv:
                log.write_text(f"Identifier={self.c['bundle_id']}\nTeamIdentifier={self.c['team_id']}\n")
        elif argv[1:3] == ["devicectl", "device"]:
            command = argv[3:5]
            result = {"deviceIdentifier": self.device}
            if command == ["info", "details"]:
                result = {"identifier": self.device, "properties": {
                    "connection": {"transportType": "wired", "pairingState": "paired", "state": "connected"},
                    "hardware": {"udid": self.c["device_udid"]}}}
            elif command == ["info", "lockState"]:
                result.update(passcodeRequired=self.locked, unlockedSinceBoot=True)
            elif command == ["info", "apps"]:
                result["apps"] = [{"bundleIdentifier": self.bundle, "bundleVersion": str(self.installed),
                                   "version": self.c["version"], "builtByDeveloper": True}]
            elif command == ["install", "app"]:
                info = plistlib.loads((Path(argv[-1]) / "Info.plist").read_bytes())
                self.installed = int(info["CFBundleVersion"])
            elif command == ["process", "launch"]:
                # devicectl treats tokens after the bundle as app arguments.
                # This catches the real failure where --device was swallowed.
                if argv.index(self.c["bundle_id"]) < argv.index("--device"):
                    log.write_text("Missing expected argument --device")
                    return 1, False
            elif command == ["copy", "from"]:
                if self.receipt is None:
                    return 1, False
                Path(argv[argv.index("--destination") + 1]).write_text(json.dumps(self.receipt))
            Path(argv[argv.index("--json-output") + 1]).write_text(
                json.dumps({"info": {"outcome": "success"}, "result": result}))
        else:
            raise AssertionError(f"Unexpected command: {argv[0:4]}")
        return 0, False


class RenewalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.now = dt.datetime(2026, 10, 21, 12, tzinfo=renew.UTC)
        source = self.base / "source"
        source.mkdir()
        (source / "project.yml").write_text("name: OpenSidecar\n")
        manifest = self.base / "manifest.json"
        renew.atomic_json(manifest, {"project.yml": renew.sha(source / "project.yml")})
        self.config = {"source_root": str(source), "manifest_path": str(manifest),
            "derived_data": str(self.base / "derived"), "state_root": str(self.base / "state"),
            "bundle_id": renew.EXPECTED_BUNDLE, "team_id": "ABCDE12345", "device_id": "device-uuid",
            "device_udid": "device-udid", "version": "1.25.0", "initial_build": 181,
            "initial_expiry": renew.iso(self.now + dt.timedelta(days=6)),
            "initial_profile_sha256": "0" * 64, "threshold_hours": 48}
        self.runner = FakeRunner(self.config, self.now)
        self.renewal = renew.Renewal(self.config, runner=self.runner, now=lambda: self.now,
                                     home=self.base / "fake-home")

    def app(self, *, build=182, expiry=None):
        app = self.base / "state/runs/candidate/app/OpenDisplay Dev.app"
        app.mkdir(parents=True, exist_ok=True)
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": renew.EXPECTED_BUNDLE,
            "CFBundleVersion": str(build), "CFBundleShortVersionString": "1.25.0"}))
        (app / "embedded.mobileprovision").write_bytes(plistlib.dumps(self.profile(expiry=expiry)))
        return app

    def profile(self, *, expiry=None, bundle=None, team=None):
        team = team or self.config["team_id"]
        return {"TeamIdentifier": [team], "ProvisionedDevices": [self.config["device_udid"]],
            "ExpirationDate": (expiry or self.now + dt.timedelta(days=7)).replace(tzinfo=None),
            "Entitlements": {"application-identifier": team + "." + (bundle or renew.EXPECTED_BUNDLE),
                             "com.apple.developer.team-identifier": team}}

    def pending(self, *, expiry=None):
        app = self.app(expiry=expiry)
        pending = {**self.renewal.identity(), "version": "1.25.0", "build": 182,
            "created_at": renew.iso(self.now - dt.timedelta(minutes=2)),
            "old_expiry": renew.iso(self.now - dt.timedelta(days=1)),
            "app_path": str(app), "app_sha256": self.renewal.app_hash(app),
            "profile_sha256": renew.sha(app / "embedded.mobileprovision"),
            "expiry": renew.iso(expiry or self.now + dt.timedelta(days=7)),
            "source_manifest_sha256": renew.sha(Path(self.config["manifest_path"]))}
        renew.atomic_json(self.base / "state/pending.json", pending)
        return pending

    def test_not_due_is_quiet_and_runs_no_commands(self):
        result = self.renewal.run(execute=True)
        self.assertEqual(result["status"], "quiet_not_due")
        self.assertEqual(self.runner.calls, [])

    def test_only_exact_team_and_app_profiles_are_moved_and_originals_restored(self):
        self.renewal.run_dir = self.base / "run"
        self.renewal.run_dir.mkdir()
        cache = self.renewal.profile_directories()[0]
        cache.mkdir(parents=True)
        entries = {"ours.mobileprovision": self.profile(),
                   "other.mobileprovision": self.profile(bundle="another.application"),
                   "wildcard.mobileprovision": self.profile(bundle="*"),
                   "wrong-team.mobileprovision": self.profile(team="OTHER12345")}
        for name, profile in entries.items():
            (cache / name).write_bytes(plistlib.dumps(profile))
        with self.renewal.refreshed_profiles():
            self.assertFalse((cache / "ours.mobileprovision").exists())
            for name in entries.keys() - {"ours.mobileprovision"}:
                self.assertTrue((cache / name).exists())
        self.assertTrue((cache / "ours.mobileprovision").exists())

    def test_unextended_profile_never_reaches_install(self):
        app = self.app(expiry=renew.utc(self.config["initial_expiry"]))
        def candidate(build, expiry):
            self.renewal.validate_app(app, build, expiry)
            return app
        with patch.object(self.renewal, "build_candidate", side_effect=candidate):
            result = self.renewal.run(execute=True, force=True)
        self.assertEqual(result["reason"], "profile_expiry_not_extended")
        self.assertFalse(any(call[3:5] == ["install", "app"] for call in self.runner.calls))
        self.assertFalse((self.base / "state/pending.json").exists())

    def test_pending_already_installed_recovers_by_launch_receipt_without_reinstall(self):
        pending = self.pending()
        self.runner.installed = 182
        self.runner.receipt = {"bundleID": renew.EXPECTED_BUNDLE, "version": "1.25.0", "build": "182",
            "profileSHA256": pending["profile_sha256"], "launchedAt": renew.iso(self.now)}
        result = self.renewal.run(execute=True)
        self.assertEqual(result["status"], "renewed")
        self.assertFalse(any(call[3:5] == ["install", "app"] for call in self.runner.calls))
        self.assertTrue(any(call[3:5] == ["process", "launch"] for call in self.runner.calls))
        self.assertFalse((self.base / "state/pending.json").exists())
        self.assertTrue((Path(result["run_dir"]) / "confirmed-pending.json").exists())

    def test_installed_pending_with_less_than_48_hours_can_be_committed(self):
        pending = self.pending(expiry=self.now + dt.timedelta(hours=3))
        self.runner.installed = 182
        self.runner.receipt = {"bundleID": renew.EXPECTED_BUNDLE, "version": "1.25.0", "build": 182,
            "profileSHA256": pending["profile_sha256"], "launchedAt": renew.iso(self.now)}
        result = self.renewal.run(execute=True)
        self.assertEqual(result["status"], "renewed")
        self.assertEqual(result["expiry"], pending["expiry"])

    def test_pending_install_launch_and_receipt_commit_once_then_skip(self):
        pending = self.pending()
        self.runner.receipt = {"bundleID": renew.EXPECTED_BUNDLE, "version": "1.25.0", "build": 182,
            "profileSHA256": pending["profile_sha256"], "launchedAt": renew.iso(self.now)}
        result = self.renewal.run(execute=True)
        self.assertEqual(result["status"], "renewed")
        installs = [c for c in self.runner.calls if c[3:5] == ["install", "app"]]
        self.assertEqual(len(installs), 1)
        self.assertEqual(installs[0][-1], pending["app_path"])
        launch = next(c for c in self.runner.calls if c[3:5] == ["process", "launch"])
        self.assertLess(launch.index("--device"), launch.index(self.config["bundle_id"]))
        count = len(self.runner.calls)
        self.assertEqual(self.renewal.run(execute=True)["status"], "quiet_not_due")
        self.assertEqual(len(self.runner.calls), count)

    def test_uninstalled_stale_pending_is_archived_before_new_build(self):
        self.pending(expiry=self.now + dt.timedelta(hours=3))
        with patch.object(self.renewal, "build_candidate", side_effect=renew.RenewalError("test_build_reached")) as build:
            result = self.renewal.run(execute=True)
        build.assert_called_once()
        self.assertEqual(result["reason"], "test_build_reached")
        self.assertTrue((Path(result["run_dir"]) / "stale-pending.json").exists())
        self.assertFalse(any(call[3:5] == ["install", "app"] for call in self.runner.calls))

    def test_wrong_device_or_bundle_is_refused_before_build_or_install(self):
        self.runner.device = "another-device"
        result = self.renewal.run(execute=True, force=True)
        self.assertEqual(result["reason"], "wrong_device")
        self.now += dt.timedelta(seconds=1)
        self.runner.device = self.config["device_id"]
        self.runner.bundle = "another.application"
        result = self.renewal.run(execute=True, force=True)
        self.assertEqual(result["reason"], "target_app_missing_or_wrong_bundle")
        self.assertFalse(any("xcodebuild" in call or call[3:5] == ["install", "app"] for call in self.runner.calls))

    def test_locked_device_is_deferred(self):
        self.runner.locked = True
        result = self.renewal.run(execute=True, force=True)
        self.assertEqual(result["status"], "deferred")
        self.assertEqual(result["reason"], "device_locked")

    def test_newer_feature_build_is_not_replaced_by_frozen_source(self):
        self.runner.installed = 190
        result = self.renewal.run(execute=True, force=True)
        self.assertEqual(result["reason"], "installed_build_changed_update_snapshot")
        self.assertFalse(any("xcodebuild" in c or c[3:5] == ["install", "app"] for c in self.runner.calls))


if __name__ == "__main__":
    unittest.main()
