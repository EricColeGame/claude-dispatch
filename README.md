# Claude Dispatch

`claude-dispatch/` 是独立的 Claude Code 任务派发目录。它负责把任务送进 Claude Code tmux 会话，让学生可以在 tmux 或 Claw Remote 面板里同步观察执行现场。

## 目录结构

```text
claude-dispatch/
  SKILL.md                    # Claude dispatch skill：告诉后续 agent 怎么调用派发程序
  dispatch-config.json        # 默认消息群与 CDP → 飞书群映射
  dispatch-claude-code.sh      # 单任务派发入口
  batch-dispatch.sh            # 批量串行派发入口
  claude_code_run.py           # Claude Code 运行器
  BATCH_DISPATCH_README.md     # 批量派发补充说明
  hooks/notify-agi.sh          # Claude Stop / SessionEnd 完成通知 hook
```

## 学生需要准备什么

必需：

- `tmux`
- `jq`
- `python3`
- `claude` CLI，并且学生自己已经登录 / 配置好 Claude Code。

安装系统依赖：

```bash
apt-get update
apt-get install -y tmux jq python3 git
```

确认 Claude Code 可用：

```bash
command -v claude
claude --version
claude
```

如果 `command -v claude` 的输出不是 `/usr/local/bin/claude`（例如装在 `/usr/bin/claude` 或 nvm 路径下），需要把 `CLAUDE_CODE_BIN` 写进 `~/.bashrc`，否则派发器会找不到 claude 二进制：

```bash
# 把 claude 实际路径写进环境变量，永久生效
echo "export CLAUDE_CODE_BIN=\"$(command -v claude)\"" >> ~/.bashrc
source ~/.bashrc
```

> `claude_code_run.py` 内部已经做了三层兜底：先读 `CLAUDE_CODE_BIN` 环境变量，再从 `PATH` 里自动查找 `claude`，最后才回退到 `/usr/local/bin/claude`。多数情况下不设环境变量也能找到；设环境变量是为了**保险**——某些 cron / 非交互 shell 的 `PATH` 不完整，自动查找可能漏掉。

默认不需要 `.env`。不传 `--model` 时，脚本直接使用学生自己 Claude Code 的默认模型配置；只有显式传 `--model` 时，才临时覆盖本次任务模型。

## 安装位置

推荐固定放到 OpenClaw skills 目录下：

```text
/root/.openclaw/skills/claude-dispatch
```

确认脚本可执行：

```bash
cd /root/.openclaw/skills/claude-dispatch
chmod +x *.sh *.py hooks/*.sh
```

## 安装后先配置消息群

首次派发任务前，必须打开当前项目目录里的配置文件：

```text
/root/.openclaw/skills/claude-dispatch/dispatch-config.json
```

默认内容使用课堂占位值，不能直接照搬。把其中的飞书 `chat_id` 全部替换成学生自己的真实群 ID：

```json
{
  "default_cdp": "9222",
  "default_target": "oc_xxxx_notification",
  "cdp_targets": {
    "9222": "oc_xxxx_notification",
    "9223": "oc_xxxx_demand",
    "9224": "oc_xxxx_code_1",
    "9225": "oc_xxxx_code_2",
    "9226": "oc_xxxx_code_3"
  }
}
```

- `default_cdp`：默认浏览器端口；未传 `--cdp` 时使用该端口，显式传入时覆盖默认值；
- `default_target`：默认工位的消息通知群；与 `default_cdp` 组成默认浏览器和通知组合；
- `cdp_targets`：CDP 端口与飞书群的对应关系；只传 `--cdp 9226` 时，dispatch 自动使用 `9226` 对应的群；
- `--target`：可选的临时覆盖；只有某次任务要改发其他群时才需要传。

`cdp_targets[default_cdp]` 必须与 `default_target` 相同；本例即 `9222 → oc_xxxx_notification`。

检查 JSON 格式：

```bash
cd /root/.openclaw/skills/claude-dispatch
jq empty dispatch-config.json
jq '.default_cdp, .default_target, .cdp_targets' dispatch-config.json
```

必须看到自己的真实群 ID，不能仍然是 `oc_xxxx_*`。配置完成后，dispatch 的选择顺序是：

```text
显式 --target
→ 否则按 --cdp 查询 cdp_targets
→ 否则使用 default_target
```

## 配置 Claude Code hook

这是完整 dispatch 闭环的关键配置。只想验证“任务能进入 tmux 会话”时可以暂时不配；但要让任务完成后自动回写状态、写入 `tasks/<TASK_ID>.json`、更新 `latest.json`，就必须先配置这个 hook。

把下面配置合并进 `~/.claude/settings.json`：

```jsonc
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/root/.openclaw/skills/claude-dispatch/hooks/notify-agi.sh",
            "timeout": 300
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/root/.openclaw/skills/claude-dispatch/hooks/notify-agi.sh",
            "timeout": 300
          }
        ]
      }
    ]
  }
}
```

验证：

```bash
test -x /root/.openclaw/skills/claude-dispatch/hooks/notify-agi.sh
jq '.hooks' ~/.claude/settings.json
```

## 最小启动

下面不传 `--target`，用于验证刚才配置的 `default_target` 是否生效。

```bash
cd /root/.openclaw/skills/claude-dispatch

env -u CLAUDECODE ./dispatch-claude-code.sh \
  --tmux-session demo-claude-readme \
  --workdir /root/Documents/dispatch-demo/claude \
  -p "在当前目录创建 README.md，内容写一行 hello from claude dispatch。完成后汇总结果。"
```

查看 tmux 现场：

```bash
tmux -S /root/clawdbot-tmux-sockets/claude-code.sock \
  attach -t demo-claude-readme
```

退出观察但不终止任务：

```text
Ctrl+b，然后按 d
```

## `dispatch-claude-code.sh`

Claude Code 单任务派发入口。课堂里最优先讲这个文件。

必填参数：

- `-p, --prompt TEXT`：必填。要交给 Claude Code 执行的任务提示词。
- `-g, --group, --target ID`：可选。显式覆盖通知目标；不传时按 CDP 映射，无法映射则使用 `dispatch-config.json` 的默认消息通知群。
- `--cdp PORT`：可选。浏览器 CDP 端口；不传时读取 `default_cdp`，显式传入时覆盖默认值，并自动写入 Prompt、环境变量和任务元数据。

可选参数：

- `-n, --name NAME`：任务名，用于生成 `TASK_ID` 和查看日志；不传时默认使用 `--tmux-session` 的值。
- `-s, --session KEY`：回调 session key，给上层系统做会话关联。
- `-w, --workdir DIR` / `--workdir DIR`：可选覆盖 Claude Code 的工作目录；默认 `/root`，普通任务无需传。
- `--agent-teams`：开启 Claude Code Agent Teams。
- `--teammate-mode MODE`：Agent Teams 展示模式，常见值是 `auto`、`in-process`、`tmux`。
- `--permission-mode MODE`：Claude Code 权限模式；默认 `dontAsk`。
- `--allowed-tools TOOLS`：限制 Claude Code 可用工具。
- `--model MODEL`：临时覆盖 Claude Code 模型；不传就用学生自己的默认模型配置。
- `--effort LEVEL`：推理强度，常见值 `low`、`medium`、`high`、`xhigh`、`max`；默认 `xhigh`。
- `--tmux`：使用 tmux 交互模式；当前默认就是 tmux。
- `--no-tmux`：禁用 tmux，改用 headless 模式。
- `--tmux-session NAME`：指定 tmux 会话名；默认 `claude-coding-agent`。
- `--parent-session NAME`：父级 Claude Code tmux 会话名，用于任务完成后回填提醒。

它负责：

- 解析任务、工作目录、模型、权限模式、tmux 会话等参数；
- 生成 `TASK_ID`；
- 写入 `/root/clawd/data/claude-code-results/` 下的任务状态文件；
- 给 prompt 追加任务结束要求；
- 设置 hook 需要的 `CODING_AGENT_*` 环境变量；
- 调用 `claude_code_run.py` 把 Claude Code 启动进 tmux；
- 配置了真实飞书目标时发送启动通知；没有通知系统时不影响 tmux 任务启动。

## `claude_code_run.py`

Claude Code 运行器。它不是课堂主入口，主要被 `dispatch-claude-code.sh` 调用。

必填参数：

- 无。独立运行时也可以不传参数；dispatch 流程会自动传入必要参数。

可选参数：

- `-p, --prompt TEXT`：要发送给 Claude Code 的 prompt。
- `--mode auto|headless|interactive`：运行模式；默认 `auto`。
- `--permission-mode MODE`：透传给 Claude Code 的权限模式。
- `--allowedTools TOOLS`：透传给 Claude Code 的工具白名单。
- `--output-format text|json|stream-json`：headless 输出格式。
- `--json-schema SCHEMA`：`--output-format json` 时使用的 JSON schema。
- `--model MODEL`：模型覆盖；不传时可回退到 `ANTHROPIC_MODEL` 环境变量。
- `--append-system-prompt TEXT`：追加 Claude Code 默认 system prompt。
- `--system-prompt TEXT`：替换 system prompt。
- `--continue`：继续最近一次 Claude Code 会话。
- `--resume SESSION_ID`：恢复指定 Claude Code session。
- `--agent-teams`：开启 Agent Teams。
- `--teammate-mode auto|in-process|tmux`：Agent Teams 展示模式。
- `--claude-bin PATH`：Claude CLI 路径；默认读取 `CLAUDE_CODE_BIN`，再回退到 `/usr/local/bin/claude`。
- `--cwd DIR`：Claude Code 工作目录；默认当前目录。
- `--tmux-session NAME`：interactive 模式的 tmux 会话名；默认 `cc`。
- `--tmux-socket-dir DIR`：tmux socket 目录；默认 `/root/clawdbot-tmux-sockets`。
- `--tmux-socket-name NAME`：tmux socket 文件名；默认 `claude-code.sock`。
- `--interactive-wait-s SECONDS`：interactive 启动后等待 N 秒再打印 tmux 快照。
- `--interactive-send-delay-ms MS`：逐行发送 prompt 的间隔。
- `-- EXTRA_ARGS`：透传给 Claude CLI 的额外参数。

它负责：

- 找到 `claude` CLI；
- 构造 headless 或 tmux interactive 命令；
- 创建 / 复用 / 清理 tmux 会话；
- 把 Claude Code 启动在指定 tmux 会话里；
- 把 API 环境变量、任务环境变量写进 tmux server 和 shell；
- 处理首次进入目录时的 trust folder 提示；
- 等 Claude UI 可交互后，把 prompt 粘贴进输入框并回车；
- 输出 attach / capture-pane 命令，方便人工观察。

## `batch-dispatch.sh`

Claude Code 批量串行派发脚本。它可以读取 `tasks.json`，也可以直接读取一个 Markdown 任务目录，然后按顺序把多个任务逐个派给 Claude Code。

任务输入二选一：

- `--tasks FILE`：读取包含 `tasks` 数组的 JSON 任务文件。
- `--markdown-dir DIR`：读取目录中的 Markdown 任务，文件名去掉 `.md` 后作为任务名，正文作为 Prompt。

可选参数：

- `--markdown-pattern GLOB`：Markdown 任务文件匹配规则；默认 `part*.md`，并按文件名自然排序。
- `--append-prompt TEXT`：在每个任务 Prompt 末尾追加同一段较短要求。
- `--append-prompt-file FILE`：在每个任务 Prompt 末尾追加指定文件的完整内容。Markdown 模式下，未显式传入时自动读取同目录的 `common-requirements.md`。
- `-g, --group, --target ID`：可选覆盖通知目标；不传时由每个 Part 的单任务 dispatch 根据配置自动选择。
- `--cdp PORT`：浏览器 CDP 端口，自动传给每个 Part。
- `-w, --workdir DIR` / `--workdir DIR`：所有子任务共用的工作目录；默认 `/root`，仅需改到其他目录时传。
- `--permission-mode MODE`：传给 Claude dispatch 的权限模式；默认 `acceptEdits`。
- `--tmux-session NAME`：基础 tmux 会话名前缀；每个 part 会变成 `${NAME}-p<序号>`。
- `--wait-timeout SECONDS`：单个 part 最长等待时间；默认 `3600` 秒。
- `--model MODEL`：传给每个 Claude 子任务的模型覆盖值。
- `--effort LEVEL`：传给每个 Claude 子任务的 effort；默认 `xhigh`。
- `--start-index N`：从第 N 个任务开始执行，适合中断后续跑；默认 `1`。
- `--stop-on-error`：某个 part 失败时立即停止；默认继续后面的任务。
- `-h, --help`：打印帮助。

`tasks.json` 格式：

```json
{
  "tasks": [
    {"name": "part-1", "prompt": "第一阶段任务"},
    {"name": "part-2", "prompt": "第二阶段任务"}
  ]
}
```

它负责：

- 读取 `--tasks tasks.json` 或 `--markdown-dir DIR`；
- 合并 `--append-prompt`、`--append-prompt-file` 或默认的 `common-requirements.md`；
- 校验任务列表格式；
- 给每个 part 派一个独立 tmux 会话：`${TMUX_SESSION}-p<序号>`；
- 调用 `dispatch-claude-code.sh` 派发当前 part；
- 从 dispatch 输出里提取 `TASK_ID`；
- 轮询 `tasks/<TASK_ID>.json` 等待任务完成；
- 把上一步结果摘要传给下一步，形成链式上下文；
- Claude Code 偶发卡空输入框时，从 `task-meta.json` 重新注入 prompt；
- 最后输出成功、失败、超时和总耗时。

## `hooks/notify-agi.sh`

Claude Code 完成通知 hook。它配置在 `~/.claude/settings.json` 的 `Stop` / `SessionEnd` 里。

派发任务必填环境变量：

- `CODING_AGENT_TASK_ID`：dispatch 注入。当前任务 ID；没有它时，脚本不会按派发任务处理。

可选输入：

- stdin payload：Claude Code hook 触发时可能传入的 JSON 内容；tmux 场景里主要依赖环境变量和 tmux 会话状态。
- `CLAW_REMOTE_TMUX_SESSION`：手动 Claw Remote / tmux 会话状态更新用。
- `CODING_AGENT_SESSION_DIR`：dispatch 注入。当前任务所在 session 状态目录。
- `CODING_AGENT_TMUX_SESSION`：dispatch 注入。当前任务对应的 tmux 会话名。
- `CODING_AGENT_WORKDIR`：dispatch 注入。当前任务工作目录。
- `COMPLETION_JUDGE_DELAY_SECONDS`：tmux 模式下 Stop 后延迟重抓输出的秒数；默认 `30`。
- `FEISHU_TARGET`：有飞书通知时使用。

它负责：

- 定位当前任务的 `task-meta.json`；
- 抓取 tmux pane 输出；
- 判断任务是完成、等待输入，还是状态不确定；
- 写入 `tasks/<TASK_ID>.json`；
- 写入 `latest.json`；
- 更新 `task-meta.json` 状态；
- 有真实通知配置时发送完成通知。

## Claw Remote 观察

Claude dispatch 固定使用：

```text
/root/clawdbot-tmux-sockets/claude-code.sock
```

只要 Claw Remote 后端读取同一个 socket，就能看到 Claude 任务现场。

```bash
tmux -S /root/clawdbot-tmux-sockets/claude-code.sock list-sessions
```

任务状态文件：

```text
/root/clawd/data/claude-code-results/
```
