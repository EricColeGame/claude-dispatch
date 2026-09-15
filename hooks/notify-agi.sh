#!/bin/bash
# Claude Code Stop Hook: 任务完成后通知 AGI
# 触发时机: Stop (生成停止) + SessionEnd (会话结束)
# 支持 Agent Teams: lead 完成后自动触发

set -uo pipefail

LOG="/home/ubuntu/clawd/data/claude-code-results/hook.log"
RESULT_DIR="/home/ubuntu/clawd/data/claude-code-results"
OPENCLAW_BIN="$(command -v openclaw || echo /home/ubuntu/.local/share/pnpm/openclaw)"
# tmux 模式下，hook 触发后等待一段时间再判定完成状态（默认 30 秒）
COMPLETION_JUDGE_DELAY_SECONDS="${COMPLETION_JUDGE_DELAY_SECONDS:-30}"

mkdir -p "$RESULT_DIR"
mkdir -p "$RESULT_DIR/tasks"

log() { echo "[$(date -Iseconds)] $*" >> "$LOG"; }

# ---- Claw Remote 会话状态更新（不依赖 CODING_AGENT_TASK_ID）----
if [ -n "${CLAW_REMOTE_TMUX_SESSION:-}" ]; then
    STATUS_FILE="/home/ubuntu/.openclaw/skills/coding-agent/tmp/session-hook-status.json"
    if [ -f "$STATUS_FILE" ]; then
        TS="$(date -Iseconds)"
        TS_EPOCH="$(date +%s)"
        TMP_FILE="${STATUS_FILE}.tmp.$$"
        jq --arg name "$CLAW_REMOTE_TMUX_SESSION" \
           --arg state "completed" \
           --arg source "claude-hook" \
           --arg ts "$TS" \
           --argjson ts_epoch "$TS_EPOCH" \
           'if .sessions[$name] then .sessions[$name].state = $state | .sessions[$name].source = $source | .sessions[$name].updated_at = $ts | .sessions[$name].updated_at_ts = $ts_epoch else . end' \
           "$STATUS_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$STATUS_FILE"
        log "Updated Claw Remote session state: $CLAW_REMOTE_TMUX_SESSION -> completed"
    fi
fi

# ---- 仅对 dispatch 派发的会话继续后续逻辑 ----
if [ -z "${CODING_AGENT_TASK_ID:-}" ]; then
    exit 0
fi

# ---- 辅助函数：捕获 tmux 输出 ----
capture_tmux_output() {
    local tmux_session=$1
    local tmux_socket=$2
    local output=""

    if tmux -S "$tmux_socket" has-session -t "$tmux_session" 2>/dev/null; then
        local tmux_raw=$(tmux -S "$tmux_socket" capture-pane -p -J -t "${tmux_session}:0.0" -S -500 2>/dev/null || echo "")
        if [ -n "$tmux_raw" ]; then
            output=$(echo "$tmux_raw" | \
                sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | \
                grep -v -E "(accept edits on|Meandering|Dilly-dallying|Tip:|running stop hook|Use /btw)" | \
                grep -v -E "^[─━═│┃║┌┐└┘├┤┬┴┼╔╗╚╝╠╣╦╩╬ ]+$" | \
                sed 's/[[:space:]]\{2,\}/ /g' | \
                sed '/^[[:space:]]*$/d' | \
                grep -v '^[[:space:]]*$' | \
                tail -n 20 | \
                head -c 2000)

            if [ -n "$output" ] && [ ${#output} -gt 30 ]; then
                echo "$output"
                return 0
            fi
        fi
    fi
    return 1
}

# ---- 辅助函数：检测任务状态 ----
# 不再用屏幕内容关键词判定"完成"。done 与否由 process_task / legacy 路径的
# transcript 归属门禁（stop_belongs_to_current_task）守护；这里只识别"等待用户输入"。
check_task_completion() {
    local output="$1"

    # 1. 检测明确的未完成标志（等待输入状态，非完成判定）
    if echo "$output" | grep -qE "(Interrupted.*What should Claude do|请指示如何继续|用户是否希望我：|AskUserQuestion)"; then
        echo "waiting_input"
        return
    fi

    # 2. 检测明确的门禁阻断与失败标志（防止失败任务被错误放行为 done）
    # 覆盖：任务失败阻断通知、触发安全门禁、严禁伪造上线、终止发布、探活未通过、HTTP 000、物料缺失等
    if echo "$output" | grep -qiE "(任务失败阻断通知|失败阻断|触发安全门禁|严禁伪造上线|终止发布与提交流程|终止发布|立即阻断流程|禁止放行|严重阻断|任务执行失败|门禁核验失败|探活未通过|HTTP 000|Error: 尚未存在 Part 7|未发现 Part 7|最终探活未通过)"; then
        echo "failed"
        return
    fi

    # 默认：本次 Stop 视为一次回合结束（是否真属于当前 part 由归属门禁决定）
    echo "done"
}

# ---- 辅助函数：定位某 tmux 会话当前 Claude 进程的 transcript jsonl ----
# tmux 场景下 Stop hook 的 stdin 为空（无 transcript_path），故主动定位：
# tmux pane_pid → 其下 claude 进程 pid → ~/.claude/sessions/<pid>.json 取 sessionId
# → find /home/ubuntu/.claude/projects 下同名 <uuid>.jsonl。失败返回空。
resolve_session_transcript() {
    local tmux_session="$1" tmux_socket="$2"
    { [ -z "$tmux_session" ] || [ -z "$tmux_socket" ]; } && return 0
    local pane_pid claude_pid uuid transcript
    pane_pid=$(tmux -S "$tmux_socket" list-panes -t "$tmux_session" -F '#{pane_pid}' 2>/dev/null | head -1)
    [ -z "$pane_pid" ] && return 0
    claude_pid=$(pgrep -P "$pane_pid" -f claude 2>/dev/null | head -1)
    [ -z "$claude_pid" ] && return 0
    uuid=$(jq -r '.sessionId // empty' "/home/ubuntu/.claude/sessions/${claude_pid}.json" 2>/dev/null)
    [ -z "$uuid" ] && return 0
    transcript=$(find /home/ubuntu/.claude/projects -name "${uuid}.jsonl" 2>/dev/null | head -1)
    [ -n "$transcript" ] && echo "$transcript"
}

# ---- 辅助函数：判定这次 Stop 是否属于"当前 part 且该 part 的一个 turn 已正常结束" ----
# 依据：当前 tmux 会话 Claude 的 transcript 里"最后一条 assistant 消息"的 stop_reason
#       == end_turn（Claude 一个 turn 正常收尾的结构化标志，非屏幕关键词），且其时间 >= 当前 part started_at。
#   - 旧 part 残留 Stop：会话已被新 part 顶替/正被 kill → 定位不到或 end_turn 时间 < started_at → 判否（杜绝张冠李戴）
#   - 新 part prompt 刚提交但 turn 未结束：最后一条是 user 或中途 tool_use → 非 end_turn → 判否（杜绝 delay 后 / turn 中途误判）
#   - 当前 part 真跑完一个 turn：最后 assistant end_turn 且 ts >= started_at → 判是
# 返回 0=属于当前 part 且 turn 已正常结束；1=否（定位失败/无法解析时保守判否）。
stop_belongs_to_current_task() {
    local started_at="$1" tmux_session="$2" tmux_socket="$3"
    [ -z "$started_at" ] && return 1
    local started_epoch transcript last_line last_sr last_ts last_epoch
    started_epoch=$(date -d "$started_at" +%s 2>/dev/null || echo "")
    [ -z "$started_epoch" ] && return 1
    transcript=$(resolve_session_transcript "$tmux_session" "$tmux_socket")
    { [ -z "$transcript" ] || [ ! -f "$transcript" ]; } && return 1
    # 取最后一条带时间戳的 assistant 消息的 stop_reason 与时间戳（@tsv：stop_reason<TAB>timestamp）。
    # 过滤掉 transcript 尾部 ts=null 的元数据记录（ai-title / mode / permission-mode）。
    last_line=$(jq -r 'select(.type=="assistant" and .timestamp != null) | [(.message.stop_reason // "-"), .timestamp] | @tsv' "$transcript" 2>/dev/null | tail -1)
    [ -z "$last_line" ] && return 1
    last_sr=$(printf '%s' "$last_line" | cut -f1)
    last_ts=$(printf '%s' "$last_line" | cut -f2)
    [ "$last_sr" = "end_turn" ] || return 1
    [ -z "$last_ts" ] && return 1
    last_epoch=$(date -d "$last_ts" +%s 2>/dev/null || echo "")
    [ -z "$last_epoch" ] && return 1
    [ "$last_epoch" -ge "$started_epoch" ] && return 0 || return 1
}

# ---- 辅助函数：从会话目录解析 running 任务 ----
resolve_task_from_session_dir() {
    local session_dir="$1"
    local session_name=""
    local candidate_task_id=""
    local status=""

    if [ -z "$session_dir" ] || [ ! -d "$session_dir" ]; then
        return 1
    fi
    if [ ! -f "${session_dir}/current-task-id.txt" ] || [ ! -f "${session_dir}/task-meta.json" ]; then
        return 1
    fi

    candidate_task_id=$(cat "${session_dir}/current-task-id.txt" 2>/dev/null || echo "")
    if [ -z "$candidate_task_id" ]; then
        return 1
    fi

    status=$(jq -r '.status // ""' "${session_dir}/task-meta.json" 2>/dev/null || echo "")
    if [ "$status" != "running" ]; then
        return 1
    fi

    session_name=$(basename "$session_dir")
    echo "${session_name}:${candidate_task_id}:${session_dir}"
    return 0
}

# ---- 辅助函数：仅解析当前 hook 对应的目标任务 ----
resolve_target_task() {
    local task_info=""

    # 0) 直接用 CODING_AGENT_TASK_ID 匹配（最可靠，不受 CWD/session 歧义影响）
    #    dispatch 场景下 env CODING_AGENT_TASK_ID 由"触发本次 Stop 的 Claude 进程"继承，
    #    精确标识这次 Stop 来自哪个 task 的会话。命中 running tasks → 正是它本人，处理之。
    if [ -n "${CODING_AGENT_TASK_ID:-}" ]; then
        for task_info in "${RUNNING_TASKS[@]}"; do
            IFS=':' read -r _sn _tid _sd <<< "$task_info"
            if [ "$_tid" = "$CODING_AGENT_TASK_ID" ]; then
                log "Resolved target by CODING_AGENT_TASK_ID direct match: $CODING_AGENT_TASK_ID"
                echo "$task_info"
                return 0
            fi
        done
        # env task_id 非空但不在 running tasks：该 task 已被新 part 顶替或已结束，
        # 这次 Stop 来自一个被取代的旧会话。若继续 fallback 到「tmux session →
        # current-task-id」，必然把它张冠李戴到当前正在跑的 part（秒级假完成的根源）。
        # 故直接放弃本次 Stop，不再 fallback；fallback（下方 1-4 步）只服务于
        # env task_id 为空的非 dispatch 场景（如手动 clawremote 会话 / --continue）。
        log "CODING_AGENT_TASK_ID=$CODING_AGENT_TASK_ID not in running tasks → 已被顶替/结束，忽略此 Stop（不 fallback 防张冠李戴）"
        return 1
    fi

    # 1) 从当前 session 的 tmux environment 读取 CODING_AGENT_SESSION_DIR（兼容新建和 --continue 模式）
    if [ -n "${CODING_AGENT_TMUX_SESSION:-}" ]; then
        local tmux_sock="/home/ubuntu/clawdbot-tmux-sockets/claude-code.sock"
        local _env_session_dir
        _env_session_dir=$(tmux -S "$tmux_sock" show-environment -t "$CODING_AGENT_TMUX_SESSION" CODING_AGENT_SESSION_DIR 2>/dev/null | sed 's/^CODING_AGENT_SESSION_DIR=//' || true)
        if [ -n "$_env_session_dir" ]; then
            task_info=$(resolve_task_from_session_dir "$_env_session_dir" || true)
            if [ -n "$task_info" ]; then
                log "Resolved target by tmux CODING_AGENT_SESSION_DIR (session: $CODING_AGENT_TMUX_SESSION)"
                echo "$task_info"
                return 0
            fi
        fi
    fi

    # 2) 使用 tmux 会话名定位会话目录
    if [ -n "${CODING_AGENT_TMUX_SESSION:-}" ]; then
        local candidate_dir="${RESULT_DIR}/sessions/${CODING_AGENT_TMUX_SESSION}"
        task_info=$(resolve_task_from_session_dir "$candidate_dir" || true)
        if [ -n "$task_info" ]; then
            log "Resolved target by CODING_AGENT_TMUX_SESSION=${CODING_AGENT_TMUX_SESSION}"
            echo "$task_info"
            return 0
        fi
        log "CODING_AGENT_TMUX_SESSION provided but no running task found: ${CODING_AGENT_TMUX_SESSION}"
    fi

    # 3) 使用 cwd 与 task meta 的 workdir 唯一匹配
    if [ -n "$CWD" ]; then
        local -a cwd_matches=()
        for task_info in "${RUNNING_TASKS[@]}"; do
            IFS=':' read -r _session_name _task_id _session_dir <<< "$task_info"
            _workdir=$(jq -r '.workdir // ""' "${_session_dir}/task-meta.json" 2>/dev/null || echo "")
            if [ -n "$_workdir" ] && [ "$_workdir" = "$CWD" ]; then
                cwd_matches+=("$task_info")
            fi
        done

        if [ ${#cwd_matches[@]} -eq 1 ]; then
            log "Resolved target by cwd match: $CWD"
            echo "${cwd_matches[0]}"
            return 0
        fi
        if [ ${#cwd_matches[@]} -gt 1 ]; then
            log "Ambiguous cwd match for $CWD (${#cwd_matches[@]} tasks), skip"
            return 1
        fi
    fi

    # 4) 仅有一个 running 任务时可直接使用
    if [ ${#RUNNING_TASKS[@]} -eq 1 ]; then
        log "Resolved target by single running task fallback"
        echo "${RUNNING_TASKS[0]}"
        return 0
    fi

    return 1
}

# ---- 辅助函数：写入 uncertain 状态（仅写 per-task，避免影响会话 running 扫描）----
mark_task_uncertain() {
    local session_name="$1"
    local task_id="$2"
    local session_dir="$3"
    local reason="${4:-unknown}"
    local uncertain_output="${5:-任务状态不确定，等待后续 hook 再次判定。}"
    local task_file="${RESULT_DIR}/tasks/${task_id}.json"
    local meta_file="${session_dir}/task-meta.json"
    local ts
    local task_name="unknown"
    local feishu_target=""
    local tmux_session="$session_name"
    local tmux_socket="/home/ubuntu/clawdbot-tmux-sockets/claude-code.sock"

    ts="$(date -Iseconds)"

    if [ -f "$meta_file" ]; then
        task_name=$(jq -r '.task_name // "unknown"' "$meta_file" 2>/dev/null || echo "unknown")
        feishu_target=$(jq -r '.feishu_target // ""' "$meta_file" 2>/dev/null || echo "")
        tmux_session=$(jq -r '.tmux_session // "'"$session_name"'"' "$meta_file" 2>/dev/null || echo "$session_name")
        tmux_socket=$(jq -r '.tmux_socket // "/home/ubuntu/clawdbot-tmux-sockets/claude-code.sock"' "$meta_file" 2>/dev/null || echo "/home/ubuntu/clawdbot-tmux-sockets/claude-code.sock")
    fi

    if [ -f "$task_file" ]; then
        jq --arg ts "$ts" \
           --arg output "$uncertain_output" \
           --arg sid "$SESSION_ID" \
           --arg reason "$reason" \
           '. + {status: "uncertain", timestamp: $ts, output: $output, session_id: $sid, uncertain_reason: $reason}' \
           "$task_file" > "${task_file}.tmp" 2>/dev/null && mv "${task_file}.tmp" "$task_file"
        log "Updated task status: tasks/${task_id}.json (status=uncertain, reason=$reason)"
    else
        jq -n \
            --arg sid "$SESSION_ID" \
            --arg ts "$ts" \
            --arg output "$uncertain_output" \
            --arg task "$task_name" \
            --arg task_id "$task_id" \
            --arg target "$feishu_target" \
            --arg tmux_session "$tmux_session" \
            --arg tmux_socket "$tmux_socket" \
            --arg reason "$reason" \
            '{session_id: $sid, timestamp: $ts, output: $output, task_name: $task, task_id: $task_id, feishu_target: $target, tmux_session: $tmux_session, tmux_socket: $tmux_socket, status: "uncertain", uncertain_reason: $reason}' \
            > "$task_file" 2>/dev/null
        log "Created task status: tasks/${task_id}.json (status=uncertain, reason=$reason)"
    fi
}

# ---- 辅助函数：处理单个任务 ----
process_task() {
    local session_name=$1
    local task_id=$2
    local session_dir=$3
    local apply_delay="${4:-false}"

    log ">>> Processing task: $session_name / $task_id"

    # 读取元数据
    local meta_file="${session_dir}/task-meta.json"
    if [ ! -f "$meta_file" ]; then
        log "ERROR: task-meta.json not found for $session_name"
        return 1
    fi

    local task_name=$(jq -r '.task_name // "unknown"' "$meta_file" 2>/dev/null || echo "unknown")
    local feishu_target=$(jq -r '.feishu_target // ""' "$meta_file" 2>/dev/null || echo "")
    local completed_at=$(jq -r '.completed_at // ""' "$meta_file" 2>/dev/null || echo "")
    local run_mode=$(jq -r '.run_mode // "headless"' "$meta_file" 2>/dev/null || echo "headless")
    local tmux_session=$(jq -r '.tmux_session // ""' "$meta_file" 2>/dev/null || echo "")
    local tmux_socket=$(jq -r '.tmux_socket // ""' "$meta_file" 2>/dev/null || echo "")

    # 设置默认值
    if [ -z "$tmux_session" ]; then
        tmux_session="$session_name"
    fi
    if [ -z "$tmux_socket" ]; then
        tmux_socket="/home/ubuntu/clawdbot-tmux-sockets/claude-code.sock"
    fi

    log "Task meta: name=$task_name, target=$feishu_target, mode=$run_mode, tmux=$tmux_session"

    # 捕获输出
    local output=""
    local task_output="${RESULT_DIR}/task-output.txt"

    # 优先从 tmux 捕获
    if [ "$run_mode" = "tmux" ]; then
        output=$(capture_tmux_output "$tmux_session" "$tmux_socket")
        if [ -n "$output" ]; then
            log "Captured from tmux (${#output} chars)"
            log "--- Captured content start ---"
            log "$output"
            log "--- Captured content end ---"
        else
            log "Failed to capture from tmux, trying fallback"
        fi
    fi

    # 回退到文件
    if [ -z "$output" ] && [ -f "$task_output" ] && [ -s "$task_output" ]; then
        local temp_output=$(tail -c 4000 "$task_output")
        if ! echo "$temp_output" | grep -q "Started interactive Claude Code in tmux"; then
            output="$temp_output"
            log "Output from task-output.txt (${#output} chars)"
        fi
    fi

    # 兜底
    if [ -z "$output" ]; then
        output="任务已完成，但输出为空。请检查工作目录或日志文件。"
        log "Using empty output fallback"
    fi

    # tmux 模式：仅对目标任务等待后再重抓一次，减少过早判定
    if [ "$run_mode" = "tmux" ] && [ "$apply_delay" = "true" ] && [ "${COMPLETION_JUDGE_DELAY_SECONDS:-0}" -gt 0 ]; then
        log "Delay completion check by ${COMPLETION_JUDGE_DELAY_SECONDS}s (tmux mode)"
        sleep "$COMPLETION_JUDGE_DELAY_SECONDS"
        local delayed_output=""
        delayed_output=$(capture_tmux_output "$tmux_session" "$tmux_socket")
        if [ -n "$delayed_output" ]; then
            output="$delayed_output"
            log "Re-captured from tmux after delay (${#output} chars)"
            log "--- Re-captured content start ---"
            log "$output"
            log "--- Re-captured content end ---"
        else
            log "Re-capture after delay failed, keep previous output (${#output} chars)"
        fi
    fi

    # 检测完成状态
    local completion_status=$(check_task_completion "$output")
    if [ "$completion_status" = failed ] && \
        jq -e '.business_validation_required == true' "$meta_file" >/dev/null 2>&1; then
        completion_status="done"
    fi
    log "Task completion status: $completion_status"

    # 归属门禁：仅当判为 done 时，校验这次 Stop 是否真属于当前 part 且 prompt 已提交。
    # 不通过 → 写 uncertain（不写 done），交给 batch 继续等待真正完成的那次 Stop。
    if [ "$completion_status" = "done" ]; then
        local started_at
        started_at=$(jq -r '.started_at // ""' "$meta_file" 2>/dev/null || echo "")
        if ! stop_belongs_to_current_task "$started_at" "$tmux_session" "$tmux_socket"; then
            log "Stop not belong to current part (session transcript last-user < started_at / prompt unsubmitted) → uncertain"
            mark_task_uncertain "$session_name" "$task_id" "$session_dir" "stop_not_belong_or_prompt_unsubmitted"
            return 0
        fi
    fi

    # 根据状态处理
    local write_status=""
    case "$completion_status" in
        "done")
            if jq -e '.business_validation_required == true' "$meta_file" >/dev/null 2>&1; then
                write_status="awaiting_validation"
            else
                write_status="done"
            fi
            ;;
        "failed")
            write_status="failed"
            log "Task explicitly blocked or failed, marking as failed"
            ;;
        "waiting_input")
            write_status="waiting_input"
            log "Task waiting for input, not marking as done"
            ;;
        *)
            mark_task_uncertain "$session_name" "$task_id" "$session_dir" "unknown_completion_status"
            return 0
            ;;
    esac

    # 更新任务状态文件
    if [ -n "$write_status" ]; then
        local done_ts="$(date -Iseconds)"
        local task_file="${RESULT_DIR}/tasks/${task_id}.json"

        if [ -f "$task_file" ]; then
            jq --arg ts "$done_ts" \
               --arg output "$output" \
               --arg sid "$SESSION_ID" \
               --arg status "$write_status" \
               '. + {status: $status, timestamp: $ts, output: $output, session_id: $sid, completed_at: $ts}' \
               "$task_file" > "${task_file}.tmp" 2>/dev/null && mv "${task_file}.tmp" "$task_file"
            log "Updated task status: tasks/${task_id}.json (status=$write_status)"
        else
            jq -n \
                --arg sid "$SESSION_ID" \
                --arg ts "$done_ts" \
                --arg output "$output" \
                --arg task "$task_name" \
                --arg task_id "$task_id" \
                --arg target "$feishu_target" \
                --arg tmux_session "$tmux_session" \
                --arg tmux_socket "$tmux_socket" \
                --arg status "$write_status" \
                '{session_id: $sid, timestamp: $ts, output: $output, task_name: $task, task_id: $task_id, feishu_target: $target, tmux_session: $tmux_session, tmux_socket: $tmux_socket, status: $status, completed_at: $ts}' \
                > "$task_file" 2>/dev/null
            log "Created task status: tasks/${task_id}.json (status=$write_status)"
        fi

        # 更新 meta 文件
        jq --arg ts "$done_ts" --arg task_id "$task_id" --arg status "$write_status" \
            'if (.completed_at // "") == "" then . + {completed_at: $ts, task_id: $task_id, status: $status} else . + {task_id: $task_id, status: $status} end' \
            "$meta_file" > "${meta_file}.tmp" 2>/dev/null && mv "${meta_file}.tmp" "$meta_file"

        # 清理 current-task-id.txt
        if [ "$write_status" = "done" ]; then
            if [ -f "${session_dir}/current-task-id.txt" ]; then
                rm -f "${session_dir}/current-task-id.txt"
                log "Cleaned current-task-id.txt for session: $session_name"
            fi
        fi

        if [ -z "$completed_at" ]; then
            completed_at="$done_ts"
        fi
    fi

    # 只有真正完成才发送通知
    if [ "$write_status" != "done" ]; then
        log "Task not done, skip notifications"
        return 0
    fi

    # 发送通知（使用 per-session lock）
    local lock_file="${session_dir}/.hook-lock"
    local lock_age_limit=30
    local skip_notify=false

    # 检查是否有有效输出
    local has_valid_output=false
    if [ -n "$output" ] && ! echo "$output" | grep -qF "任务已完成，但输出为空"; then
        has_valid_output=true
    fi

    # 去重检查（per-session）
    # if [ "$has_valid_output" = true ]; then
    #     if [ -f "$lock_file" ]; then
    #         local lock_time=$(stat -c %Y "$lock_file" 2>/dev/null || echo 0)
    #         local now=$(date +%s)
    #         local age=$(( now - lock_time ))
    #         if [ "$age" -lt "$lock_age_limit" ]; then
    #             skip_notify=true
    #             log "Duplicate notification within ${age}s for session $session_name, skip"
    #         fi
    #     fi
    #     if [ "$skip_notify" != true ]; then
    #         touch "$lock_file"
    #     fi
    # fi

    # 任务级去重
    # local notify_key="${task_name}|${completed_at}|${feishu_target}"
    # local notify_key_file="${session_dir}/.last-notify-key"
    # if [ -f "$notify_key_file" ] && [ "$(cat "$notify_key_file" 2>/dev/null)" = "$notify_key" ]; then
    #     log "Skip duplicate notification for key=$notify_key"
    #     skip_notify=true
    # fi

    if [ "$skip_notify" = true ]; then
        log "Skip notifications due to duplicate check"
        return 0
    fi

    # 发送飞书消息
    if [ -n "$feishu_target" ] && [ -x "$OPENCLAW_BIN" ]; then
        local summary=$(echo "$output" | tail -c 1000 | tr '\n' ' ')
        local msg="🤖 *Claude Code 任务完成*
📋 任务: ${task_name}
📝 结果摘要:
\`\`\`
${summary:0:800}
\`\`\`"

        timeout 30 "$OPENCLAW_BIN" message send \
            --channel feishu \
            --target "$feishu_target" \
            --message "$msg" 2>/dev/null && log "Sent Feishu message to $feishu_target" || log "Feishu send failed"
    fi

    # send-keys 通知父 CC tmux session（带延迟重试）
    local parent_session
    parent_session=$(jq -r '.parent_tmux_session // empty' "$meta_file" 2>/dev/null || echo "")
    if [ -n "$parent_session" ]; then
        local parent_socket="/home/ubuntu/clawdbot-tmux-sockets/claude-code.sock"
        if tmux -S "$parent_socket" has-session -t "$parent_session" 2>/dev/null; then
            local notify_msg="子任务 ${task_name} 已完成，请根据对应 SKILL.md 文档或 prompt 检查任务完成进展，没有问题则请继续执行下一阶段。"

            # 第一次尝试：发送文本 + Enter
            tmux -S "$parent_socket" send-keys -t "${parent_session}" "$notify_msg" Enter 2>/dev/null
            log "Sent send-keys to parent session: $parent_session (attempt 1)"

            # 延迟 60 秒后补发 Enter：如果父会话正在生成，第一次 Enter 可能被 TUI 吃掉
            # 60 秒后父会话可能已空闲，补发的 Enter 能提交输入框里的文本
            (sleep 60 && tmux -S "$parent_socket" send-keys -t "${parent_session}" Enter 2>/dev/null && log "Sent delayed Enter to parent: $parent_session") &
        else
            log "Parent session $parent_session not found, skipping send-keys"
        fi
    fi

    log "<<< Task processing completed: $session_name"
    return 0
}

log "=== Hook fired ==="

# ---- 读 stdin ----
INPUT=""
if [ -t 0 ]; then
    log "stdin is tty, skip"
elif [ -e /dev/stdin ]; then
    INPUT=$(timeout 2 cat /dev/stdin 2>/dev/null || true)
fi

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")
CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || echo "")
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // "unknown"' 2>/dev/null || echo "unknown")
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")

log "session=$SESSION_ID cwd=$CWD event=$EVENT transcript=$TRANSCRIPT_PATH"
log "env task_id=${CODING_AGENT_TASK_ID:-} tmux_session=${CODING_AGENT_TMUX_SESSION:-} session_dir=${CODING_AGENT_SESSION_DIR:-}"

# ---- 防重复参数 ----
# 注意: LOCK_FILE 将在找到会话后设置为 per-session lock
LOCK_FILE=""
LOCK_AGE_LIMIT=30  # 30秒内重复触发视为同一任务
SKIP_NOTIFY=false

# ---- 查找对应的会话目录 ----
# 收集所有 running 任务
declare -a RUNNING_TASKS
for session_dir in "${RESULT_DIR}/sessions/"*; do
    if [ -d "$session_dir" ] && [ -f "${session_dir}/current-task-id.txt" ]; then
        candidate_task_id=$(cat "${session_dir}/current-task-id.txt" 2>/dev/null || echo "")
        if [ -n "$candidate_task_id" ] && [ -f "${session_dir}/task-meta.json" ]; then
            # 检查任务状态是否为 running
            status=$(jq -r '.status // ""' "${session_dir}/task-meta.json" 2>/dev/null || echo "")
            if [ "$status" = "running" ]; then
                session_name=$(basename "$session_dir")
                RUNNING_TASKS+=("$session_name:$candidate_task_id:${session_dir}")
                log "Found running task: $session_name, task_id: $candidate_task_id"
            fi
        fi
    fi
done

log "Total running tasks found: ${#RUNNING_TASKS[@]}"

# 如果找到 running 任务，仅处理当前 hook 对应的目标任务（会话隔离）
    if [ ${#RUNNING_TASKS[@]} -gt 0 ]; then
        log "Running tasks detected: ${#RUNNING_TASKS[@]} (session-isolated mode)"
        TARGET_TASK_INFO=$(resolve_target_task || true)

    if [ -z "$TARGET_TASK_INFO" ]; then
        log "No unique target task resolved; ignoring callback without changing any task"
        log "=== Hook completed (session-isolated skip) ==="
        exit 0
    fi

    IFS=':' read -r target_session_name target_task_id target_session_dir <<< "$TARGET_TASK_INFO"
    log "Resolved target task: ${target_session_name} / ${target_task_id}"
    process_task "$target_session_name" "$target_task_id" "$target_session_dir" "true"

    log "=== Hook completed (session-isolated mode) ==="
    exit 0
fi

# 如果没有找到任何 running 任务，回退到全局 task-meta.json（向后兼容）
if [ -f "${RESULT_DIR}/task-meta.json" ]; then
    log "No running tasks found, fallback to global task-meta.json (legacy mode)"
    # 使用旧的单任务处理逻辑（保持向后兼容）
    META_FILE="${RESULT_DIR}/task-meta.json"
    TASK_ID=""
    TMUX_SESSION=""
    # 继续执行原有的单任务逻辑
else
    log "ERROR: No running tasks and no global task-meta.json found"
    exit 1
fi

# ---- 读取任务元数据（尽早，避免猜错 tmux 会话）----
TASK_NAME=$(jq -r ' .task_name // "unknown" ' "$META_FILE" 2>/dev/null || echo "unknown")
if [ -z "$TASK_ID" ]; then
    TASK_ID=$(jq -r '.task_id // ""' "$META_FILE" 2>/dev/null || echo "")
fi
FEISHU_TARGET=$(jq -r '.feishu_target // ""' "$META_FILE" 2>/dev/null || echo "")
TASK_COMPLETED_AT=$(jq -r '.completed_at // ""' "$META_FILE" 2>/dev/null || echo "")
META_RUN_MODE=$(jq -r '.run_mode // "headless"' "$META_FILE" 2>/dev/null || echo "headless")
if [ -z "$TMUX_SESSION" ]; then
    TMUX_SESSION=$(jq -r '.tmux_session // ""' "$META_FILE" 2>/dev/null || echo "")
fi
META_TMUX_SOCKET=$(jq -r '.tmux_socket // ""' "$META_FILE" 2>/dev/null || echo "")

log "Meta: task=$TASK_NAME task_id=$TASK_ID target=$FEISHU_TARGET completed_at=$TASK_COMPLETED_AT run_mode=$META_RUN_MODE tmux_session=$TMUX_SESSION"

# ---- 读取 Claude Code 输出（快速路径，避免 hook 超时）----
OUTPUT=""
TASK_OUTPUT="${RESULT_DIR}/task-output.txt"
IS_TMUX_MODE=false
TMUX_SOCKET="${META_TMUX_SOCKET:-/home/ubuntu/clawdbot-tmux-sockets/claude-code.sock}"
TMUX_SESSION="${TMUX_SESSION:-claude-coding-agent}"

# 优先根据元数据判断 tmux 模式
if [ "$META_RUN_MODE" = "tmux" ]; then
    IS_TMUX_MODE=true
fi
# 兼容旧元数据：从 task-output 启动信息判断
if [ -f "$TASK_OUTPUT" ] && grep -q "Started interactive Claude Code in tmux" "$TASK_OUTPUT" 2>/dev/null; then
    IS_TMUX_MODE=true
fi

if [ "$IS_TMUX_MODE" = true ]; then
    log "Detected tmux mode, target session=$TMUX_SESSION socket=$TMUX_SOCKET"

    if tmux -S "$TMUX_SOCKET" has-session -t "$TMUX_SESSION" 2>/dev/null; then
        TMUX_OUTPUT=$(tmux -S "$TMUX_SOCKET" capture-pane -p -J -t "${TMUX_SESSION}:0.0" -S -500 2>/dev/null || echo "")
        if [ -n "$TMUX_OUTPUT" ]; then
            CLEANED_OUTPUT=$(echo "$TMUX_OUTPUT" | \
                sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | \
                grep -v -E "(accept edits on|Meandering|Dilly-dallying|Tip:|running stop hook|Use /btw)" | \
                grep -v -E "^[─━═│┃║┌┐└┘├┤┬┴┼╔╗╚╝╠╣╦╩╬ ]+$" | \
                sed 's/[[:space:]]\{2,\}/ /g' | \
                sed '/^[[:space:]]*$/d' | \
                grep -v '^[[:space:]]*$' | \
                tail -n 20 | \
                head -c 2000)

            if [ -n "$CLEANED_OUTPUT" ] && [ ${#CLEANED_OUTPUT} -gt 30 ]; then
                OUTPUT="$CLEANED_OUTPUT"
                log "Captured from tmux (${#OUTPUT} chars, cleaned)"
                log "--- Captured content start ---"
                log "$OUTPUT"
                log "--- Captured content end ---"
            else
                log "Tmux output too short after cleaning (${#CLEANED_OUTPUT} chars), fallback"
            fi
        else
            log "Failed to capture from tmux, fallback"
        fi
    else
        log "Tmux session not found: $TMUX_SESSION"
    fi
fi

# 来源1: task-output.txt（快速读取，不重试等待）
if [ -z "$OUTPUT" ] && [ -f "$TASK_OUTPUT" ] && [ -s "$TASK_OUTPUT" ]; then
    TEMP_OUTPUT=$(tail -c 4000 "$TASK_OUTPUT")
    if ! echo "$TEMP_OUTPUT" | grep -q "Started interactive Claude Code in tmux"; then
        OUTPUT="$TEMP_OUTPUT"
        log "Output from task-output.txt (${#OUTPUT} chars)"
    else
        log "task-output contains only tmux bootstrap lines"
    fi
fi

# 来源2: /tmp/claude-code-output.txt（备用）
if [ -z "$OUTPUT" ] && [ -f "/tmp/claude-code-output.txt" ] && [ -s "/tmp/claude-code-output.txt" ]; then
    OUTPUT=$(tail -c 4000 /tmp/claude-code-output.txt)
    log "Output from /tmp fallback (${#OUTPUT} chars)"
fi

# 来源3: 工作目录（兜底）
if [ -z "$OUTPUT" ] && [ -n "$CWD" ] && [ -d "$CWD" ]; then
    FILES=$(ls -1t "$CWD" 2>/dev/null | head -20 | tr '\n' ', ')
    OUTPUT="Working dir: ${CWD}\nFiles: ${FILES}"
    log "Output from dir listing (fallback)"
fi

# 来源4: 空摘要兜底
if [ -z "$OUTPUT" ]; then
    OUTPUT="任务已完成，但输出为空。请检查工作目录或日志文件。"
    log "Using empty output fallback message"
fi

# tmux 模式：等待后再重抓一次，减少过早判定
if [ "$IS_TMUX_MODE" = true ] && [ "${COMPLETION_JUDGE_DELAY_SECONDS:-0}" -gt 0 ]; then
    log "Delay completion check by ${COMPLETION_JUDGE_DELAY_SECONDS}s (legacy tmux mode)"
    sleep "$COMPLETION_JUDGE_DELAY_SECONDS"
    if tmux -S "$TMUX_SOCKET" has-session -t "$TMUX_SESSION" 2>/dev/null; then
        TMUX_OUTPUT_DELAYED=$(tmux -S "$TMUX_SOCKET" capture-pane -p -J -t "${TMUX_SESSION}:0.0" -S -500 2>/dev/null || echo "")
        if [ -n "$TMUX_OUTPUT_DELAYED" ]; then
            CLEANED_OUTPUT_DELAYED=$(echo "$TMUX_OUTPUT_DELAYED" | \
                sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | \
                grep -v -E "(accept edits on|Meandering|Dilly-dallying|Tip:|running stop hook|Use /btw)" | \
                grep -v -E "^[─━═│┃║┌┐└┘├┤┬┴┼╔╗╚╝╠╣╦╩╬ ]+$" | \
                sed 's/[[:space:]]\{2,\}/ /g' | \
                sed '/^[[:space:]]*$/d' | \
                grep -v '^[[:space:]]*$' | \
                tail -n 20 | \
                head -c 2000)
            if [ -n "$CLEANED_OUTPUT_DELAYED" ] && [ ${#CLEANED_OUTPUT_DELAYED} -gt 30 ]; then
                OUTPUT="$CLEANED_OUTPUT_DELAYED"
                log "Re-captured from tmux after delay (${#OUTPUT} chars, cleaned)"
                log "--- Re-captured content start ---"
                log "$OUTPUT"
                log "--- Re-captured content end ---"
            else
                log "Delayed tmux output too short after cleaning (${#CLEANED_OUTPUT_DELAYED} chars), keep previous output"
            fi
        else
            log "Delayed tmux capture empty, keep previous output"
        fi
    else
        log "Tmux session missing after delay: $TMUX_SESSION"
    fi
fi

# ---- 防重复：仅跳过通知，不跳过 done 写回 ----
HAS_VALID_OUTPUT=false
if [ -n "$OUTPUT" ] && ! echo "$OUTPUT" | grep -qF "任务已完成，但输出为空"; then
    HAS_VALID_OUTPUT=true
fi

# 设置 legacy mode 的 lock file（全局，向后兼容）
LOCK_FILE="${RESULT_DIR}/.hook-lock"

if [ "$HAS_VALID_OUTPUT" = true ]; then
    if [ -f "$LOCK_FILE" ]; then
        LOCK_TIME=$(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0)
        NOW=$(date +%s)
        AGE=$(( NOW - LOCK_TIME ))
        if [ "$AGE" -lt "$LOCK_AGE_LIMIT" ]; then
            SKIP_NOTIFY=true
            log "Duplicate hook within ${AGE}s (with valid output), skip notifications"
        fi
    fi
    if [ "$SKIP_NOTIFY" != true ]; then
        touch "$LOCK_FILE"
    fi
else
    log "No valid output yet, allow notification fallback"
fi

DONE_TS="$(date -Iseconds)"

# 检测任务完成状态
COMPLETION_STATUS=$(check_task_completion "$OUTPUT")
log "Task completion status: $COMPLETION_STATUS"

# 归属门禁（legacy）：仅当判为 done 时校验 Stop 归属与 prompt 是否提交，不通过降级 uncertain
if [ "$COMPLETION_STATUS" = "done" ]; then
    LEGACY_STARTED_AT=$(jq -r '.started_at // ""' "$META_FILE" 2>/dev/null || echo "")
    if ! stop_belongs_to_current_task "$LEGACY_STARTED_AT" "$TMUX_SESSION" "$TMUX_SOCKET"; then
        log "Stop not belong to current part (legacy: session transcript last-user < started_at / prompt unsubmitted) → uncertain"
        COMPLETION_STATUS="uncertain"
    fi
fi

# ---- 写入结果 JSON（优先保证 batch 能收到 done）----
# 1. 写入 per-task 状态文件（主要）
if [ -n "$TASK_ID" ]; then
    TASK_FILE="${RESULT_DIR}/tasks/${TASK_ID}.json"

    # 根据完成状态决定写入的 status
    if [ "$COMPLETION_STATUS" = "done" ]; then
        WRITE_STATUS="done"
    elif [ "$COMPLETION_STATUS" = "waiting_input" ]; then
        WRITE_STATUS="waiting_input"
        log "Task is waiting for user input, not marking as done"
    elif [ "$COMPLETION_STATUS" = "uncertain" ]; then
        WRITE_STATUS="uncertain"
        log "Task uncertain (stop not belong / prompt unsubmitted), not marking as done"
    else
        # 默认判定为完成
        WRITE_STATUS="done"
        log "Task completion unknown ($COMPLETION_STATUS), default to done"
    fi

    # 只有在有明确状态时才写入
    if [ -n "$WRITE_STATUS" ]; then
        # 如果文件已存在（dispatch 写入的元数据），则更新；否则创建新文件
        if [ -f "$TASK_FILE" ]; then
            # 更新现有文件：保留原有字段，只更新 status、output、timestamp
            jq --arg ts "$DONE_TS" \
               --arg output "$OUTPUT" \
               --arg sid "$SESSION_ID" \
               --arg status "$WRITE_STATUS" \
               '. + {status: $status, timestamp: $ts, output: $output, session_id: $sid, completed_at: $ts}' \
               "$TASK_FILE" > "${TASK_FILE}.tmp" 2>/dev/null && mv "${TASK_FILE}.tmp" "$TASK_FILE"
            log "Updated per-task status: tasks/${TASK_ID}.json (status=$WRITE_STATUS)"
        else
            # 文件不存在，创建新文件（向后兼容）
            jq -n \
                --arg sid "$SESSION_ID" \
                --arg ts "$DONE_TS" \
                --arg cwd "$CWD" \
                --arg event "$EVENT" \
                --arg output "$OUTPUT" \
                --arg task "$TASK_NAME" \
                --arg task_id "$TASK_ID" \
                --arg target "$FEISHU_TARGET" \
                --arg tmux_session "$TMUX_SESSION" \
                --arg tmux_socket "$TMUX_SOCKET" \
                --arg status "$WRITE_STATUS" \
                '{session_id: $sid, timestamp: $ts, cwd: $cwd, event: $event, output: $output, task_name: $task, task_id: $task_id, feishu_target: $target, tmux_session: $tmux_session, tmux_socket: $tmux_socket, status: $status, completed_at: $ts}' \
                > "$TASK_FILE" 2>/dev/null
            log "Created per-task status: tasks/${TASK_ID}.json (status=$WRITE_STATUS)"
        fi
    fi
fi

# 2. 写入 latest.json（向后兼容）
if [ -n "$WRITE_STATUS" ]; then
    jq -n \
        --arg sid "$SESSION_ID" \
        --arg ts "$DONE_TS" \
        --arg cwd "$CWD" \
        --arg event "$EVENT" \
        --arg output "$OUTPUT" \
        --arg task "$TASK_NAME" \
        --arg task_id "$TASK_ID" \
        --arg target "$FEISHU_TARGET" \
        --arg tmux_session "$TMUX_SESSION" \
        --arg tmux_socket "$TMUX_SOCKET" \
        --arg status "$WRITE_STATUS" \
        '{session_id: $sid, timestamp: $ts, cwd: $cwd, event: $event, output: $output, task_name: $task, task_id: $task_id, feishu_target: $target, tmux_session: $tmux_session, tmux_socket: $tmux_socket, status: $status}' \
        > "${RESULT_DIR}/latest.json" 2>/dev/null

    log "Wrote latest.json (backward compatibility, status=$WRITE_STATUS)"
fi

# 同步更新 task-meta，避免 completed_at 为空
if [ -f "$META_FILE" ] && [ -n "$WRITE_STATUS" ]; then
    jq --arg ts "$DONE_TS" --arg task_id "$TASK_ID" --arg status "$WRITE_STATUS" \
        'if (.completed_at // "") == "" then . + {completed_at: $ts, task_id: $task_id, status: $status} else . + {task_id: $task_id, status: $status} end' \
        "$META_FILE" > "${META_FILE}.tmp" 2>/dev/null && mv "${META_FILE}.tmp" "$META_FILE"

    if [ -z "$TASK_COMPLETED_AT" ]; then
        TASK_COMPLETED_AT="$DONE_TS"
    fi

    # 只有在任务真正完成时才清理 current-task-id.txt
    if [ "$WRITE_STATUS" = "done" ]; then
        SESSION_DIR=$(dirname "$META_FILE")
        if [ -f "${SESSION_DIR}/current-task-id.txt" ]; then
            rm -f "${SESSION_DIR}/current-task-id.txt"
            log "Cleaned current-task-id.txt for session: $(basename "$SESSION_DIR")"
        fi
    fi
fi
if [ -z "$TASK_COMPLETED_AT" ]; then
    TASK_COMPLETED_AT="$DONE_TS"
fi

# 如果任务未真正完成，跳过通知
if [ "$COMPLETION_STATUS" != "done" ]; then
    log "Task not completed (status=$COMPLETION_STATUS), skip notifications"
    log "=== Hook completed ==="
    exit 0
fi

if [ "$SKIP_NOTIFY" = true ]; then
    log "Skip notifications due to duplicate lock window"
    log "=== Hook completed ==="
    exit 0
fi

# 即使输出为空也发送通知，让用户知道任务已完成
if [ "$HAS_VALID_OUTPUT" != true ]; then
    log "Output is empty/fallback, but will still send notification"
fi

# 任务级去重：同一 task_name + completed_at 只通知一次
NOTIFY_KEY="${TASK_NAME}|${TASK_COMPLETED_AT}|${FEISHU_TARGET}"
NOTIFY_KEY_FILE="${RESULT_DIR}/.last-notify-key"
if [ -f "$NOTIFY_KEY_FILE" ] && [ "$(cat "$NOTIFY_KEY_FILE" 2>/dev/null)" = "$NOTIFY_KEY" ]; then
    log "Skip duplicate notification for key=$NOTIFY_KEY"
    log "=== Hook completed ==="
    exit 0
fi

# ---- 方式1: 直接发飞书消息（如果有目标）----
if [ -n "$FEISHU_TARGET" ] && [ -x "$OPENCLAW_BIN" ]; then
    SUMMARY=$(echo "$OUTPUT" | tail -c 1000 | tr '\n' ' ')
    MSG="🤖 *Claude Code 任务完成*
📋 任务: ${TASK_NAME}
📝 结果摘要:
\`\`\`
${SUMMARY:0:800}
\`\`\`"

    timeout 8 "$OPENCLAW_BIN" message send \
        --channel feishu \
        --target "$FEISHU_TARGET" \
        --message "$MSG" 2>/dev/null && log "Sent Feishu message to $FEISHU_TARGET" || log "Feishu send failed"
fi

echo "$NOTIFY_KEY" > "$NOTIFY_KEY_FILE" 2>/dev/null || true
log "Recorded notify key: $NOTIFY_KEY"

log "=== Hook completed ==="
exit 0
