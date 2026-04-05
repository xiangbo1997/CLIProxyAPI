# CLIProxyAPI 开发文档

## 1. 项目概览

CLIProxyAPI 是一个多上游、多协议、多凭据形态的 AI 代理服务。它的核心目标不是简单转发 HTTP，而是把不同来源的能力统一抽象成一套可调度、可热更新、可管理的运行时。

从代码结构看，它同时承担了几类职责：

- 对外提供 OpenAI / Claude / Gemini / Codex 兼容 API
- 管理 OAuth 登录、API Key、文件认证与多账号轮询
- 把不同上游协议翻译成客户端期望的请求/响应格式
- 对配置文件和认证文件做热更新
- 提供管理 API、管理面板与 TUI
- 提供 Amp CLI/IDE 的兼容路由与反向代理

主入口文件是 [cmd/server/main.go](/software/CLIProxyAPI/cmd/server/main.go)。

## 2. 启动流程

### 2.1 主启动链路

服务启动的主链路如下：

1. `cmd/server/main.go`
2. 解析 flag、加载 `.env`
3. 根据环境变量选择持久化后端
4. 加载配置并解析 `auth-dir`
5. 注册 token store、access provider、模型更新器
6. 进入登录模式、TUI 模式或服务模式
7. 服务模式下调用 [internal/cmd/run.go](/software/CLIProxyAPI/internal/cmd/run.go) 的 `StartService`
8. `StartService` 通过 [sdk/cliproxy/builder.go](/software/CLIProxyAPI/sdk/cliproxy/builder.go) 构建 `Service`
9. `Service.Run` 启动 API server、watcher、auth auto-refresh、pprof、websocket gateway

### 2.2 可选启动模式

`main` 支持多种分支模式：

- 登录模式：`-login`、`-codex-login`、`-claude-login`、`-qwen-login`、`-iflow-login`、`-antigravity-login`、`-kimi-login`
- TUI 管理模式：`-tui`
- TUI 内嵌服务模式：`-tui -standalone`
- 默认服务模式：直接启动 HTTP API 服务

### 2.3 持久化后端选择

启动时会优先根据环境变量切换持久化后端，而不是永远使用本地文件：

- 文件存储：默认模式，使用 [sdk/auth/filestore.go](/software/CLIProxyAPI/sdk/auth/filestore.go)
- Postgres 存储：`PGSTORE_DSN`
- Git 存储：`GITSTORE_GIT_URL`
- Object Store 存储：`OBJECTSTORE_ENDPOINT`

对应实现位于：

- [internal/store/postgresstore.go](/software/CLIProxyAPI/internal/store/postgresstore.go)
- [internal/store/gitstore.go](/software/CLIProxyAPI/internal/store/gitstore.go)
- [internal/store/objectstore.go](/software/CLIProxyAPI/internal/store/objectstore.go)

这些后端都会把配置或认证数据同步到本地工作目录镜像，保证现有文件型流程仍可复用。

开发时有一个很常见的误判：

- 仓库里已经存在 `auths/*.json`
- 但 `config.yaml` 的 `auth-dir` 仍然指向 `~/.cli-proxy-api`

这种情况下服务会正常启动，但实际加载到的 auth 数量可能是 0。排查时先看启动日志里的这类信息：

```text
server clients and configuration updated: 0 clients (0 auth entries + ...)
```

如果 auth 数量不对，先核对“配置里的 `auth-dir`”和“凭据真实存放目录”是否一致，再看 executor 或 handler。

## 3. 核心架构

### 3.1 API Server 层

[internal/api/server.go](/software/CLIProxyAPI/internal/api/server.go) 负责：

- 创建 Gin engine
- 注册日志、中间件、CORS
- 注册 `/v1`、`/v1beta`、管理 API、OAuth callback、Amp module
- 根据配置决定是否启用 TLS、keep-alive、management routes
- 在热更新时调用 `UpdateClients`

主路由：

- `/v1/models`
- `/v1/chat/completions`
- `/v1/completions`
- `/v1/messages`
- `/v1/messages/count_tokens`
- `/v1/responses`
- `/v1/responses/compact`
- `/v1beta/models`
- `/v1beta/models/*action`
- `/v0/management/*`
- `/api/provider/*`
- `/anthropic/callback`、`/codex/callback`、`/google/callback` 等 OAuth 回调

### 3.2 Handler 层

[sdk/api/handlers](/software/CLIProxyAPI/sdk/api/handlers) 是协议入口层，负责：

- 解析客户端协议
- 生成标准错误响应
- 处理 stream / non-stream 差异
- 透传或过滤头
- 组装执行上下文与幂等 metadata
- 把请求交给 `sdk/cliproxy/auth.Manager`

这层不是最终执行器，真正的 provider 选择、重试、刷新和账号状态管理在 auth conductor。

### 3.3 Auth Conductor

[sdk/cliproxy/auth/conductor.go](/software/CLIProxyAPI/sdk/cliproxy/auth/conductor.go) 的 `Manager` 是运行时核心之一，负责：

- 管理 auth 列表和状态
- 注册 provider executor
- 根据 selector 选择凭据
- 执行请求与流式请求
- 处理 refresh、cooldown、失败回退
- 维护 OAuth model alias / API key model alias
- 驱动调度器与自动刷新

选择策略来自配置项 `routing.strategy`，当前内置：

- `round-robin`
- `fill-first`

### 3.4 Executor 层

[internal/runtime/executor](/software/CLIProxyAPI/internal/runtime/executor) 是各 provider 的实际执行层。这里封装了：

- OpenAI Codex
- Claude
- Gemini
- Gemini CLI
- Qwen
- Kimi
- iFlow
- Antigravity
- OpenAI-compatible 上游

这层负责：

- 构造上游请求
- 处理 provider 特定头、身份信息与错误
- 处理 stream / websocket / token counting
- 将结果交给 translator 或直接回传

### 3.5 Translator 层

[internal/translator](/software/CLIProxyAPI/internal/translator) 负责跨协议翻译，例如：

- OpenAI chat-completions
- OpenAI responses
- Claude
- Gemini
- Gemini CLI
- Codex
- Antigravity

如果请求入口协议和上游 provider 协议不一致，通常会经过这里。

### 3.6 Watcher 与热更新

[internal/watcher/watcher.go](/software/CLIProxyAPI/internal/watcher/watcher.go) 监控：

- 配置文件
- `auth-dir` 下的认证文件
- 运行时 auth 更新队列

它会触发两类变更：

- 配置热更新：刷新 selector、重试策略、pprof、server clients、OAuth alias
- auth 增量更新：新增、修改、删除指定 auth，并重新绑定 executor / 模型注册

因此改动配置或 auth 管理逻辑时，不能只验证冷启动路径，还要验证热更新路径。

## 4. 配置模型

核心配置结构在 [internal/config/config.go](/software/CLIProxyAPI/internal/config/config.go)，样例文件在 [config.example.yaml](/software/CLIProxyAPI/config.example.yaml)。

常用顶层配置：

- `host`
- `port`
- `tls`
- `remote-management`
- `auth-dir`
- `api-keys`
- `debug`
- `pprof`
- `commercial-mode`
- `logging-to-file`
- `usage-statistics-enabled`
- `proxy-url`
- `force-model-prefix`
- `passthrough-headers`
- `request-retry`
- `max-retry-credentials`
- `max-retry-interval`
- `quota-exceeded`
- `routing`
- `ws-auth`
- `nonstream-keepalive-interval`
- `streaming`

provider 相关配置：

- `gemini-api-key`
- `codex-api-key`
- `claude-api-key`
- `openai-compatibility`
- `vertex-api-key`
- `ampcode`
- `oauth-excluded-models`
- `oauth-model-alias`
- `payload`

### 4.1 配置的几个关键事实

- 管理 API 只有在 `remote-management.secret-key` 或环境变量 `MANAGEMENT_PASSWORD` 存在时才会注册。
- `remote-management.secret-key` 可为明文或 bcrypt hash。
- `auth-dir` 会在启动时解析 `~` 并转换为绝对路径。
- `ws-auth` 只控制 WebSocket API 是否需要认证，不影响普通 HTTP API。
- `routing.strategy` 会在热更新时即时替换 selector。

## 5. 路由与协议层

### 5.1 统一业务接口

[internal/api/server.go](/software/CLIProxyAPI/internal/api/server.go) 注册的核心业务接口：

- `/v1/*`：OpenAI / Claude Code 风格
- `/v1beta/*`：Gemini 风格

`/v1/models` 是统一入口，会根据 `User-Agent` 决定用 Claude models 还是 OpenAI models handler。

### 5.2 管理接口

管理接口位于 `/v0/management/*`，功能非常多，主要分为：

- 配置读取与写回
- API keys / provider 配置维护
- auth 文件上传、下载、清理、检查
- usage 统计导入导出
- logs / request logs 查看
- OAuth 发起与回调状态查询
- Amp 配置管理

管理中间件实现见 [internal/api/handlers/management/handler.go](/software/CLIProxyAPI/internal/api/handlers/management/handler.go)。

安全点：

- 所有管理请求都要求 management key
- 远程访问默认关闭
- 非本地访问有失败次数统计和封禁窗口
- 环境变量 `MANAGEMENT_PASSWORD` 会强制允许远程管理

### 5.3 Amp 模块

Amp 集成模块位于：

- [internal/api/modules/amp/amp.go](/software/CLIProxyAPI/internal/api/modules/amp/amp.go)
- [internal/api/modules/amp/routes.go](/software/CLIProxyAPI/internal/api/modules/amp/routes.go)

它提供两类能力：

- `/api/provider/{provider}/...` 本地兼容路由
- `/api/*`、`/auth/*`、`/threads*` 等到 Amp upstream 的代理

同时支持：

- model mapping
- localhost-only 限制
- upstream 热更新
- per-client upstream API key 映射

## 6. 认证与凭据

### 6.1 凭据来源

系统里并存三类凭据来源：

- OAuth / 文件型 auth
- 配置文件中的 API key
- 运行时 websocket provider auth

OAuth / 文件型 auth 最终会进入 core auth manager，形成统一的 `Auth` 运行时对象。

### 6.2 Token Store 抽象

`sdk/auth` 暴露统一 token store 接口，启动时用 `sdkAuth.RegisterTokenStore(...)` 注册。

当前实现：

- 文件型 store
- Git store
- Postgres store
- Object store

这意味着任何“保存 auth 文件”的逻辑都不能假设直接写本地磁盘就结束了，可能还需要同步远端存储。

### 6.3 登录流程

登录入口主要在 [internal/cmd](/software/CLIProxyAPI/internal/cmd) 和 [internal/auth](/software/CLIProxyAPI/internal/auth)。

CLI flag 负责触发：

- Gemini
- Codex OAuth / device login
- Claude
- Qwen
- iFlow
- Antigravity
- Kimi
- Vertex 导入

OAuth callback 则由主服务上的固定 HTTP 路由接收。

## 7. 模型目录与注册

模型目录来源有两层：

- 内置静态定义：例如 [internal/registry/models/models.json](/software/CLIProxyAPI/internal/registry/models/models.json)
- 运行时远程更新：`registry.StartModelsUpdater(...)`

运行时模型注册同时受这些因素影响：

- provider 可用性
- auth 状态
- alias / excluded-models
- OAuth model alias
- Amp model mappings

Service 在模型目录变化后会触发受影响 provider 的模型重新注册。

## 8. TUI 与管理面板

### 8.1 TUI

TUI 代码位于 [internal/tui](/software/CLIProxyAPI/internal/tui)。

两种运行方式：

- 纯客户端模式：要求服务已启动
- `-tui -standalone`：先启动内嵌服务，再连接本地管理 API

### 8.2 Management Control Panel

管理面板资源由 [internal/managementasset/updater.go](/software/CLIProxyAPI/internal/managementasset/updater.go) 管理，默认会自动下载和更新前端静态页，通过 `/management.html` 提供。

## 9. 开发建议

### 9.1 阅读代码的建议顺序

建议按下面顺序入手：

1. [cmd/server/main.go](/software/CLIProxyAPI/cmd/server/main.go)
2. [sdk/cliproxy/builder.go](/software/CLIProxyAPI/sdk/cliproxy/builder.go)
3. [sdk/cliproxy/service.go](/software/CLIProxyAPI/sdk/cliproxy/service.go)
4. [internal/api/server.go](/software/CLIProxyAPI/internal/api/server.go)
5. [sdk/cliproxy/auth/conductor.go](/software/CLIProxyAPI/sdk/cliproxy/auth/conductor.go)
6. 某个具体 provider 的 executor 与 translator

### 9.2 修改前要先确认的点

- 功能是配置期行为还是请求期行为
- 是否需要支持热更新
- 是否涉及多种 token store
- 是否会影响管理 API、TUI 或 Amp 兼容层
- 是否涉及流式与非流式两条路径
- 是否需要同步更新测试

### 9.3 测试命令

常用命令：

```bash
go test ./...
go test ./sdk/cliproxy/...
go test ./internal/api/...
go test ./internal/runtime/executor/...
```

这个仓库测试覆盖面较广，很多行为已经有单测，优先沿现有测试风格补。

## 10. 扩展入口

### 10.1 新增 provider

通常需要同时落几个层次：

1. auth / credential 表达
2. executor
3. translator
4. model registry 映射
5. handler 路由接入或协议适配
6. 配置模型
7. 管理 API 支持

### 10.2 新增可选路由模块

可以参考 [internal/api/modules/modules.go](/software/CLIProxyAPI/internal/api/modules/modules.go) 的 `RouteModuleV2` 接口，把功能做成可插拔模块，而不是直接把逻辑塞进 `server.go`。

## 11. 当前仓库注意事项

- 当前工作区不是干净状态，已有用户修改：[internal/runtime/executor/codex_executor.go](/software/CLIProxyAPI/internal/runtime/executor/codex_executor.go)
- 根目录下原有 `.codex` 是一个空文件，当前文档没有依赖它
- 新 agent 进入仓库时，优先读本文件和部署文档，不要只依赖 README
