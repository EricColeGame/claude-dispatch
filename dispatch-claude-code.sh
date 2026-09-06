#!/bin/bash
# dispatch-claude-code.sh — Dispatch a task to Claude Code with auto-callback
#
# Usage:
#   dispatch-claude-code.sh [OPTIONS] -p "your prompt here"
#
# Options:
#   -p, --prompt TEXT        Task prompt (required)
#   -n, --name NAME          Task name (for tracking)
#   -g, --group, --target ID Feishu target; injected into the task prompt and environment
#   --cdp PORT               Browser CDP port; injected into the task prompt and environment
#   -s, --session KEY        Callback session key (AGI session to notify)
#   -w, --workdir DIR        Working directory for Claude Code
#   --agent-teams            Enable Agent Teams (lead + sub-agents)
#   --teammate-mode MODE     Agent Teams display mode (auto/in-process/tmux)
#   --permission-mode MODE   Claude Code permission mode
#   --allowed-tools TOOLS    Allowed tools string
#   --model MODEL            Model override
#   --effort LEVEL           Effort 等级（low/medium/high/xhigh/max，默认 xhigh）
#   --tmux                   Enable tmux interactive mode (DEFAULT)
#   --no-tmux                Disable tmux, use headless mode
#   --tmux-session NAME      Custom tmux session name (default: claude-coding-agent)
#
# Default behavior:
#   - Uses tmux interactive mode by default
#   - Tasks share context in the same tmux session
#   - Use --no-tmux to run in headless mode
#
# The script:
#   1. Writes task metadata to task-meta.json (hook reads this)
#   2. Runs Claude Code via claude_code_run.py
#   3. When Claude Code finishes, Stop hook fires automatically
#   4. Hook reads meta, writes results, sends Feishu notification
#   5. AGI reads results and relays to Telegram group

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULT_DIR="/home/ubuntu/clawd/data/claude-code-results"

# 状态目录在参数解析后再计算（避免 set -u + 提前引用）
SESSION_DIR=""
META_FILE=""

OUTPUT_FILE="/tmp/claude-code-output.txt"
TASK_OUTPUT="${RESULT_DIR}/task-output.txt"
RUNNER="$SCRIPT_DIR/claude_code_run.py"

# Defaults
PROMPT=""
TASK_NAME=""
TASK_ID=""  # 将在后面生成
FEISHU_TARGET="${FEISHU_TARGET:-}"
CDP_PORT="${CDP_PORT:-}"
CALLBACK_SESSION=""
WORKDIR="/home/ubuntu"
AGENT_TEAMS=""
TEAMMATE_MODE=""
PERMISSION_MODE="bypassPermissions"
ALLOWED_TOOLS=""
MODEL=""  # 默认不覆盖 Claude Code 自身模型配置；只有 --model 才设置
EFFORT="xhigh"  # effort 等级，默认 xhigh；可被 --effort 覆盖（脚本 dispatch 统一 xhigh）
ENABLE_TMUX="1"  # 默认启用 tmux interactive 模式
TMUX_SESSION_NAME=""
DISABLE_TMUX=""  # 新增：用于禁用 tmux
PARENT_SESSION=""  # 父 CC 的 tmux session（用于完成后 send-keys 通知）
DISPATCH_CONFIG="${DISPATCH_CONFIG:-}"

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--prompt) PROMPT="$2"; shift 2;;
        -n|--name) TASK_NAME="$2"; shift 2;;
        -g|--group|--target) FEISHU_TARGET="$2"; shift 2;;
        --cdp) CDP_PORT="$2"; shift 2;;
        -s|--session) CALLBACK_SESSION="$2"; shift 2;;
        -w|--workdir) WORKDIR="$2"; shift 2;;
        --agent-teams) AGENT_TEAMS="1"; shift;;
        --teammate-mode) TEAMMATE_MODE="$2"; shift 2;;
        --permission-mode) PERMISSION_MODE="$2"; shift 2;;
        --allowed-tools) ALLOWED_TOOLS="$2"; shift 2;;
        --model) MODEL="$2"; MODEL_EXPLICIT="1"; shift 2;;
        --effort) EFFORT="$2"; shift 2;;
        --tmux) ENABLE_TMUX="1"; shift;;
        --no-tmux) DISABLE_TMUX="1"; shift;;  # 新增：禁用 tmux
        --tmux-session) TMUX_SESSION_NAME="$2"; shift 2;;
        --parent-session) PARENT_SESSION="$2"; shift 2;;
        *) echo "Unknown option: $1" >&2; exit 1;;
    esac
done

# 如果明确禁用 tmux，则关闭
if [ -n "$DISABLE_TMUX" ]; then
    ENABLE_TMUX=""
fi

if [ -z "$PROMPT" ]; then
    echo "Error: --prompt is required" >&2
    exit 1
fi

# Locate the config before resolving runtime defaults. An explicit --cdp or
# CDP_PORT always wins; otherwise use the configured default browser.
if [ -z "$DISPATCH_CONFIG" ]; then
    for candidate in "$SCRIPT_DIR/dispatch-config.json" "$SCRIPT_DIR/../dispatch-config.json" "/home/ubuntu/.openclaw/skills/coding-agent/scripts/dispatch-config.json"; do
        if [ -f "$candidate" ]; then DISPATCH_CONFIG="$candidate"; break; fi
    done
fi
if [ -z "$CDP_PORT" ] && [ -n "$DISPATCH_CONFIG" ] && [ -f "$DISPATCH_CONFIG" ]; then
    CDP_PORT="$(jq -r '.default_cdp // empty' "$DISPATCH_CONFIG")"
fi

if [ -n "$CDP_PORT" ] && ! [[ "$CDP_PORT" =~ ^[0-9]+$ ]]; then
    echo "Error: --cdp must be a numeric port" >&2
    exit 1
fi

if [ -z "$FEISHU_TARGET" ]; then
    if [ -n "$DISPATCH_CONFIG" ] && [ -f "$DISPATCH_CONFIG" ] && [ -n "$CDP_PORT" ]; then
        FEISHU_TARGET="$(jq -r --arg cdp "$CDP_PORT" '.cdp_targets[$cdp] // empty' "$DISPATCH_CONFIG")"
    fi
    if [ -z "$FEISHU_TARGET" ] && [ -n "$DISPATCH_CONFIG" ] && [ -f "$DISPATCH_CONFIG" ]; then
        FEISHU_TARGET="$(jq -r '.default_target // empty' "$DISPATCH_CONFIG")"
    fi
fi
if [ -z "$FEISHU_TARGET" ]; then
    echo "Error: no Feishu target; configure dispatch-config.json or pass --target" >&2
    exit 1
fi

# Dispatch parameters are the runtime source of truth. The worker receives them
# both as exported environment variables and as an explicit prompt block.
export FEISHU_TARGET CDP_PORT
RUNTIME_CONTEXT="【Dispatch 运行时参数（由派发器注入，请直接使用，不要向用户重复询问）】"
if [ -n "$CDP_PORT" ]; then
    RUNTIME_CONTEXT="${RUNTIME_CONTEXT}
- CDP_PORT=${CDP_PORT}：浏览器调试端口；所有 agent-browser 命令使用 --cdp ${CDP_PORT}。"
fi
if [ -n "$FEISHU_TARGET" ]; then
    RUNTIME_CONTEXT="${RUNTIME_CONTEXT}
- FEISHU_TARGET=${FEISHU_TARGET}：飞书汇报目标；任务结束通知发送到该目标。"
fi
PROMPT="${RUNTIME_CONTEXT}

${PROMPT}"

# ---- 0. Resolve runtime mode + tmux metadata ----
TMUX_SESSION="${TMUX_SESSION_NAME:-}"
if [ -z "$TASK_NAME" ]; then
    TASK_NAME="${TMUX_SESSION_NAME:-adhoc-$(date +%s)}"
fi
TASK_ID="${TASK_NAME}_$(date +%Y%m%d_%H%M%S)_$$"

RUN_MODE="headless"
TMUX_SOCKET=""
TMUX_SESSION_EXISTS=0
if [ -n "$ENABLE_TMUX" ]; then
    RUN_MODE="tmux"
    # Use a stable, globally visible socket directory for Claw Remote.
    TMUX_SOCKET_DIR="${CLAWDBOT_TMUX_SOCKET_DIR:-/home/ubuntu/clawdbot-tmux-sockets}"
    mkdir -p "$TMUX_SOCKET_DIR"
    TMUX_SOCKET="$TMUX_SOCKET_DIR/claude-code.sock"
fi

# 根据 tmux 会话名确定状态目录（参数解析后）
if [ -n "$TMUX_SESSION_NAME" ]; then
    SESSION_DIR="${RESULT_DIR}/sessions/${TMUX_SESSION_NAME}"
    META_FILE="${SESSION_DIR}/task-meta.json"
else
    # 未指定会话名，使用全局路径（向后兼容）
    SESSION_DIR="${RESULT_DIR}"
    META_FILE="${RESULT_DIR}/task-meta.json"
fi

# ---- 1. Write task metadata ----
mkdir -p "$RESULT_DIR"
mkdir -p "$RESULT_DIR/tasks"
mkdir -p "$WORKDIR"

# 创建会话目录
if [ -n "$SESSION_DIR" ] && [ "$SESSION_DIR" != "$RESULT_DIR" ]; then
    mkdir -p "$SESSION_DIR"
fi

jq -n \
    --arg name "$TASK_NAME" \
    --arg task_id "$TASK_ID" \
    --arg target "$FEISHU_TARGET" \
    --arg cdp_port "$CDP_PORT" \
    --arg session "$CALLBACK_SESSION" \
    --arg prompt "$PROMPT" \
    --arg workdir "$WORKDIR" \
    --arg ts "$(date -Iseconds)" \
    --arg agent_teams "${AGENT_TEAMS:-0}" \
    --arg run_mode "$RUN_MODE" \
    --arg tmux_session "$TMUX_SESSION" \
    --arg tmux_socket "$TMUX_SOCKET" \
    --arg parent_session "${PARENT_SESSION}" \
    '{task_name: $name, task_id: $task_id, feishu_target: $target, cdp_port: $cdp_port, callback_session: $session, prompt: $prompt, workdir: $workdir, started_at: $ts, agent_teams: ($agent_teams == "1"), run_mode: $run_mode, tmux_session: $tmux_session, tmux_socket: $tmux_socket, parent_tmux_session: $parent_session, status: "running"}' \
    > "$META_FILE"

# 写入 current-task-id.txt（用于 hook 查找）
if [ -n "$SESSION_DIR" ] && [ "$SESSION_DIR" != "$RESULT_DIR" ]; then
    echo "$TASK_ID" > "${SESSION_DIR}/current-task-id.txt"
fi

# 同时写入 per-task 元数据文件
cp "$META_FILE" "${RESULT_DIR}/tasks/${TASK_ID}.json"

echo "📋 Task metadata written: $META_FILE"
echo "   Task ID: $TASK_ID"
echo "   Task: $TASK_NAME"
echo "   Target: ${FEISHU_TARGET:-none}"
echo "   CDP: ${CDP_PORT:-none}"
echo "   Agent Teams: ${AGENT_TEAMS:-no}"

# ---- 2. Clear previous output ----
> "$OUTPUT_FILE"
> "$TASK_OUTPUT"

# ---- 3. Auto-append Feishu notification ----
PROMPT="${PROMPT}

---
【必须执行】任务完成后，你必须：

1. 统计任务总用时和各阶段用时
2. 分析执行过程中的优化点（哪些步骤耗时长、哪些失败重试了、哪些流程可以改进）
3. 给出 prompt 提示词或执行脚本的具体修改建议（如有）
4. 将以上内容连同任务结果摘要（成功/失败状态、关键信息）一起发送到飞书群聊：

\`\`\`bash
openclaw message send --channel feishu --target \"${FEISHU_TARGET}\" --message \"<任务结果摘要 + 用时统计 + 优化建议>\" 2>/dev/null || true
\`\`\`

即使任务失败，也必须发送失败原因和已完成的阶段信息。这是强制要求，不可省略。

5. 出错脚本修复、验证与 git 提交：任务结束前，对执行过程中出错的脚本进行修复；修复后必须重新运行验证，确认输出符合预期才算完成，禁止只修改不验证。凡是修复了脚本，验证通过后必须进入 /home/ubuntu/.openclaw 仓库，检查 git status 和 git diff，只提交本次修复涉及的文件，创建 git commit，并 push 到远程仓库的 master 分支（git push origin master），禁止推送到非 master 分支。禁止提交无关改动、密钥文件、临时文件或大产物；若提交或 push 失败，必须在飞书失败通知中说明原因。**重要：执行 git add/commit/push 时必须使用 flock 排队锁**，避免多 agent 并行操作同一仓库导致 index.lock 冲突：
   \`\`\`bash
   flock /home/ubuntu/.openclaw/.git/git-commit.lock bash -c 'cd /home/ubuntu/.openclaw && git add <文件> && git commit --no-verify -m \"消息\" && git push origin master'
   \`\`\`
   如果获取锁超时（默认等 120 秒），说明其他 agent 正在 commit，等待后重试即可。

6. 经验库读写：
   - 目录结构：/home/ubuntu/Documents/同步/skill-memory/ 按 skill 名分为子目录（如 game-refactor/、code-before/、drbacklink/、wiki-sites/ 等），子目录内是按日期命名的经验文件 <YYYY-MM-DD>.md，同一天的所有任务经验合并到同一个日期文件里。
   - 子目录推断：读取环境变量 \$CODING_AGENT_TMUX_SESSION，从中去掉末尾的动态参数部分（域名、站点名、序号等任务级变量），剩余的固定前缀即为子目录名（如 game-refactor-part4-homepage-1-superstarbaseballwiki → 子目录 game-refactor/；code-before-example.com → 子目录 code-before/；wiki 站点相关 → 子目录 wiki-sites/）。如不确定，先 ls /home/ubuntu/Documents/同步/skill-memory/ 查看所有子目录列表，选择最匹配的。
   - 文件名：当天日期，即 /home/ubuntu/Documents/同步/skill-memory/<子目录>/<YYYY-MM-DD>.md（用执行当天日期，不要用任务名做文件名）。
   - 执行前：读取该子目录下最近 3 天的日期文件（最近 3 个 <YYYY-MM-DD>.md），把里面的经验条目作为参考，主动规避已知问题。不要读取全部历史文件，只取最近 3 天即可。
   - 执行后：将本次遇到的问题和改进建议追加写入当天的日期文件。同一天多次任务都追加到同一个日期文件，用 ## <本次域名或任务简称> 二级标题区分不同任务段落。如该日期文件不存在则先创建，并在首行写入标题行 # <子目录名> 经验 - <YYYY-MM-DD>，空一行后再追加经验段落。追加格式：
     ## <本次域名或任务简称>
     ### 遇到的问题
     - <如实填写，无则写\"无明显问题\">
     ### 改进建议
     - <如实填写，无则写\"无\">
     （末尾空一行）"

# ---- 4. Build runner command ----
if [ -n "$ENABLE_TMUX" ]; then
    # tmux 模式：使用 interactive 模式
    CMD=(python3 "$RUNNER" -p "$PROMPT" --cwd "$WORKDIR" --mode interactive)
    CMD+=(--tmux-session "$TMUX_SESSION")
    CMD+=(--tmux-socket-dir "$TMUX_SOCKET_DIR")
    CMD+=(--interactive-wait-s 0)  # 不等待，立即返回
    # 检查环境变量，决定是否使用 --continue
    if [ "${FORCE_NEW_SESSION:-false}" = "true" ]; then
        # 强制新会话模式：不使用 --continue，让 runner 杀死旧会话
        TMUX_SESSION_EXISTS=0
    elif tmux -S "$TMUX_SOCKET" has-session -t "$TMUX_SESSION" 2>/dev/null; then
        # 检查 session 里是否有活跃的 claude 进程
        PANE_PID=$(tmux -S "$TMUX_SOCKET" list-panes -t "$TMUX_SESSION" -F '#{pane_pid}' 2>/dev/null | head -1)
        CLAUDE_ALIVE=false
        if [ -n "$PANE_PID" ] && pgrep -P "$PANE_PID" -f "claude" > /dev/null 2>&1; then
            CLAUDE_ALIVE=true
        fi

        if [ "$CLAUDE_ALIVE" = true ]; then
            TMUX_SESSION_EXISTS=1
            CMD+=(--continue)
            echo "♻️  Reusing existing session with active Claude process: $TMUX_SESSION"
        else
            echo "⚠️  Session exists but Claude not running, killing stale session: $TMUX_SESSION"
            tmux -S "$TMUX_SOCKET" kill-session -t "$TMUX_SESSION" 2>/dev/null || true
            TMUX_SESSION_EXISTS=0
        fi
    fi
else
    # 默认模式：headless
    CMD=(python3 "$RUNNER" -p "$PROMPT" --cwd "$WORKDIR")
fi

# 添加其他参数
if [ -n "$AGENT_TEAMS" ]; then
    CMD+=(--agent-teams)
fi
if [ -n "$TEAMMATE_MODE" ]; then
    CMD+=(--teammate-mode "$TEAMMATE_MODE")
fi
if [ -n "$PERMISSION_MODE" ]; then
    CMD+=(--permission-mode "$PERMISSION_MODE")
fi
if [ -n "$ALLOWED_TOOLS" ]; then
    CMD+=(--allowedTools "$ALLOWED_TOOLS")
fi
if [ -n "$MODEL" ]; then
    CMD+=(--model "$MODEL")
fi

# ---- 5. Set environment ----
# ANTHROPIC_BASE_URL / AUTH_TOKEN may already be set by routing config (section 3.5).
# Caller overrides still take precedence (re-export overwrites the routing value).
if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
    export ANTHROPIC_BASE_URL
else
    unset ANTHROPIC_BASE_URL || true
fi

if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    export ANTHROPIC_API_KEY
else
    unset ANTHROPIC_API_KEY || true
fi

if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
    export ANTHROPIC_AUTH_TOKEN
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    export ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_API_KEY}"
else
    unset ANTHROPIC_AUTH_TOKEN || true
fi

# Hook 侧会话隔离定位信息（避免多会话串扰）
export CODING_AGENT_TASK_ID="$TASK_ID"
export CODING_AGENT_SESSION_DIR="$SESSION_DIR"
export CODING_AGENT_TMUX_SESSION="$TMUX_SESSION"
export CODING_AGENT_WORKDIR="$WORKDIR"
export PARENT_TMUX_SESSION="${PARENT_SESSION}"
# dispatch 路径显式注入 effort（默认 xhigh），由 claude_code_run.py 注入到 tmux 会话，
# 覆盖继承自长驻 tmux server 的旧值（如历史遗留的 max）
export CLAUDE_CODE_EFFORT_LEVEL="$EFFORT"

if [ -n "$MODEL" ]; then
    export ANTHROPIC_MODEL="$MODEL"
fi

# ---- 6. Run Claude Code ----
if [ -n "$ENABLE_TMUX" ]; then
    if [ "$TMUX_SESSION_EXISTS" -eq 1 ]; then
        echo "🔄 Sending task to existing Claude Code session: $TMUX_SESSION"
    else
        echo "🚀 Creating new Claude Code session: $TMUX_SESSION"
    fi
    echo "   Task: $TASK_NAME"
    echo ""

    # 运行 claude_code_run.py（它会处理 tmux 逻辑）
    "${CMD[@]}" 2>&1 | tee "$TASK_OUTPUT"
    EXIT_CODE=${PIPESTATUS[0]}

    echo ""
    echo "✅ Task sent to Claude Code session: $TMUX_SESSION"
    echo ""
    echo "📺 To watch live:"
    echo "   tmux -S $TMUX_SOCKET attach -t $TMUX_SESSION"
    echo ""
    echo "📸 To snapshot output:"
    echo "   tmux -S $TMUX_SOCKET capture-pane -p -J -t ${TMUX_SESSION}:0.0 -S -200"
    echo ""
    echo "💡 Session: $TMUX_SESSION (tasks in this session share context)"
    echo ""

    # 自动发送 tmux 连接信息到飞书
    if [ -n "$FEISHU_TARGET" ]; then
        ATTACH_CMD="tmux -S $TMUX_SOCKET attach -t $TMUX_SESSION"
        NOTIFY_MSG="🚀 任务已启动: ${TASK_NAME}

Tmux 会话: $TMUX_SESSION

查看实时执行:
\`\`\`bash
$ATTACH_CMD
\`\`\`"
        timeout 30 openclaw message send --channel feishu --target "$FEISHU_TARGET" --message "$NOTIFY_MSG" 2>/dev/null || true
    fi
else
    # ---- 默认模式（现有逻辑）----
    echo "🚀 Launching Claude Code..."
    echo "   Command: ${CMD[*]}"
    echo ""

    # Use tee to capture output while also displaying it
    "${CMD[@]}" 2>&1 | tee "$TASK_OUTPUT"
    EXIT_CODE=${PIPESTATUS[0]}

    echo ""
    echo "✅ Claude Code exited with code: $EXIT_CODE"
    echo "   Hook should have fired automatically."
    echo "   Results: ${RESULT_DIR}/latest.json"

    # Update meta with completion
    if [ -f "$META_FILE" ]; then
        jq --arg code "$EXIT_CODE" --arg ts "$(date -Iseconds)" \
            '. + {exit_code: ($code | tonumber), completed_at: $ts, status: "done"}' \
            "$META_FILE" > "${META_FILE}.tmp" && mv "${META_FILE}.tmp" "$META_FILE"
    fi
fi

exit $EXIT_CODE
