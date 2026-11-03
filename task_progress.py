#!/usr/bin/env python3
import argparse
import json
import subprocess
import time
from datetime import datetime
from pathlib import Path


def last_activity(transcript, started_epoch, now_epoch):
    latest = 0
    with Path(transcript).open() as source:
        for line in source:
            try:
                record = json.loads(line)
                if record.get("type") not in {"user", "assistant"}:
                    continue
                stamp = datetime.fromisoformat(record["timestamp"].replace("Z", "+00:00")).timestamp()
                if started_epoch <= stamp <= now_epoch:
                    latest = max(latest, int(stamp))
            except (ValueError, KeyError, TypeError, AttributeError):
                continue
    return latest


def task_progress(task_id, session, socket, result_dir, started_epoch):
    metadata = json.loads((Path(result_dir) / "sessions" / session / "task-meta.json").read_text())
    if metadata.get("task_id") != task_id or metadata.get("tmux_session") != session:
        return {"owned": False, "last_activity": 0}
    pane_pid = subprocess.check_output(
        ["tmux", "-S", socket, "display-message", "-p", "-t", session + ":0.0", "#{pane_pid}"],
        text=True, stderr=subprocess.DEVNULL, timeout=5,
    ).strip()
    candidates = subprocess.run(
        ["pgrep", "-P", pane_pid, "-f", "claude"],
        capture_output=True, text=True, timeout=5,
    ).stdout.split()
    for process_id in [pane_pid, *candidates]:
        try:
            environment = Path("/proc", process_id, "environ").read_bytes().split(b"\0")
            if ("CODING_AGENT_TASK_ID=" + task_id).encode() not in environment:
                continue
            registry = json.loads((Path.home() / ".claude" / "sessions" / (process_id + ".json")).read_text())
            session_id = registry.get("sessionId", "")
            if not session_id or Path(session_id).name != session_id:
                continue
            project = Path.home() / ".claude" / "projects"
            transcripts = list(project.glob("*/" + session_id + ".jsonl"))
            if len(transcripts) == 1:
                return {
                    "owned": True,
                    "last_activity": last_activity(transcripts[0], started_epoch, time.time()),
                }
        except (OSError, ValueError, TypeError):
            continue
    return {"owned": False, "last_activity": 0}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("task_id")
    parser.add_argument("session")
    parser.add_argument("socket")
    parser.add_argument("result_dir")
    parser.add_argument("started_epoch", type=int)
    args = parser.parse_args()
    try:
        result = task_progress(**vars(args))
    except (OSError, ValueError, TypeError, subprocess.SubprocessError):
        result = {"owned": False, "last_activity": 0}
    print(json.dumps(result))


if __name__ == "__main__":
    main()
