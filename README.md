# Laya × OpenCode Router

一个适用于 macOS 的 OpenCode 自动模型路由插件。它用本机 [Laya](https://huggingface.co/convaiinnovations/laya) 判断任务复杂度，再让 OpenCode 为当前会话选择模型。Laya 服务按需启动，空闲 90 秒后退出；分类失败时可由备用模型接手。`/laya` 打开控制窗口，`!manual` 可让单条消息保留手动选择的模型。

An OpenCode model router for macOS. A local Laya classifier selects a model tier before each prompt. It includes a small control app, fallback classification, and filename lookup.

## 功能

- 按简单、常规、复杂任务分配模型；每档模型在控制窗口中选择。
- Laya 无法分类时使用备用分类模型；再次失败则使用最终处理模型。
- 对只查找单个本地文件名或路径的请求，先用 Spotlight 找候选路径，再交给指定模型回答。这是文件名检索，不读取文件内容，也不建立向量索引。
- 与当前工作区的 Laya MCP 开关同步；关闭 MCP 后停止自动路由。

## 要求

- macOS、OpenCode Desktop，以及可运行 `swiftc` 的 Xcode Command Line Tools。
- Python 3.10 或更新版本。安装脚本会安装 `laya==0.3.20` 和 `uvicorn==0.54.0`。
- 在 OpenCode 中已配置所选模型，并为工作区配置名为 `laya` 的 MCP 服务。模型权重由 Laya 自行获取，**不包含在本仓库中**。

## 安装

```sh
git clone https://github.com/Wauuuuuu/laya-opencode-router.git
cd laya-opencode-router
./install.sh
```

安装脚本将插件链接到 `~/.config/opencode/plugins/laya-router`，在 `~/.config/laya-opencode-router` 下创建配置、虚拟环境和控制窗口，并在 `~/Library/LaunchAgents` 写入按需启动的服务定义。不会覆盖已有配置或已有插件路径。如果 OpenCode 使用自定义配置目录，可设置 `OPENCODE_CONFIG_DIR` 后再运行安装脚本。安装后在 `~/.config/laya-opencode-router/settings.json` 中填写你可用的模型 ID，重启 OpenCode 后台服务，输入 `/laya` 选择各档模型。

在 OpenCode 全局配置的 `mcp.servers` 中添加名为 `laya` 的本地服务，命令指向 `~/.config/laya-opencode-router/.venv/bin/laya-mcp-server` 的**展开后绝对路径**，并将 `HF_HOME` 指向 `~/.config/laya-opencode-router/hf-cache` 的展开后绝对路径。例如：

```json
{
  "mcp": {
    "servers": {
      "laya": {
        "type": "local",
        "command": ["/Users/YOU/.config/laya-opencode-router/.venv/bin/laya-mcp-server"],
        "environment": {
          "HF_HOME": "/Users/YOU/.config/laya-opencode-router/hf-cache",
          "LAYA_DEVICE": "mps",
          "LAYA_PRELOAD": "0"
        }
      }
    }
  }
}
```

插件以当前工作区的 Laya MCP 开关状态决定是否自动路由。控制窗口依赖 OpenCode Desktop 的模型 API；模型显示状态读取取决于 Desktop 本地数据库格式，读取失败时仍可使用完整模型目录。设置 `OPENCODE_DRAFTS_DB` 可覆盖数据库路径。

## 配置与文件

| 路径 | 用途 |
| --- | --- |
| `plugin/index.js` | OpenCode 插件源码 |
| `service/idle_server.py` | Laya HTTP 服务与空闲退出 |
| `control/Control.swift` | 原生 macOS 控制窗口源码 |
| `settings.example.json` | 不含个人信息的模型配置示例 |

运行时文件、模型缓存、日志、数据库和密钥均不在仓库中。默认服务端口是 `127.0.0.1:8766`。此项目不由 OpenCode 或 Laya 官方维护。

## License

MIT。Laya 模型及其权重遵循各自发布者的许可，本仓库不分发模型权重。
