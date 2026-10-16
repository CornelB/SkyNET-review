#!/usr/bin/env python3
"""Print the weekly Codex usage for the codex seat's model rule.

Output, one line: <percent used, rounded up>|<source>
Sources, in order:
  live      `codex app-server`, JSON-RPC `account/rateLimits/read`. No model turn.
  snapshot  the last `rate_limits` event in the newest rollouts under
            $CODEX_HOME/sessions. Written on each Codex turn, so it can be old.
A window whose reset time has passed counts as 0%.
Exit 0 with data, 2 when no source has a weekly window.
"""
import json
import math
import os
import queue
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

LIVE_TIMEOUT_S = 10
WEEK_MINS = 10080


def read_live():
    exe = shutil.which("codex")
    if not exe:
        raise RuntimeError("codex not on PATH")
    proc = subprocess.Popen([exe, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True, cwd=str(Path.home()))
    lines = queue.Queue()
    threading.Thread(target=lambda: [lines.put(line) for line in proc.stdout], daemon=True).start()
    try:
        for msg in ({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                     "params": {"clientInfo": {"name": "review-council", "version": "1"}}},
                    {"jsonrpc": "2.0", "method": "initialized"},
                    {"jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read"}):
            proc.stdin.write(json.dumps(msg) + "\n")
        proc.stdin.flush()
        deadline = time.monotonic() + LIVE_TIMEOUT_S
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                raise RuntimeError("app-server gave no answer")
            try:
                msg = json.loads(lines.get(timeout=left))
            except (queue.Empty, json.JSONDecodeError):
                continue
            if msg.get("id") != 2:
                continue
            if "error" in msg:
                raise RuntimeError("app-server error")
            rl = msg["result"].get("rateLimits") or {}
            return [(w.get("usedPercent"), w.get("windowDurationMins"), w.get("resetsAt"))
                    for w in (rl.get("primary"), rl.get("secondary")) if w]
    finally:
        proc.kill()


def read_snapshot():
    home = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")
    rollouts = sorted((home / "sessions").glob("*/*/*/rollout-*.jsonl"),
                      key=lambda p: p.stat().st_mtime, reverse=True)
    for path in rollouts[:20]:
        last = None
        with path.open(encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if '"rate_limits"' not in line:
                    continue
                try:
                    rl = (json.loads(line).get("payload") or {}).get("rate_limits")
                except json.JSONDecodeError:
                    continue
                if rl:
                    last = rl
        if last:
            return [(w.get("used_percent"), w.get("window_minutes"), w.get("resets_at"))
                    for w in (last.get("primary"), last.get("secondary")) if w]
    raise RuntimeError("no rate_limits event")


def main():
    now = time.time()
    for name, reader in (("live", read_live), ("snapshot", read_snapshot)):
        try:
            windows = reader()
        except Exception:  # noqa: BLE001 - every failure falls through to the next source
            continue
        for used, mins, resets_at in windows:
            if mins != WEEK_MINS:
                continue
            pct = 0 if resets_at is not None and resets_at <= now else math.ceil(float(used or 0))
            print(f"{pct}|{name}")
            return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
