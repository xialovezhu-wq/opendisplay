#!/usr/bin/env python3
"""Native macOS renewal entry point; no Codex process, model, or API is used."""
from pathlib import Path
import datetime, json, os, sys
import renew_ipad

def cadence_gate(config, now):
    state_root = Path(config["state_root"])
    if (state_root / "pending.json").exists():
        return None
    state_path = state_root / "state.json"
    if not state_path.exists():
        return None
    state = renew_ipad.load_json(state_path)
    anchor = state.get("last_success_at")
    if not anchor:
        return None
    due = renew_ipad.utc(anchor) + datetime.timedelta(days=float(config.get("cadence_days", 3)))
    if now < due:
        return {"status": "quiet_cadence_wait", "reason": "three_day_cadence_not_due",
                "checked_at": renew_ipad.iso(now), "next_renewal_due": renew_ipad.iso(due)}
    return None

if __name__ == "__main__":
    os.umask(0o077)
    root = Path(__file__).resolve().parent
    now = datetime.datetime.now(datetime.timezone.utc)
    context = {"started_at": now.isoformat(), "pid": os.getpid(), "parent_pid": os.getppid(),
               "python": sys.executable, "working_directory": os.getcwd(),
               "service": os.environ.get("OPENDISPLAY_RENEWAL_SERVICE", "manual")}
    with (root / "logs" / "launch-context.jsonl").open("a", encoding="utf-8") as output:
        output.write(json.dumps(context, ensure_ascii=False) + "\n")
    try:
        config_path = Path(sys.argv[sys.argv.index("--config") + 1])
        config = renew_ipad.load_json(config_path)
        result = None if "--force" in sys.argv else cadence_gate(config, now)
        if result:
            renew_ipad.atomic_json(root / "logs" / "cadence-status.json", result)
            print(json.dumps(result, ensure_ascii=False, sort_keys=True))
            raise SystemExit(0)
    except (OSError, ValueError, KeyError, IndexError):
        # The normal entry point reports malformed config/state; do not mask it.
        pass
    raise SystemExit(renew_ipad.main())
