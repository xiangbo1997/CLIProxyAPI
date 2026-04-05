# CLIProxyAPI Agent Memory

本文件是仓库级项目记忆，供后续 agent 快速建立上下文。详细说明见 [docs/development.md](/software/CLIProxyAPI/docs/development.md) 和 [docs/deployment.md](/software/CLIProxyAPI/docs/deployment.md)。

## 项目定位

CLIProxyAPI 是一个 Go 实现的多协议 AI 代理服务，目标是把多种上游能力统一暴露成 CLI 常用的 OpenAI / Claude / Gemini / Codex 兼容接口，同时提供：

- OAuth / API Key / 文件凭据混合接入
- 多账号调度与失败重试
- 模型别名、模型池与协议翻译
- 管理 API、TUI、Amp 兼容路由
- 配置与认证文件热重载

主入口是 [cmd/server/main.go](/software/CLIProxyAPI/cmd/server/main.go)。

## 运行链路

启动主链路：

`main -> config/store 初始化 -> sdk/cliproxy.Builder -> sdk/cliproxy.Service.Run -> internal/api.Server`

请求主链路：

`Gin Route -> sdk/api/handlers -> sdk/cliproxy/auth.Manager -> provider executor -> translator / upstream`

热更新链路：

`internal/watcher.Watcher -> config reload / auth update -> Service.reloadCallback / core auth update -> Server.UpdateClients`

## 关键目录

- [cmd/server](/software/CLIProxyAPI/cmd/server): 可执行程序入口
- [internal/cmd](/software/CLIProxyAPI/internal/cmd): 登录流程、服务启动封装
- [internal/api](/software/CLIProxyAPI/internal/api): Gin server、middleware、management handlers、Amp module
- [sdk/cliproxy](/software/CLIProxyAPI/sdk/cliproxy): 服务构建、生命周期、watcher 接线、auth conductor
- [sdk/api/handlers](/software/CLIProxyAPI/sdk/api/handlers): OpenAI / Claude / Gemini 兼容 handler
- [internal/runtime/executor](/software/CLIProxyAPI/internal/runtime/executor): 各 provider 执行器
- [internal/translator](/software/CLIProxyAPI/internal/translator): 协议格式翻译
- [sdk/auth](/software/CLIProxyAPI/sdk/auth): 认证器与 token store 抽象
- [internal/store](/software/CLIProxyAPI/internal/store): Postgres / Git / Object Store 持久化
- [internal/watcher](/software/CLIProxyAPI/internal/watcher): 配置与 auth 文件热重载
- [internal/tui](/software/CLIProxyAPI/internal/tui): 终端管理 UI
- [internal/registry](/software/CLIProxyAPI/internal/registry): 模型目录与更新器

## 核心事实

- 默认配置文件是工作目录下的 `config.yaml`，样例文件是 [config.example.yaml](/software/CLIProxyAPI/config.example.yaml)。
- 默认认证目录来自配置项 `auth-dir`，启动时会被解析成绝对路径。
- 管理 API 路由前缀是 `/v0/management`，只有配置了管理密钥才会注册。
- 主业务接口在 `/v1` 和 `/v1beta`。
- Amp 兼容路由挂在 `/api/provider/...` 和若干 `/api/*`、根路径 `/auth/*`、`/threads*`。
- WebSocket provider 路由默认是 `/v1/ws`，OpenAI Responses WebSocket 在 `/v1/responses` GET。
- Service 会启动 watcher，并对配置文件和 auth 文件变化做增量更新。
- 可选持久化后端不是只支持文件系统，还支持 Postgres、Git、Object Store，代码在启动时按环境变量决定。

## 当前部署记忆

- 当前机器上正在运行的 CLIProxyAPI 是 Docker 部署，不是本地 `go run`。
- 当前运行中的容器名是 `cli-proxy-api`。
- 对外 `8317` 端口当前由 `docker-proxy` 监听，指向该容器。
- 后续默认优先按 Docker 方式排查和操作：
  `docker compose ps`
  `docker compose logs -f cli-proxy-api`
  `docker compose up -d --force-recreate`
- 当前仓库本地开发配置 [config.yaml](/software/CLIProxyAPI/config.yaml) 使用 `auth-dir: "./auths"`。
- 当前仓库内实际认证文件目录是 [auths](/software/CLIProxyAPI/auths)。
- 如果服务日志出现 `0 auth entries`，优先检查：
  `config.yaml` 的 `auth-dir`
  容器挂载是否覆盖了 `/CLIProxyAPI/auths` 或 `/root/.cli-proxy-api`
  `auths` 目录下是否存在有效 `.json` 凭据文件
- 当前 [docker-compose.yml](/software/CLIProxyAPI/docker-compose.yml) 已同时挂载：
  `./auths -> /root/.cli-proxy-api`
  `./auths -> /CLIProxyAPI/auths`
  这样兼容默认 home 目录方案和仓库相对路径方案。

## 修改代码时要注意

- 这是脏工作区，当前已有未提交修改：[internal/runtime/executor/codex_executor.go](/software/CLIProxyAPI/internal/runtime/executor/codex_executor.go)。
- 不要假设只有文件存储。涉及 auth/config 持久化时，要看 `sdkAuth.GetTokenStore()` 实际返回什么。
- 不要只看 Gin 路由决定功能归属。很多行为真正落在 `sdk/cliproxy/auth.Manager` 和 executor。
- 修改模型路由、别名、provider 选择时，要同时考虑：
  `config`、`registry`、`auth conductor selector`、`executor binding`、`watcher hot reload`
- 修改管理接口时，要考虑 `allow-remote`、环境变量 `MANAGEMENT_PASSWORD`、本地密码、限流封禁逻辑。
- 修改 websocket 或 Responses 流式逻辑时，要同时看：
  `internal/api/server.go`、`sdk/api/handlers/openai/*`、`internal/wsrelay/*`

## 常用开发命令

- 本地运行：`go run ./cmd/server`
- 指定配置：`go run ./cmd/server -config ./config.yaml`
- TUI 模式：`go run ./cmd/server -tui`
- TUI 内嵌服务：`go run ./cmd/server -tui -standalone`
- Docker Compose：`docker compose up -d`
- 测试：`go test ./...`

## 文档入口

- 开发文档：[docs/development.md](/software/CLIProxyAPI/docs/development.md)
- 部署文档：[docs/deployment.md](/software/CLIProxyAPI/docs/deployment.md)
