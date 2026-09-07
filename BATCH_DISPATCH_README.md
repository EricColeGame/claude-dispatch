# 批量串行派发 Claude Code 任务

## 功能说明

`batch-dispatch.sh` 脚本用于批量串行派发多个 Claude Code 任务，每个任务执行完成后再发送下一个任务。

## 使用方法

### 基本用法

```bash
/home/ubuntu/.openclaw/skills/claude-dispatch/batch-dispatch.sh \
  --tasks tasks.json \
  -g "oc_xxxx_notification" \
  -w "/home/ubuntu/Documents/dispatch-demo/claude-batch"
```

### 完整参数

```bash
batch-dispatch.sh \
  --tasks tasks.json \           # JSON 文件路径（必需）
  -g "oc_xxxx_notification" \                     # 飞书通知目标（可选）
  -w "/path/to/workdir" \        # 可选覆盖工作目录（默认: /root）
  --permission-mode acceptEdits \ # 权限模式（默认: acceptEdits）
  --tmux-session "session-name" \ # tmux 会话名（默认: claude-coding-agent）
  --wait-timeout 600 \            # 单个任务超时时间（秒，默认: 600）
  --stop-on-error                 # 任务失败时停止（默认: 继续）
```

## JSON 文件格式

```json
{
  "tasks": [
    {
      "name": "task-1",
      "prompt": "第一个任务的 prompt"
    },
    {
      "name": "task-2",
      "prompt": "第二个任务的 prompt"
    },
    {
      "name": "task-3",
      "prompt": "第三个任务的 prompt"
    }
  ]
}
```

**字段说明**：
- `name`: 任务名称（用于标识和日志）
- `prompt`: 任务的 prompt 内容

## 工作原理

1. **串行执行**：每个任务按顺序执行，前一个任务完成后才开始下一个
2. **Hook 检测**：通过监听 `/home/ubuntu/clawd/data/claude-code-results/latest.json` 文件来检测任务完成
3. **超时保护**：每个任务有独立的超时时间（默认 600 秒）
4. **失败处理**：
   - 默认：任务失败后继续执行下一个任务
   - `--stop-on-error`：任务失败后停止执行

## 任务完成检测

脚本通过以下方式检测任务完成：

1. 监听 Hook 写入的 `latest.json` 文件
2. 检查 `task_name` 是否匹配当前任务
3. 检查 `status` 是否为 `done`
4. 验证时间戳（确保不是旧结果）

## 示例

### 示例 1: 基本测试

创建任务文件 `/home/ubuntu/Documents/dispatch-demo/claude-batch/tasks.json`：

```json
{
  "tasks": [
    {
      "name": "test-task-1",
      "prompt": "请在当前目录创建文件 batch-test-1.txt，内容为：'批量任务 1'"
    },
    {
      "name": "test-task-2",
      "prompt": "请在当前目录创建文件 batch-test-2.txt，内容为：'批量任务 2'"
    }
  ]
}
```

执行：

```bash
batch-dispatch.sh \
  --tasks /home/ubuntu/Documents/dispatch-demo/claude-batch/tasks.json \
  -g "oc_xxxx_notification" \
  -w "/home/ubuntu/Documents/dispatch-demo/claude-batch"
```

验证结果：

```bash
ls -lt /home/ubuntu/Documents/dispatch-demo/claude-batch/batch-test-*.txt
cat /home/ubuntu/Documents/dispatch-demo/claude-batch/batch-test-1.txt
cat /home/ubuntu/Documents/dispatch-demo/claude-batch/batch-test-2.txt
```

### 示例 2: 代码开发任务

```json
{
  "tasks": [
    {
      "name": "setup-project",
      "prompt": "创建一个新的 Node.js 项目，包含 package.json 和基本的目录结构"
    },
    {
      "name": "add-express",
      "prompt": "添加 Express 框架，创建一个简单的 HTTP 服务器"
    },
    {
      "name": "add-routes",
      "prompt": "添加 /api/health 和 /api/users 两个路由"
    },
    {
      "name": "add-tests",
      "prompt": "为路由添加单元测试"
    }
  ]
}
```

### 示例 3: 失败时停止

```bash
batch-dispatch.sh \
  --tasks tasks.json \
  --stop-on-error \
  -g "oc_xxxx_notification"
```

## 输出示例

```
🚀 批量串行派发 Claude Code 任务
   任务文件: /home/ubuntu/Documents/dispatch-demo/claude-batch/tasks.json
   工作目录: /home/ubuntu/Documents/dispatch-demo/claude-batch
   飞书通知: oc_xxxx_notification
   Tmux 会话: claude-coding-agent

📊 共 3 个任务

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 任务 [1/3]: test-task-1
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔄 Sending task to existing Claude Code session: claude-coding-agent
   Task: test-task-1

✅ Task sent to Claude Code session: claude-coding-agent
⏳ 等待任务完成: test-task-1 (超时: 600s)
   仍在等待... (10s / 600s)
✅ 任务完成: test-task-1 (耗时: 15s)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 任务 [2/3]: test-task-2
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📊 执行总结
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   总任务数: 3
   成功: 3
   失败: 0
   总耗时: 45s
```

## 注意事项

1. **串行执行**：任务按顺序执行，适合有依赖关系的任务
2. **共享上下文**：所有任务在同一个 tmux 会话中执行，共享上下文
3. **超时设置**：根据任务复杂度调整 `--wait-timeout` 参数
4. **飞书通知**：每个任务完成后会发送飞书通知（如果配置了 `-g` 参数）
5. **工作目录**：所有任务使用相同的工作目录

## 故障排查

### 任务超时

如果任务经常超时，可以：
- 增加 `--wait-timeout` 参数
- 检查 Hook 是否正常工作：`tail -f /home/ubuntu/clawd/data/claude-code-results/hook.log`
- 检查 `latest.json` 是否更新：`cat /home/ubuntu/clawd/data/claude-code-results/latest.json`

### 任务未执行

检查：
- tmux 会话是否存在：`tmux -S /home/ubuntu/clawdbot-tmux-sockets/claude-code.sock ls`
- Claude Code 是否正常运行：`ps aux | grep claude`
- 工作目录是否存在：`ls -la /home/ubuntu/Documents/dispatch-demo/claude-batch`

### Hook 未触发

检查：
- Hook 日志：`tail -50 /home/ubuntu/clawd/data/claude-code-results/hook.log`
- Hook 配置：`cat ~/.claude/hooks.json`
- 权限问题：`ls -la /home/ubuntu/clawd/data/claude-code-results/`

## 相关文件

- 脚本位置：`/home/ubuntu/.openclaw/skills/claude-dispatch/batch-dispatch.sh`
- 依赖脚本：`/home/ubuntu/.openclaw/skills/claude-dispatch/dispatch-claude-code.sh`
- Hook 脚本：`/home/ubuntu/.openclaw/skills/claude-dispatch/hooks/notify-agi.sh`
- 结果目录：`/home/ubuntu/clawd/data/claude-code-results/`
