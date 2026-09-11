#!/usr/bin/env bash
# website-stage-router.sh — 基于 Claude Code Stop Hook 的建站阶段自动流转器 (官方标准 block + response)
set -uo pipefail

LOG="/home/ubuntu/clawd/data/claude-code-results/website-stage-router.log"
log() { echo "[$(date -Iseconds)] $*" >> "$LOG"; }

# 1. 判定会话名称
SESSION_NAME="${CLAW_REMOTE_TMUX_SESSION:-${CODING_AGENT_TMUX_SESSION:-}}"
if [ -z "$SESSION_NAME" ] && [ -n "${TMUX_PANE:-}" ]; then
  SESSION_NAME=$(tmux display-message -p '#{session_name}' 2>/dev/null || true)
fi

if [[ ! "$SESSION_NAME" =~ website-create ]]; then
  exit 0
fi

log "捕获到建站会话 Stop 事件: ${SESSION_NAME}"

# 2. 精准提取 DOMAIN
DOMAIN=""
# 优先从 task-meta.json 中提取
TASK_META="/home/ubuntu/clawd/data/claude-code-results/sessions/${SESSION_NAME}/task-meta.json"
if [ -f "$TASK_META" ]; then
  PROMPT_TEXT=$(jq -r '.prompt' "$TASK_META" 2>/dev/null || echo "")
  # 优先从明确标注的 DOMAIN 参数行提取
  DOMAIN=$(echo "$PROMPT_TEXT" | grep -oP '(?<=DOMAIN:\s)[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}' | head -1 || true)
  # 备选：通用合法域名提取并排除常见占位符
  if [ -z "$DOMAIN" ]; then
    DOMAIN=$(echo "$PROMPT_TEXT" | grep -oE '[a-zA-Z0-9][-a-zA-Z0-9]*\.[a-zA-Z]{2,}' | grep -vE 'example\.(com|org|net)' | head -1 || true)
  fi
fi

# 备选：从 0_meta 目录或会话名推导
if [ -z "$DOMAIN" ]; then
  # 匹配 0_meta 下已有的目录
  DIR_MATCH=$(ls -d /home/ubuntu/Documents/GameProjects/0_meta/* 2>/dev/null | xargs -n1 basename | grep -i "$(echo "$SESSION_NAME" | sed -E 's/^website-create-//; s/-[0-9]+.*$//')" | head -1 || true)
  if [ -n "$DIR_MATCH" ]; then
    DOMAIN="${DIR_MATCH//_/.}"
  else
    DOMAIN=$(echo "$SESSION_NAME" | sed -E 's/^website-create-//; s/-[0-9]+.*$//; s/-wiki$//' | tr '-' '.')
  fi
fi

DOMAIN_SLUG="${DOMAIN//./_}"
META_DIR="/home/ubuntu/Documents/GameProjects/0_meta/${DOMAIN_SLUG}"
TMUX_SOCKET="/home/ubuntu/clawdbot-tmux-sockets/claude-code.sock"

log "解析到域名: DOMAIN=${DOMAIN}, META_DIR=${META_DIR}"

if [ ! -d "$META_DIR" ]; then
  log "元数据目录尚未建立: ${META_DIR}，等待初始化或由前序步骤创建"
  exit 0
fi

# 检查线上 200/301 探活（若已上线则完全退出）
HTTP_CODE=$(curl -fsSL -o /dev/null -w "%{http_code}" --max-time 8 "https://${DOMAIN}" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "301" ]]; then
  log "线上域名 ${DOMAIN} 探活已通过 (HTTP ${HTTP_CODE})，整站已上线，流程完毕。"
  exit 0
fi

# 双重推进保险：同时进行 官方 JSON Block 推进 与 终端后台注入，确保无论何种环境必被激活
drive_stage() {
  local next_stage="$1"
  local prompt_text="$2"
  log "触发自动接续: [${next_stage}] -> ${prompt_text}"

  # 后台延时向 tmux 补一个兜底回车/注入，确保终端不卡顿
  (
    sleep 2
    tmux -S "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" C-u "$prompt_text" C-m 2>/dev/null || true
  ) &

  # Claude Code Stop Hook 标准 JSON 协议阻断停止并喂入下一轮 Prompt
  cat << JSON_RESP
{
  "decision": "block",
  "reason": "建站流程未完成，自动推进至${next_stage}：${prompt_text}"
}
JSON_RESP
  exit 0
}

# 阶段 3 检查: 缺少 00基础信息.md 或 00首页信息.md
if [ ! -f "${META_DIR}/00基础信息.md" ] || [ ! -f "${META_DIR}/00首页信息.md" ]; then
  drive_stage "阶段3" "严禁输出分析总结！立即调用 Bash 运行 chatgpt-dev-info 补齐 00基础信息.md 与 00首页信息.md，完成后立即推进下一阶段。"
fi

# 阶段 4 检查: 缺少 languages.json
if [ ! -f "${META_DIR}/languages.json" ]; then
  drive_stage "阶段4" "严禁输出分析总结！立即从 00基础信息.md 提取并生成 languages.json，完成后立即推进下一阶段。"
fi

# 阶段 5 检查: 缺少 Favicon
if [ ! -f "${META_DIR}/favicon/favicon.ico" ] && [ ! -f "${META_DIR}/output/favicon.ico" ] && [ ! -f "${META_DIR}/favicon.ico" ]; then
  drive_stage "阶段5" "严禁输出分析总结！立即调用 generate_favicon_package.py 生成全套 5 尺寸 Favicon 图标包，完成后立即推进下一阶段。"
fi

# 阶段 6 检查: 缺少 关键词.json
if [ ! -f "${META_DIR}/output/关键词.json" ] && [ ! -f "${META_DIR}/关键词.json" ]; then
  drive_stage "阶段6" "严禁输出分析总结！立即运行 long-tail-keyword-mining 系列脚本挖掘生成 关键词.json，完成后立即推进下一阶段。"
fi

# 阶段 7 检查: 检查文章数量（<10 篇说明文章未齐备）
ARTICLE_COUNT=$(find "${META_DIR}" -type f \( -name "*.md" -o -name "*.mdx" \) 2>/dev/null | grep -E "articles|output" | wc -l | tr -dc '0-9' || echo "0")
ARTICLE_COUNT=${ARTICLE_COUNT:-0}
if (( ARTICLE_COUNT < 10 )); then
  drive_stage "阶段7" "严禁输出分析总结！立即以低内存模式运行 seoscout translate 或 write-articles 完成全部多语言 MDX 文章资产生成，完成后立即推进下一阶段。"
fi

# 阶段 8-9 检查: 文章齐备但站点未上线 -> 推进重构与部署
drive_stage "阶段8-9" "文章资产已齐备，严禁输出分析总结！立即调用 /home/ubuntu/.openclaw/skills/game-refactor/scripts/run-refactor.sh 完成代码重构 Part 1~7 并调用 workers-deploy 完成整站线上部署与飞书通报！"
