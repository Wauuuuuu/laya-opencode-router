# Laya × OpenCode Router

一个适用于 macOS 和 OpenCode V2 的自动模型路由插件。明确简单或复杂的请求直接按规则分配；其他请求才调用本机 Laya。Laya 分类失败时使用备用分类模型。`/laya` 打开控制窗口，`!manual` 保留当前手选模型并从提示词中移除该指令。

## 功能

- 简单、常规、复杂任务分别选择模型；开关和模型 ID 保存在 `settings.json`。
- Laya HTTP 服务按需启动，空闲 90 秒后退出。首次模型加载或下载最多等待 180 秒，已预热推理最多等待 30 秒。
- 可选接入本地 MLX 网关。选中本地模型前等待网关启动模型；切回云模型后延迟请求关闭。网关也会在没有活动请求时自动卸载模型。
- 文件名检索默认只向回答模型提供文件名；用户明确询问位置时才提供以 `~` 开头的主目录相对路径。

## 要求

- macOS、OpenCode V2、Xcode Command Line Tools、Python 3.10 或更新版本。
- 在 OpenCode 中已经配置需要使用的模型。安装脚本安装 `laya[serve]==0.3.20`；Laya 权重由其发布者提供，不包含在仓库中。
- 可选的本地执行模型需要自行安装 MLX 运行环境和模型文件；本仓库不分发 Qwen 或其他模型权重。

## 安装

```sh
git clone https://github.com/Wauuuuuu/laya-opencode-router.git
cd laya-opencode-router
sh install.sh
```

安装脚本将插件链接到 `~/.config/opencode/plugins/laya-router`，在 `~/.config/laya-opencode-router` 创建配置、虚拟环境和控制窗口，并写入 Laya 的 LaunchAgent。它不会覆盖已有的 `settings.json` 或其他插件路径。自定义 OpenCode 配置目录可设置 `OPENCODE_CONFIG_DIR`。安装后填写 `~/.config/laya-opencode-router/settings.json` 中可用的模型 ID，重启 OpenCode 后台服务，输入 `/laya` 开启路由。

**从旧版本升级：** 路由开关现在只由 `settings.json` 的 `enabled` 字段控制。旧版 OpenCode 配置中的 `laya` MCP 服务可删除；新版本不使用它，也不调用 OpenCode 的 experimental MCP 接口。安装脚本保留现有 `settings.json`，请检查其 `enabled` 值。

## 可选：本地 MLX 模型

仓库提供 `service/local_model_gateway.py`。网关只监听本机，按需启动 `mlx_vlm.server`（可在配置中改为其他兼容的服务器模块），代理 OpenAI 兼容请求，并在空闲后关闭它启动的模型进程。网关本身必须先运行；模型进程由网关按需管理。

1. 将 `local-model.example.json` 复制到 `~/.config/laya-opencode-router/local-model.json`，填写本机 Python、模型文件路径和端口。`mlx_python` 所在环境必须已安装所选服务器模块。
2. 运行 `python3 service/local_model_gateway.py`，或用你自己的进程管理器保持网关运行。不要在已有网关使用相同端口时再启动第二份。
3. 在 OpenCode 配置本地供应商，`baseURL` 指向 `http://127.0.0.1:8787/v1`，模型 ID 与 `local-model.json` 的 `model_id` 相同。
4. 在路由 `settings.json` 添加以下配置，`providerID` 应与 OpenCode 本地供应商 ID 相同，并在控制窗口选用该供应商的模型：

```json
{
  "localModel": {
    "providerID": "local-mlx",
    "gatewayURL": "http://127.0.0.1:8787",
    "startupTimeoutMs": 300000,
    "stopGraceMs": 45000
  }
}
```

如果本地模型启动失败，路由器会改用已配置的最终处理模型。网关在有活动请求时拒绝关闭，之后按自己的空闲计时器关闭模型。网关只管理它自己启动的进程，不会终止其他应用启动的模型服务。

## 文件

| 路径 | 用途 |
| --- | --- |
| `plugin/index.js` | OpenCode 路由和本地网关控制 |
| `service/idle_server.py` | Laya HTTP 服务与空闲退出 |
| `service/local_model_gateway.py` | 可选 MLX 模型生命周期网关 |
| `control/Control.swift` | 原生 macOS 控制窗口 |
| `settings.example.json` | 路由配置示例 |
| `local-model.example.json` | 本地 MLX 网关配置示例 |

运行时配置、模型权重、日志、数据库和密钥不在仓库中。本项目不由 OpenCode、Laya 或 MLX 官方维护。

## License

MIT。Laya 和本地模型及其权重遵循各自发布者的许可。
