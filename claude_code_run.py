#!/usr/bin/env python3
"""Run Claude Code (claude CLI) reliably.

Default mode is *auto*:
- If the prompt looks like it uses interactive slash commands (e.g. /speckit.*)
  we start an interactive Claude Code session in tmux (PTY).
- Otherwise we run headless (-p) through `script(1)` to force a pseudo-terminal.

Why this wrapper exists:
- Claude Code can hang when run without a TTY.
- CI / exec environments are often non-interactive.

Docs:
- Headless: https://code.claude.com/docs/en/headless
- Agent Teams: https://code.claude.com/docs/en/agent-teams
"""

from __future__ import annotations

import argparse
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path


def which(name: str) -> str | None:
    paths = os.environ.get("PATH", "").split(":")
    for p in paths:
        cand = Path(p) / name
        try:
            if cand.is_file() and os.access(cand, os.X_OK):
                return str(cand)
        except OSError:
            pass
    return None


# 三层兜底：CLAUDE_CODE_BIN 环境变量 → PATH 里查找 claude → 硬编码 /usr/local/bin/claude
# 学员机器上 claude 可能装在 /usr/bin/claude 或 nvm 路径下，前两层会自动适配
DEFAULT_CLAUDE = (
    os.environ.get("CLAUDE_CODE_BIN")
    or which("claude")
    or "/usr/local/bin/claude"
)


def looks_like_slash_commands(prompt: str | None) -> bool:
    if not prompt:
        return False
    for line in prompt.splitlines():
        if line.strip().startswith("/"):
            return True
    return False


def build_headless_cmd(args: argparse.Namespace) -> list[str]:
    cmd: list[str] = [args.claude_bin]

    # Model override: CLI arg > ANTHROPIC_MODEL env var
    model = getattr(args, "model", None) or os.environ.get("ANTHROPIC_MODEL", "")
    if model:
        cmd += ["--model", model]

    if args.permission_mode:
        cmd += ["--permission-mode", args.permission_mode]

    if args.prompt is not None:
        cmd += ["-p", args.prompt]

    if args.allowedTools:
        cmd += ["--allowedTools", args.allowedTools]

    if args.output_format:
        cmd += ["--output-format", args.output_format]

    if args.json_schema:
        cmd += ["--json-schema", args.json_schema]

    if args.append_system_prompt:
        cmd += ["--append-system-prompt", args.append_system_prompt]

    if args.system_prompt:
        cmd += ["--system-prompt", args.system_prompt]

    if args.continue_latest:
        cmd.append("--continue")

    if args.resume:
        cmd += ["--resume", args.resume]

    # Agent Teams support
    if args.teammate_mode:
        cmd += ["--teammate-mode", args.teammate_mode]

    if args.extra:
        cmd += args.extra

    return cmd


def build_agent_teams_env(args: argparse.Namespace) -> dict[str, str]:
    """Build environment dict with Agent Teams support."""
    env = os.environ.copy()
    if args.agent_teams:
        env["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] = "1"
    return env


def run_with_pty(cmd: list[str], cwd: str | None, env: dict[str, str] | None = None) -> int:
    cmd_str = " ".join(shlex.quote(c) for c in cmd)

    script_bin = which("script")
    if not script_bin:
        proc = subprocess.run(cmd, cwd=cwd, text=True, env=env)
        return proc.returncode

    proc = subprocess.run([script_bin, "-q", "-c", cmd_str, "/dev/null"], cwd=cwd, text=True, env=env)
    return proc.returncode


def tmux_cmd(socket_path: str, *args: str) -> list[str]:
    return ["tmux", "-S", socket_path, *args]


def tmux_capture(socket_path: str, target: str, lines: int = 200) -> str:
    out = subprocess.check_output(
        tmux_cmd(socket_path, "capture-pane", "-p", "-J", "-t", target, "-S", f"-{lines}"),
        text=True,
    )
    return out


def tmux_wait_for_text(socket_path: str, target: str, pattern: str, timeout_s: int = 30, poll_s: float = 0.5) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            buf = tmux_capture(socket_path, target, lines=200)
            if pattern in buf:
                return True
        except subprocess.CalledProcessError:
            pass
        time.sleep(poll_s)
    return False


def tmux_wait_for_any_text(
    socket_path: str,
    target: str,
    patterns: list[str],
    timeout_s: int = 30,
    poll_s: float = 0.5,
) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            buf = tmux_capture(socket_path, target, lines=240)
            for pattern in patterns:
                if pattern in buf:
                    return True
        except subprocess.CalledProcessError:
            pass
        time.sleep(poll_s)
    return False


def input_box_has_content(socket_path: str, target: str) -> bool:
    """Check whether the Claude Code input box currently holds any content.

    Used to verify a tmux paste-buffer actually reached the CC input box:
    tmux can report a successful paste while the React/Ink input box drops
    the keystrokes during its startup focus-binding window. Returns True
    conservatively (capture failure or no '❯' marker) to avoid spurious
    retries that could double-inject the prompt.
    """
    try:
        buf = tmux_capture(socket_path, target, lines=24)
    except subprocess.CalledProcessError:
        return True
    lines = buf.splitlines()
    # Find the last input prompt line carrying the '❯' marker.
    for i in range(len(lines) - 1, -1, -1):
        if "❯" in lines[i]:
            after = lines[i].split("❯", 1)[-1]
            if after.strip():
                return True
            # Multiline input may wrap onto following lines. CC v2.x renders the
            # input box bounded by ───── frame lines; the bottom frame strips to
            # non-empty box-drawing chars, so without this guard it would be
            # mistaken for pasted content — making every empty box look
            # non-empty and defeating the paste retry (root cause of silent
            # empty-prompt injection failures, e.g. axe-rng refactor part1).
            for j in range(i + 1, min(i + 4, len(lines))):
                if _INPUT_FRAME_RE.fullmatch(lines[j]):
                    break
                if lines[j].strip():
                    return True
            return False
    return True


# CC v2.x input-box frame line (box-drawing chars only). Used to detect the
# bottom frame so it isn't mistaken for pasted content when checking whether
# the input box is empty after a paste.
_INPUT_FRAME_RE = re.compile(r"[\s─━┄┅┈┉═│║╮╯╰╭┌┐└┘├┤┬┴┼]+")


def run_interactive_tmux(args: argparse.Namespace) -> int:
    if not which("tmux"):
        print("tmux not found in PATH; cannot run interactive mode.", file=sys.stderr)
        return 2

    # Keep interactive dispatch sessions visible to the shared Claw Remote
    # backend. Allow an explicit env/CLI override for diagnostics, but default
    # to the global socket directory used by the panel.
    socket_dir = args.tmux_socket_dir or os.environ.get("CLAWDBOT_TMUX_SOCKET_DIR") or "/root/clawdbot-tmux-sockets"
    Path(socket_dir).mkdir(parents=True, exist_ok=True)
    socket_path = str(Path(socket_dir) / args.tmux_socket_name)

    session = args.tmux_session

    # Check if session exists
    session_exists = subprocess.run(
        tmux_cmd(socket_path, "has-session", "-t", session),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    ).returncode == 0

    cwd = args.cwd or os.getcwd()

    # If continuing and session exists, skip session creation
    session_ttl = int(os.environ.get("SESSION_TTL", "43200"))  # default 12 hours
    if args.continue_latest and session_exists:
        print(f"Continuing existing tmux session: {session}")
    else:
        # Kill old self-destruct timer to prevent race condition when cron period == SESSION_TTL
        try:
            result = subprocess.run(
                ["pgrep", "-f", f"sleep {session_ttl} && tmux -S.*kill-session -t {re.escape(session)}"],
                capture_output=True, text=True
            )
            for pid in filter(None, result.stdout.strip().split('\n')):
                subprocess.run(["kill", pid.strip()], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass
        # Kill old session if exists and create new one
        subprocess.run(tmux_cmd(socket_path, "kill-session", "-t", session), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.check_call(tmux_cmd(socket_path, "new", "-d", "-s", session, "-n", "shell"))

    # Resolve target dynamically so we respect any tmux base-index / pane-base-index
    # set in ~/.tmux.conf (e.g. base-index 1 would break a hardcoded ":0.0").
    target = subprocess.check_output(
        tmux_cmd(socket_path, "list-panes", "-t", session, "-F", "#{session_name}:#{window_index}.#{pane_index}"),
        text=True,
    ).strip().split("\n")[0]

    subprocess.Popen(
        ["setsid", "bash", "-c",
         f"sleep {session_ttl} && tmux -S {shlex.quote(socket_path)} kill-session -t {shlex.quote(session)} 2>/dev/null"],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )

    if not (args.continue_latest and session_exists):
        # Set Agent Teams env var inside tmux session if enabled
        if args.agent_teams:
            subprocess.check_call(tmux_cmd(socket_path, "send-keys", "-t", target, "-l", "--", "export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1"))
            subprocess.check_call(tmux_cmd(socket_path, "send-keys", "-t", target, "Enter"))
            time.sleep(0.3)

    # Set Anthropic API configuration at tmux server level (works for both new and existing sessions)
    anthropic_base_url = os.environ.get("ANTHROPIC_BASE_URL", "")
    anthropic_api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    anthropic_auth_token = os.environ.get("ANTHROPIC_AUTH_TOKEN", "")

    # Use tmux set-environment to set at server level (more reliable than send-keys)
    if anthropic_base_url:
        subprocess.check_call(tmux_cmd(socket_path, "set-environment", "-t", session, "ANTHROPIC_BASE_URL", anthropic_base_url))
        print("ANTHROPIC_BASE_URL injected into tmux session", flush=True)
    else:
        subprocess.run(
            tmux_cmd(socket_path, "set-environment", "-u", "-t", session, "ANTHROPIC_BASE_URL"),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )

    if anthropic_api_key:
        subprocess.check_call(tmux_cmd(socket_path, "set-environment", "-t", session, "ANTHROPIC_API_KEY", anthropic_api_key))
        print("ANTHROPIC_API_KEY injected into tmux session", flush=True)
    else:
        subprocess.run(
            tmux_cmd(socket_path, "set-environment", "-u", "-t", session, "ANTHROPIC_API_KEY"),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )

    if anthropic_auth_token:
        subprocess.check_call(tmux_cmd(socket_path, "set-environment", "-t", session, "ANTHROPIC_AUTH_TOKEN", anthropic_auth_token))
        print("ANTHROPIC_AUTH_TOKEN injected into tmux session", flush=True)
    else:
        # Unset ANTHROPIC_AUTH_TOKEN to avoid auth conflicts
        subprocess.run(
            tmux_cmd(socket_path, "set-environment", "-u", "-t", session, "ANTHROPIC_AUTH_TOKEN"),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )

    # Forward ANTHROPIC_MODEL to tmux session (CLI arg > env var)
    anthropic_model = getattr(args, "model", None) or os.environ.get("ANTHROPIC_MODEL", "")
    if anthropic_model:
        subprocess.check_call(tmux_cmd(socket_path, "set-environment", "-t", session, "ANTHROPIC_MODEL", anthropic_model))
        print(f"Set ANTHROPIC_MODEL={anthropic_model}")
    else:
        subprocess.run(
            tmux_cmd(socket_path, "set-environment", "-u", "-t", session, "ANTHROPIC_MODEL"),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )

    # Forward CLAUDE_CODE_EFFORT_LEVEL to tmux session (dispatch 路径默认 xhigh；
    # 显式 set-environment 覆盖会话从长驻 tmux server 继承的旧值，如历史遗留 max。
    # 手动 +GLM 不走此路径，effort_level 为空时不注入，保持原有继承行为)
    effort_level = os.environ.get("CLAUDE_CODE_EFFORT_LEVEL", "")
    if effort_level:
        subprocess.check_call(tmux_cmd(socket_path, "set-environment", "-t", session, "CLAUDE_CODE_EFFORT_LEVEL", effort_level))
        print(f"Set CLAUDE_CODE_EFFORT_LEVEL={effort_level}")

    # Also set via send-keys as backup (for shell processes that don't inherit tmux env)
    if not (args.continue_latest and session_exists):
        if anthropic_base_url:
            subprocess.check_call(tmux_cmd(socket_path, "send-keys", "-t", target, "-l", "--", f"export ANTHROPIC_BASE_URL={shlex.quote(anthropic_base_url)}"))
        else:
            subprocess.check_call(tmux_cmd(socket_path, "send-keys", "-t", target, "-l", "--", "unset ANTHROPIC_BASE_URL"))
        subprocess.check_call(tmux_cmd(socket_path, "send-keys", "-t", target, "Enter"))
        time.sleep(0.2)

        if anthropic_api_key:
            subprocess.check_call(tmux_cmd(socket_path, "send-keys", "-t", target, "-l", "--", f"export ANTHROPIC_API_KEY={shlex.quote(anthropic_api_key)}"))
        else:
            subprocess.check_call(tmux_cmd(socket_path, "send-keys", "-t", target, "-l", "--", "unset ANTHROPIC_API_KEY"))
        subprocess.check_call(tmux_cmd(socket_path, "send-keys", "-t", target, "Enter"))
        time.sleep(0.2)

        if anthropic_auth_token:
            subprocess.check_call(tmux_cmd(socket_path, "send-keys", "-t", target, "-l", "--", f"export ANTHROPIC_AUTH_TOKEN={shlex.quote(anthropic_auth_token)}"))
        else:
            subprocess.check_call(tmux_cmd(socket_path, "send-keys", "-t", target, "-l", "--", "unset ANTHROPIC_AUTH_TOKEN"))
        subprocess.check_call(tmux_cmd(socket_path, "send-keys", "-t", target, "Enter"))
        time.sleep(0.2)

        if anthropic_model:
            subprocess.check_call(tmux_cmd(socket_path, "send-keys", "-t", target, "-l", "--", f"export ANTHROPIC_MODEL={shlex.quote(anthropic_model)}"))
        else:
            subprocess.check_call(tmux_cmd(socket_path, "send-keys", "-t", target, "-l", "--", "unset ANTHROPIC_MODEL"))
        subprocess.check_call(tmux_cmd(socket_path, "send-keys", "-t", target, "Enter"))
        time.sleep(0.2)

        if effort_level:
            subprocess.check_call(tmux_cmd(socket_path, "send-keys", "-t", target, "-l", "--", f"export CLAUDE_CODE_EFFORT_LEVEL={shlex.quote(effort_level)}"))
            subprocess.check_call(tmux_cmd(socket_path, "send-keys", "-t", target, "Enter"))
            time.sleep(0.2)

    # Inject CODING_AGENT_* env vars for hook session isolation
    coding_agent_vars = {
        "CODING_AGENT_TASK_ID": os.environ.get("CODING_AGENT_TASK_ID", ""),
        "CODING_AGENT_SESSION_DIR": os.environ.get("CODING_AGENT_SESSION_DIR", ""),
        "CODING_AGENT_TMUX_SESSION": os.environ.get("CODING_AGENT_TMUX_SESSION", ""),
        "CODING_AGENT_WORKDIR": os.environ.get("CODING_AGENT_WORKDIR", ""),
    }
    for var_name, var_val in coding_agent_vars.items():
        if var_val:
            subprocess.check_call(tmux_cmd(socket_path, "set-environment", "-t", session, var_name, var_val))
            if not (args.continue_latest and session_exists):
                subprocess.check_call(tmux_cmd(socket_path, "send-keys", "-t", target, "-l", "--", f"export {var_name}={shlex.quote(var_val)}"))
                subprocess.check_call(tmux_cmd(socket_path, "send-keys", "-t", target, "Enter"))
                time.sleep(0.1)

    # Inject CLAW_REMOTE_* env vars for Claw Remote session tracking
    claw_remote_vars = {
        "CLAW_REMOTE_TMUX_SESSION": os.environ.get("CLAW_REMOTE_TMUX_SESSION", ""),
        "CLAW_REMOTE_SOURCE": os.environ.get("CLAW_REMOTE_SOURCE", ""),
    }
    for var_name, var_val in claw_remote_vars.items():
        if var_val:
            subprocess.check_call(tmux_cmd(socket_path, "set-environment", "-t", session, var_name, var_val))
            if not (args.continue_latest and session_exists):
                subprocess.check_call(tmux_cmd(socket_path, "send-keys", "-t", target, "-l", "--", f"export {var_name}={shlex.quote(var_val)}"))
                subprocess.check_call(tmux_cmd(socket_path, "send-keys", "-t", target, "Enter"))
                time.sleep(0.1)

    # Launch Claude Code (only for new sessions)
    if not (args.continue_latest and session_exists):
        claude_parts = [args.claude_bin]
        if args.permission_mode:
            claude_parts += ["--permission-mode", args.permission_mode]
        if args.allowedTools:
            claude_parts += ["--allowedTools", args.allowedTools]
        if args.append_system_prompt:
            claude_parts += ["--append-system-prompt", args.append_system_prompt]
        if args.system_prompt:
            claude_parts += ["--system-prompt", args.system_prompt]
        if args.continue_latest:
            claude_parts.append("--continue")
        if args.resume:
            claude_parts += ["--resume", args.resume]
        # Agent Teams teammate mode
        if args.teammate_mode:
            claude_parts += ["--teammate-mode", args.teammate_mode]
        if args.extra:
            claude_parts += args.extra

        launch = f"cd {shlex.quote(cwd)} && " + " ".join(shlex.quote(p) for p in claude_parts)
        subprocess.check_call(tmux_cmd(socket_path, "send-keys", "-t", target, "-l", "--", launch))
        subprocess.check_call(tmux_cmd(socket_path, "send-keys", "-t", target, "Enter"))

        # Workspace trust prompt (first run in a new folder).
        if tmux_wait_for_text(socket_path, target, "Yes, I trust this folder", timeout_s=20):
            subprocess.run(tmux_cmd(socket_path, "send-keys", "-t", target, "Enter"), check=False)
            time.sleep(0.8)
            if tmux_wait_for_text(socket_path, target, "Yes, I trust this folder", timeout_s=2):
                subprocess.run(tmux_cmd(socket_path, "send-keys", "-t", target, "1"), check=False)
                subprocess.run(tmux_cmd(socket_path, "send-keys", "-t", target, "Enter"), check=False)

    # Send prompt (works for both new and existing sessions)
    if args.prompt:
        # Wait until Claude UI is interactive before sending prompt.
        # 45s timeout: CC UI typically appears in 10-20s; must stay under openclaw exec timeout (~60-90s).
        ready = tmux_wait_for_any_text(
            socket_path,
            target,
            patterns=["shift+tab to cycle", "accept edits on", "❯"],
            timeout_s=45,
            poll_s=0.5,
        )
        if not ready:
            print("WARNING: Claude Code UI not ready after 45s, attempting paste anyway", file=sys.stderr)
        # Focus-binding window in CC v2.x can last several seconds after the
        # '❯' prompt first appears; pasting too early silently drops content
        # even though tmux reports a successful paste-buffer. Wait longer
        # before the first paste so the React/Ink input box fully binds focus.
        time.sleep(4.0)

        # Write prompt to a temporary file and use tmux load-buffer + paste-buffer
        # Use -p flag on paste-buffer to suppress bracketed paste escape sequences
        import tempfile
        with tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.txt') as f:
            f.write(args.prompt)
            temp_file = f.name

        try:
            # Paste the prompt and verify the input box actually received it.
            # paste-buffer can succeed at the tmux layer while the CC React/Ink
            # input box drops the content during its startup focus-binding
            # window; detect an empty input box and retry to avoid leaving the
            # session idle at a blank prompt.
            max_attempts = 6
            for attempt in range(1, max_attempts + 1):
                subprocess.check_call(tmux_cmd(socket_path, "load-buffer", temp_file))
                subprocess.check_call(tmux_cmd(socket_path, "paste-buffer", "-d", "-p", "-t", target))
                # Give React/Ink UI enough time to process and collapse pasted content.
                time.sleep(2.0)
                if input_box_has_content(socket_path, target):
                    break
                if attempt < max_attempts:
                    print(
                        f"WARNING: paste attempt {attempt}/{max_attempts} left input box empty; retrying",
                        file=sys.stderr,
                    )
                    time.sleep(2.0 * attempt)
            else:
                print(
                    f"WARNING: input box still empty after {max_attempts} paste attempts; "
                    f"CC startup focus-binding window may still be open (slow cold start / "
                    f"memory pressure, e.g. OOM-active server); waiting 10s for it to settle, "
                    f"then one final paste before Enter",
                    file=sys.stderr,
                )
                # Under memory pressure CC v2.x's startup focus-binding window can
                # outlast the retry span above, so every attempt lands inside the
                # drop window and the input box stays empty. Wait for the React/Ink
                # input box to fully bind focus, then do one final paste before the
                # Enter submit. This recovers the slow-cold-start case (e.g. refactor
                # part1 right after a heavy setup under memory contention) that the
                # fast retry loop misses. Worst case (still empty) is unchanged: the
                # Enter below is sent on an empty box and CC stays idle.
                time.sleep(10.0)
                subprocess.check_call(tmux_cmd(socket_path, "load-buffer", temp_file))
                subprocess.check_call(tmux_cmd(socket_path, "paste-buffer", "-d", "-p", "-t", target))
                time.sleep(2.0)
            # Send Enter to submit
            subprocess.check_call(tmux_cmd(socket_path, "send-keys", "-t", target, "Enter"))
            time.sleep(args.interactive_send_delay_ms / 1000.0)
        finally:
            Path(temp_file).unlink(missing_ok=True)

    print("Started interactive Claude Code in tmux.")
    print("To monitor:")
    print(f"  tmux -S {shlex.quote(socket_path)} attach -t {shlex.quote(session)}")
    print("To snapshot output:")
    print(f"  tmux -S {shlex.quote(socket_path)} capture-pane -p -J -t {shlex.quote(target)} -S -200")

    if args.interactive_wait_s > 0:
        time.sleep(args.interactive_wait_s)
        try:
            snap = tmux_capture(socket_path, target, lines=200)
            print("\n--- tmux snapshot (last 200 lines) ---\n")
            print(snap)
        except subprocess.CalledProcessError:
            pass

    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Run Claude Code reliably (headless or interactive via tmux)")

    ap.add_argument("-p", "--prompt", help="Prompt text. In headless mode this is passed via -p. In interactive mode it is sent as keystrokes.")
    ap.add_argument(
        "--mode",
        choices=["auto", "headless", "interactive"],
        default="auto",
        help="Execution mode. auto switches to interactive when prompt contains slash commands (lines starting with '/').",
    )

    ap.add_argument(
        "--permission-mode",
        default=None,
        help=(
            "Claude Code permission mode (passed through to `claude --permission-mode`). "
            "Common values include: plan, acceptEdits, dontAsk, bypassPermissions, default."
        ),
    )

    ap.add_argument("--allowedTools", dest="allowedTools", help="Allowed tools allowlist string")
    ap.add_argument("--output-format", dest="output_format", choices=["text", "json", "stream-json"], help="Output format (headless)")
    ap.add_argument("--json-schema", dest="json_schema", help="JSON schema (string) when using --output-format json")
    ap.add_argument("--model", help="Model override (e.g. claude-sonnet-4-6). Falls back to ANTHROPIC_MODEL env var.")

    ap.add_argument("--append-system-prompt", dest="append_system_prompt", help="Append to Claude Code default system prompt")
    ap.add_argument("--system-prompt", dest="system_prompt", help="Replace system prompt")

    ap.add_argument("--continue", dest="continue_latest", action="store_true", help="Continue the most recent session")
    ap.add_argument("--resume", help="Resume a specific session ID")

    # Agent Teams options
    ap.add_argument(
        "--agent-teams",
        action="store_true",
        help="Enable Agent Teams (sets CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1). Allows spawning multiple coordinated Claude Code instances.",
    )
    ap.add_argument(
        "--teammate-mode",
        choices=["auto", "in-process", "tmux"],
        default=None,
        help="Agent Teams display mode. auto (default) uses in-process; tmux creates split panes.",
    )

    ap.add_argument(
        "--claude-bin",
        default=DEFAULT_CLAUDE,
        help=f"Path to claude binary (default: {DEFAULT_CLAUDE}). You can also set CLAUDE_CODE_BIN.",
    )

    ap.add_argument("--cwd", help="Working directory to run claude in (defaults to current directory)")

    ap.add_argument("--tmux-session", default="cc", help="tmux session name (interactive mode)")
    ap.add_argument("--tmux-socket-dir", default=None, help="tmux socket dir (defaults to $CLAWDBOT_TMUX_SOCKET_DIR or /root/clawdbot-tmux-sockets)")
    ap.add_argument("--tmux-socket-name", default="claude-code.sock", help="tmux socket file name")
    ap.add_argument("--interactive-wait-s", type=int, default=0, help="Wait N seconds then print a tmux output snapshot")
    ap.add_argument("--interactive-send-delay-ms", type=int, default=800, help="Delay between sending lines in interactive mode")

    ap.add_argument("extra", nargs=argparse.REMAINDER, help="Extra args after --")

    args = ap.parse_args()

    extra = args.extra
    if extra and extra[0] == "--":
        extra = extra[1:]
    args.extra = extra

    if not Path(args.claude_bin).exists():
        print(f"claude binary not found: {args.claude_bin}", file=sys.stderr)
        print("Tip: set CLAUDE_CODE_BIN=/path/to/claude", file=sys.stderr)
        return 2

    mode = args.mode
    if mode == "auto" and looks_like_slash_commands(args.prompt):
        mode = "interactive"

    if mode == "interactive":
        return run_interactive_tmux(args)

    cmd = build_headless_cmd(args)
    env = build_agent_teams_env(args)
    return run_with_pty(cmd, cwd=args.cwd, env=env)


if __name__ == "__main__":
    raise SystemExit(main())
