#!/bin/bash
# batch-dispatch.sh - 批量串行派发 Claude Code 任务
#
# Usage:
#   batch-dispatch.sh (--tasks tasks.json | --markdown-dir DIR) [OPTIONS]
#
# Task input:
#   --tasks FILE             JSON 任务文件；与 --markdown-dir 二选一
#   --markdown-dir DIR       Markdown 任务目录；与 --tasks 二选一
#   --markdown-pattern GLOB  Markdown 文件匹配规则（默认: part*.md）
#   --append-prompt TEXT     给每个任务追加同一段 Prompt
#   --append-prompt-file FILE
#                            覆盖公共要求文件；Markdown 模式默认读取同目录 common-requirements.md
#
# Other options:
#   -g, --group ID           飞书通知目标
#   -w, --workdir DIR        工作目录（默认: /root）
#   --permission-mode MODE   权限模式（默认: bypassPermissions）
#   --tmux-session NAME      tmux 会话名（默认: claude-coding-agent）
#   --wait-timeout SECONDS   单个任务超时时间（默认: 3600）
#   --stop-on-error          任务失败时停止（默认: 继续）
#   -h, --help               显示帮助信息
#
# JSON 格式:
#   {
#     "tasks": [
#       {"name": "task-1", "prompt": "任务 1 的 prompt"},
#       {"name": "task-2", "prompt": "任务 2 的 prompt"}
#     ]
#   }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH_SCRIPT="$SCRIPT_DIR/dispatch-claude-code.sh"
TMP_DIR="${SCRIPT_DIR}/tmp"
RESULT_DIR="/home/ubuntu/clawd/data/claude-code-results"
TASKS_DIR="${RESULT_DIR}/tasks"  # per-task 状态目录

# 提取任务状态摘要
extract_task_summary() {
    local task_id=$1
    local task_file="${TASKS_DIR}/${task_id}.json"

    if [ ! -f "$task_file" ]; then
        return
    fi

    local output=$(jq -r '.output // ""' "$task_file")

    # 清理输出：只保留用户输入(❯)和 Claude 响应(●)
    if [ -n "$output" ]; then
        output=$(echo "$output" | \
            sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | \
            grep -E "^(❯|●|⎿)" | \
            sed 's/[[:space:]]\{2,\}/ /g' | \
            sed '/^[[:space:]]*$/d' | \
            awk '/^❯/ && length($0) <= 5 {next} {print}')

        # 截断输出（最多 500 字符）
        if [ ${#output} -gt 500 ]; then
            output="${output:0:500}..."
        fi
    fi

    echo "$output"
}

# 自动兜底重注入：dispatch 返回后 CC 偶发卡在空❯（CC v2.x 启动 focus-binding
# window 偶发超长，refactor part1 多站复现）。dispatch 内部 claude_code_run.py 已有
# 6 次 paste 重试 + 10s 最终 paste，但都集中在 CC 刚启动的 focus-binding 窗口内，
# 覆盖不到"dispatch 返回后 CC 仍卡空"这个外层时机。本函数填补该盲区：
# 等 30s 让 CC 有时间显示首个 Thought/工具调用；若仍无任何"开始处理"迹象则判定卡空，
# 从 task-meta.json 重注入 prompt（只一次）。保守设计：宁可漏判（编排者手动恢复）
# 也不误判（重复提交 prompt 导致 CC 重复工作）。
reinject_idle_prompt_if_needed() {
    local session_name="$1"   # tmux 会话名，如 battlepiece_wiki-p1
    local task_meta="$2"      # task-meta.json 路径（含 .prompt）

    # 等 CC 启动 + focus-binding 过 + 有时间显示首个 Thought（xhigh effort 首 token 较慢）
    sleep 30

    local pane
    local pane_command
    pane_command=$(tmux -S "$TMUX_SOCKET" list-panes -t "$session_name" -F '#{pane_current_command}' 2>/dev/null | head -1 || true)
    if [ "$pane_command" = "bash" ] || [ "$pane_command" = "sh" ] || [ "$pane_command" = "zsh" ]; then
        echo "   Error: ${session_name} 中 Claude 已退出，当前仅剩 ${pane_command}；禁止向 shell 重注入 Prompt" >&2
        return 1
    fi

    pane=$(tmux -S "$TMUX_SOCKET" capture-pane -p -J -t "${session_name}:0.0" -S -40 2>/dev/null || true)
    if [ -z "$pane" ]; then
        echo "   兜底: 无法捕获 ${session_name} pane，跳过重注入检测"
        return 0
    fi

    # CC 已开始处理 prompt 的明确迹象：首个 Thought / 工具调用结果 / tokens 计数
    if echo "$pane" | grep -qE "Thought for|Thinking for|Thinking…|⎿|↓ [0-9.,]+ ?k? ?tokens|↑ [0-9.,]+ ?k? ?tokens"; then
        return 0   # CC 正常工作中，注入成功
    fi

    # 无开始处理迹象 + 无❯标记：状态不明（可能 CC 还在更早期），保守跳过
    if ! echo "$pane" | grep -q "❯"; then
        echo "   兜底: ${session_name} 30s 后无❯且无工作迹象，状态不明，跳过（保守不注入）"
        return 0
    fi

    # 有❯ + 30s 无任何开始处理迹象 → 判定卡空❯，重注入
    if [ ! -f "$task_meta" ]; then
        echo "   兜底: ${session_name} 疑似卡空❯，但 task-meta 不存在 ($task_meta)，跳过"
        return 0
    fi

    local prompt_file
    mkdir -p "$TMP_DIR"
    prompt_file=$(mktemp "${TMP_DIR}/reinject-XXXXXX.txt" 2>/dev/null) || {
        echo "   兜底: mktemp 失败，跳过重注入"
        return 0
    }
    if ! jq -r '.prompt // empty' "$task_meta" > "$prompt_file" 2>/dev/null || [ ! -s "$prompt_file" ]; then
        echo "   兜底: prompt 提取为空，放弃重注入"
        rm -f "$prompt_file"
        return 0
    fi

    echo "   ⚠️ 兜底: ${session_name} 卡空❯（30s 无开始处理迹象），从 task-meta.json 重注入 prompt"
    tmux -S "$TMUX_SOCKET" load-buffer "$prompt_file" 2>/dev/null || true
    sleep 1
    tmux -S "$TMUX_SOCKET" paste-buffer -t "${session_name}:0.0" -d -p 2>/dev/null || true
    sleep 3
    tmux -S "$TMUX_SOCKET" send-keys -t "${session_name}:0.0" Enter 2>/dev/null || true
    rm -f "$prompt_file"
    echo "   兜底: 重注入完成（等待任务完成逻辑会接管后续监控）"
}

# 默认值
TASKS_FILE=""
MARKDOWN_DIR=""
MARKDOWN_PATTERN="part*.md"
APPEND_PROMPT=""
APPEND_PROMPT_FILE=""
FEISHU_TARGET=""
CDP_PORT=""
WORKDIR="/home/ubuntu"
PERMISSION_MODE="bypassPermissions"
TMUX_SESSION="claude-coding-agent"
WAIT_TIMEOUT=3600
STOP_ON_ERROR=false
MODEL=""
EFFORT="xhigh"  # effort 等级，默认 xhigh（脚本 dispatch 统一 xhigh），透传给 dispatch-claude-code.sh
# tmux socket：与 dispatch-claude-code.sh 保持一致（支持 CLAWDBOT_TMUX_SOCKET_DIR 覆盖），
# 供"每个 part 完成后销毁上一个 idle 会话"使用
TMUX_SOCKET="${CLAWDBOT_TMUX_SOCKET_DIR:-/home/ubuntu/clawdbot-tmux-sockets}/claude-code.sock"
# 起始任务序号（1-based）：从完整任务列表的第 N 个开始跑（跳过前面已完成的 part）。
# 会话名后缀 -p${index} 直接用 task 在完整列表中的序号(=part号)，attach 时直观对应。
START_INDEX=1

# 统计变量
TOTAL_TASKS=0
SUCCESS_COUNT=0
FAILED_COUNT=0
TIMEOUT_COUNT=0
START_TIME=$(date +%s)
WAIT_RESULT=""

usage() {
    cat << EOF
批量串行派发 Claude Code 任务

用法:
  batch-dispatch.sh (--tasks tasks.json | --markdown-dir DIR) [OPTIONS]

选项:
  --tasks FILE             JSON 任务文件；与 --markdown-dir 二选一
  --markdown-dir DIR       Markdown 目录；每个 .md 生成一个任务，按文件名自然排序
  --markdown-pattern GLOB  Markdown 文件名模式（默认: part*.md）
  --append-prompt TEXT     给每个任务末尾追加同一段 Prompt
  --append-prompt-file FILE
                           覆盖公共要求文件；Markdown 模式默认读取同目录 common-requirements.md
  -g, --group, --target ID 飞书通知目标；自动传给每个 Part
  --cdp PORT               浏览器 CDP 端口；自动传给每个 Part
  -w, --workdir DIR        工作目录（默认: /root）
  --permission-mode MODE   权限模式（默认: bypassPermissions）
  --tmux-session NAME      tmux 会话名（默认: claude-coding-agent）
  --wait-timeout SECONDS   单个任务超时时间（默认: 3600）
  --model MODEL            模型覆盖（如 claude-sonnet-4-6）
  --effort LEVEL           effort 等级（默认 xhigh）
  --stop-on-error          任务失败时停止（默认: 继续）
  -h, --help               显示帮助信息

JSON 格式:
  {
    "tasks": [
      {"name": "task-1", "prompt": "任务 1 的 prompt"},
      {"name": "task-2", "prompt": "任务 2 的 prompt"}
    ]
  }

Markdown 文件名去掉 .md 后作为任务名，文件正文作为 Prompt。
EOF
}

# 解析参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tasks) TASKS_FILE="$2"; shift 2;;
            --markdown-dir) MARKDOWN_DIR="$2"; shift 2;;
            --markdown-pattern) MARKDOWN_PATTERN="$2"; shift 2;;
            --append-prompt) APPEND_PROMPT="$2"; shift 2;;
            --append-prompt-file) APPEND_PROMPT_FILE="$2"; shift 2;;
            -g|--group|--target) FEISHU_TARGET="$2"; shift 2;;
            --cdp) CDP_PORT="$2"; shift 2;;
            -w|--workdir) WORKDIR="$2"; shift 2;;
            --permission-mode) PERMISSION_MODE="$2"; shift 2;;
            --tmux-session) TMUX_SESSION="$2"; shift 2;;
            --wait-timeout) WAIT_TIMEOUT="$2"; shift 2;;
            --model) MODEL="$2"; shift 2;;
            --effort) EFFORT="$2"; shift 2;;
            --start-index) START_INDEX="$2"; shift 2;;
            --stop-on-error) STOP_ON_ERROR=true; shift;;
            -h|--help) usage; exit 0;;
            *) echo "未知参数: $1" >&2; usage; exit 1;;
        esac
    done

    if [[ -n "$TASKS_FILE" && -n "$MARKDOWN_DIR" ]] || [[ -z "$TASKS_FILE" && -z "$MARKDOWN_DIR" ]]; then
        echo "错误: --tasks 与 --markdown-dir 必须且只能选择一个" >&2
        usage
        exit 1
    fi

    if [[ -n "$TASKS_FILE" && ! -f "$TASKS_FILE" ]]; then
        echo "错误: 任务文件不存在: $TASKS_FILE" >&2
        exit 1
    fi
    if [[ -n "$MARKDOWN_DIR" && ! -d "$MARKDOWN_DIR" ]]; then
        echo "错误: Markdown 任务目录不存在: $MARKDOWN_DIR" >&2
        exit 1
    fi
    if [[ -n "$MARKDOWN_DIR" && -z "$APPEND_PROMPT_FILE" && -f "$MARKDOWN_DIR/common-requirements.md" ]]; then
        APPEND_PROMPT_FILE="$MARKDOWN_DIR/common-requirements.md"
    fi
    if [[ -n "$APPEND_PROMPT_FILE" && ! -f "$APPEND_PROMPT_FILE" ]]; then
        echo "错误: 追加 Prompt 文件不存在: $APPEND_PROMPT_FILE" >&2
        exit 1
    fi
}

load_tasks_json() {
    local tasks_json=""

    if [[ -n "$TASKS_FILE" ]]; then
        tasks_json=$(cat "$TASKS_FILE")
        echo "$tasks_json" | jq -e '.tasks | type == "array"' >/dev/null 2>&1 || {
            echo "错误: JSON 任务文件必须包含 tasks 数组: $TASKS_FILE" >&2
            return 1
        }
    else
        tasks_json='{"tasks":[]}'
        local markdown_file=""
        while IFS= read -r markdown_file; do
            local task_name
            local task_prompt
            task_name=$(basename "$markdown_file" .md)
            task_prompt=$(cat "$markdown_file")
            [[ -n "$task_prompt" ]] || {
                echo "错误: Markdown 任务为空: $markdown_file" >&2
                return 1
            }
            tasks_json=$(echo "$tasks_json" | jq \
                --arg name "$task_name" \
                --arg prompt "$task_prompt" \
                '.tasks += [{name:$name,prompt:$prompt}]')
        done < <(find "$MARKDOWN_DIR" -maxdepth 1 -type f -name "$MARKDOWN_PATTERN" -print | sort -V)
    fi

    local append_text="$APPEND_PROMPT"
    if [[ -n "$APPEND_PROMPT_FILE" ]]; then
        local append_file_text
        append_file_text=$(cat "$APPEND_PROMPT_FILE")
        if [[ -n "$append_text" && -n "$append_file_text" ]]; then
            append_text="${append_text}"$'\n\n'"${append_file_text}"
        elif [[ -n "$append_file_text" ]]; then
            append_text="$append_file_text"
        fi
    fi
    if [[ -n "$append_text" ]]; then
        tasks_json=$(echo "$tasks_json" | jq \
            --arg append "$append_text" \
            '.tasks |= map(.prompt = ((.prompt // "") + "\n\n" + $append))')
    fi

    echo "$tasks_json"
}

# 等待任务完成
wait_for_task_completion() {
    local task_id=$1
    local timeout=$2
    local task_start_time=$3  # 任务启动时间（从外部传入）
    local wait_start_time=$(date +%s)
    local elapsed=0
    local check_interval=20
    local task_file="${TASKS_DIR}/${task_id}.json"

    WAIT_RESULT=""
    echo "⏳ 等待任务完成: $task_id (超时: ${timeout}s)"
    echo "   监控文件: $task_file"

    while [ $elapsed -lt $timeout ]; do
        if [ -f "$task_file" ]; then
            local status=$(jq -r '.status // ""' "$task_file" 2>/dev/null || echo "")
            local timestamp=$(jq -r '.timestamp // ""' "$task_file" 2>/dev/null || echo "")

            if [ "$status" == "done" ]; then
                # 验证时间戳（确保不是旧结果）
                local result_time=$(date -d "$timestamp" +%s 2>/dev/null || echo 0)
                if [ $result_time -ge $task_start_time ]; then
                    # done 的正确性由 hook 侧 transcript 归属门禁保证：只有"这次 Stop
                    # 属于当前 part 且 prompt 已提交"才会被写成 done，故这里不再 grep
                    # 屏幕兜底，命中 done + 时间戳新即视为完成。
                    WAIT_RESULT="done"
                    echo "✅ 任务完成: $task_id (耗时: ${elapsed}s)"
                    return 0
                else
                    echo "   检测到旧结果（时间戳: $timestamp），继续等待..."
                fi
            elif [ "$status" == "failed" ]; then
                WAIT_RESULT="failed"
                echo "❌ 任务失败: $task_id"
                return 1
            elif [ "$status" == "waiting_input" ]; then
                # 任务等待用户输入，这违反了自动化执行的要求
                WAIT_RESULT="waiting_input"
                echo "❌ 任务等待用户输入: $task_id"
                echo "   这违反了自动化执行的要求"
                echo "   任务可能包含了需要用户选择的步骤"
                return 1
            elif [ "$status" == "uncertain" ]; then
                # 任务状态不确定，继续等待
                echo "   任务状态不确定，继续等待..."
            fi
        fi

        sleep $check_interval
        elapsed=$((elapsed + check_interval))

        # 每 10 秒显示一次进度
        if [ $((elapsed % 10)) -eq 0 ]; then
            echo "   仍在等待... (${elapsed}s / ${timeout}s)"
        fi
    done

    WAIT_RESULT="timeout"
    echo "⚠️  任务超时: $task_id (${timeout}s)"
    return 1
}

# 执行单个任务
execute_task() {
    local task_name=$1
    local prompt=$2
    local index=$3

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📋 任务 [$index/$TOTAL_TASKS]: $task_name"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # 记录当前 part 序号（供 main 收尾销毁最后一个会话用）
    LAST_INDEX=$index

    # 销毁上一个 part 的 idle 会话：进入本函数即代表 part(index-1) 已串行执行完毕、会话已 idle。
    # 立即 kill 之，把同时存活会话数压到 ≤2、释放内存。杀的是早已 done 的 idle 旧会话，
    # 即便 kill 触发其残留 Stop（env=旧 part，此刻已 not in running），也会被 hook 的
    # resolve 门禁直接忽略（不 fallback）——故时机最安全，不会污染当前正在跑的 part。
    if [ "$index" -gt 1 ]; then
        local prev_session="${TMUX_SESSION}-p$((index - 1))"
        if tmux -S "$TMUX_SOCKET" has-session -t "$prev_session" 2>/dev/null; then
            tmux -S "$TMUX_SOCKET" kill-session -t "$prev_session" 2>/dev/null \
                && echo "🧹 已销毁上一个 idle 会话: $prev_session"
        fi
    fi

    # 记录任务启动时间
    local task_start_time=$(date +%s)

    # 构建完整 prompt（包含上一步 prompt 和状态摘要）
    local full_prompt="$prompt"
    if [ $index -gt 1 ] && [ -n "${LAST_PROMPT:-}" ] && [ -n "${LAST_TASK_ID:-}" ]; then
        # 提取上一步任务状态摘要
        local task_summary=$(extract_task_summary "$LAST_TASK_ID")

        full_prompt="【背景参考：上一步任务与结果摘要，仅供了解上下文，无需回头重做】
上一步任务：$LAST_PROMPT

上一步结果摘要：$task_summary

【当前任务，请直接开始执行，完成后再按要求收尾提交】
$prompt"
        echo "📝 传递上一步 prompt (${#LAST_PROMPT} 字符) + 执行结果"
    fi

    # 调用 dispatch-claude-code.sh
    # 每个 task 使用独立 tmux 会话名（${TMUX_SESSION}-p${index}）：避免 FORCE_NEW_SESSION
    # 杀旧同名会话时触发旧 CC 的 Stop hook，而 current-task-id.txt 已被新 dispatch 更新，
    # 导致新 task 被秒标 done（实测 part3-9 全被误判成功、part4-8 根本没执行）。独立会话名
    # 让"杀旧"找不到同名旧会话，从源头避免误触发，每个 part 在自己会话里跑完退出才标 done。
    local dispatch_args=(
        -p "$full_prompt"
        -n "$task_name"
        -w "$WORKDIR"
        --permission-mode "$PERMISSION_MODE"
        --tmux-session "${TMUX_SESSION}-p${index}"
    )

    if [ -n "$FEISHU_TARGET" ]; then
        dispatch_args+=(--target "$FEISHU_TARGET")
    fi

    if [ -n "$CDP_PORT" ]; then
        dispatch_args+=(--cdp "$CDP_PORT")
    fi

    if [ -n "$MODEL" ]; then
        dispatch_args+=(--model "$MODEL")
    fi

    # 执行 dispatch 并传递环境变量
    local dispatch_output
    if dispatch_output=$(
        FORCE_NEW_SESSION=true \
        env -u CLAUDECODE "$DISPATCH_SCRIPT" "${dispatch_args[@]}" 2>&1
    ); then
        :
    else
        echo "$dispatch_output"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 1
    fi
    echo "$dispatch_output"

    if echo "$dispatch_output" | grep -q "ERROR: Claude Code exited before prompt injection"; then
        echo "❌ Claude Code 在 Prompt 注入前退出，立即停止当前 Part" >&2
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 1
    fi

    # 从输出中提取 Task ID
    local task_id=$(echo "$dispatch_output" | grep "Task ID:" | sed 's/.*Task ID: //' | tr -d ' ')

    if [ -z "$task_id" ]; then
        echo "⚠️  警告: 无法提取 Task ID，尝试从元数据文件读取..."
        task_id=$(jq -r '.task_id // ""' "${RESULT_DIR}/task-meta.json" 2>/dev/null || echo "")
    fi

    if [ -z "$task_id" ]; then
        echo "❌ 错误: 无法获取 Task ID"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 1
    fi

    echo "   Task ID: $task_id"

    # 自动兜底：dispatch 返回后 CC 偶发卡空❯（CC v2.x focus-binding window 超长，
    # refactor part1 多站复现）。检测到卡空则从 task-meta.json 重注入 prompt。
    local part_session="${TMUX_SESSION}-p${index}"
    local part_task_meta
    part_task_meta=$(echo "$dispatch_output" | grep -oP 'Task metadata written: \K\S+' | head -1 || true)
    if [ -z "$part_task_meta" ]; then
        part_task_meta="${RESULT_DIR}/sessions/${part_session}/task-meta.json"
    fi
    if ! reinject_idle_prompt_if_needed "$part_session" "$part_task_meta"; then
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 1
    fi

    # 等待任务完成（传递任务启动时间）
    if wait_for_task_completion "$task_id" "$WAIT_TIMEOUT" "$task_start_time"; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        LAST_PROMPT="$prompt"      # 保存当前 prompt（不是 full_prompt）
        LAST_TASK_ID="$task_id"    # 保存当前 task_id
        return 0
    else
        if [ "$WAIT_RESULT" == "timeout" ]; then
            TIMEOUT_COUNT=$((TIMEOUT_COUNT + 1))
            if [ "$STOP_ON_ERROR" == "true" ]; then
                FAILED_COUNT=$((FAILED_COUNT + 1))
                return 1
            fi
            LAST_PROMPT="$prompt"      # 超时也保留上下文
            LAST_TASK_ID="$task_id"
            echo "⏭️  超时已记录为非致命，继续后续任务"
            return 0
        fi
        FAILED_COUNT=$((FAILED_COUNT + 1))
        LAST_PROMPT="$prompt"      # 即使失败也保存
        LAST_TASK_ID="$task_id"    # 即使失败也保存
        return 1
    fi
}

# 主流程
main() {
    parse_args "$@"

    echo "🚀 批量串行派发 Claude Code 任务"
    echo "   任务输入: ${TASKS_FILE:-$MARKDOWN_DIR}"
    echo "   工作目录: $WORKDIR"
    echo "   飞书通知: ${FEISHU_TARGET:-无}"
    echo "   Tmux 会话: $TMUX_SESSION"
    echo "   模式: 每任务重建会话 + Prompt 链式传递 + 执行结果传递"
    echo ""

    # 初始化全局变量
    LAST_PROMPT=""
    LAST_TASK_ID=""
    LAST_INDEX=0

    # 读取任务列表
    local tasks_json
    tasks_json=$(load_tasks_json)
    TOTAL_TASKS=$(echo "$tasks_json" | jq '.tasks | length' 2>/dev/null || echo 0)

    if [ $TOTAL_TASKS -eq 0 ]; then
        echo "错误: 任务文件中没有任务" >&2
        exit 1
    fi

    echo "📊 共 $TOTAL_TASKS 个任务"
    # START_INDEX 合法性校验（1 ≤ START_INDEX ≤ TOTAL_TASKS）
    if ! [[ "$START_INDEX" =~ ^[0-9]+$ ]] || [ "$START_INDEX" -lt 1 ] || [ "$START_INDEX" -gt "$TOTAL_TASKS" ]; then
        echo "⚠️  --start-index=$START_INDEX 非法（应在 1~$TOTAL_TASKS），重置为 1"
        START_INDEX=1
    fi
    [ "$START_INDEX" -gt 1 ] && echo "▶️  从第 $START_INDEX 个任务开始（跳过前 $((START_INDEX - 1)) 个），会话名 ${TMUX_SESSION}-p${START_INDEX} 起"
    echo ""

    # 遍历执行任务（从 START_INDEX-1 索引开始；execute_task 收到的 index=i+1 直接等于 part 号）
    for i in $(seq $((START_INDEX - 1)) $((TOTAL_TASKS - 1))); do
        local task_name=$(echo "$tasks_json" | jq -r ".tasks[$i].name" 2>/dev/null || echo "task-$i")
        local prompt=$(echo "$tasks_json" | jq -r ".tasks[$i].prompt" 2>/dev/null || echo "")

        if [ -z "$prompt" ]; then
            echo "⚠️  跳过任务 $task_name: prompt 为空"
            FAILED_COUNT=$((FAILED_COUNT + 1))
            continue
        fi

        if ! execute_task "$task_name" "$prompt" "$((i + 1))"; then
            if [ "$STOP_ON_ERROR" == "true" ]; then
                echo ""
                echo "❌ 任务失败，停止执行（--stop-on-error）"
                break
            fi
        fi
    done

    # 销毁最后一个 part 的会话：循环结束后它没有"下一个 part"来触发销毁，在此统一清理，
    # 释放内存。break 提前退出时 LAST_INDEX 也指向最后真正执行的 part。
    if [ "${LAST_INDEX:-0}" -ge 1 ]; then
        local last_session="${TMUX_SESSION}-p${LAST_INDEX}"
        if tmux -S "$TMUX_SOCKET" has-session -t "$last_session" 2>/dev/null; then
            tmux -S "$TMUX_SOCKET" kill-session -t "$last_session" 2>/dev/null \
                && echo "🧹 已销毁最后一个会话: $last_session"
        fi
    fi

    # 输出总结
    local end_time=$(date +%s)
    local total_time=$((end_time - START_TIME))

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📊 执行总结"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   总任务数: $TOTAL_TASKS"
    echo "   成功: $SUCCESS_COUNT"
    echo "   超时(非致命): $TIMEOUT_COUNT"
    echo "   失败: $FAILED_COUNT"
    echo "   总耗时: ${total_time}s"
    echo ""

    if [ $FAILED_COUNT -gt 0 ]; then
        exit 1
    fi
}

main "$@"
