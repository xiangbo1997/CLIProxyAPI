# CLIProxyAPI 部署文档

## 1. 部署概览

CLIProxyAPI 可以用三种典型方式部署：

- 直接本地运行 Go 程序
- Docker 单容器 / Docker Compose
- 使用远端持久化后端运行
  包括 Postgres、Git、Object Store

默认服务端口来自配置项 `port`，样例配置默认是 `8317`，配置文件样例见 [config.example.yaml](/software/CLIProxyAPI/config.example.yaml)。

## 2. 运行前准备

最少需要准备：

- 一个 `config.yaml`
- 一个认证目录 `auth-dir`
- 至少一种可用凭据
  包括 API key 或 OAuth 登录产物

可选准备：

- 管理密钥
- TLS 证书
- 代理地址
- 远端持久化后端环境变量

## 3. 配置文件

默认行为：

- 如果显式传 `-config`，就使用指定路径
- 否则默认读取当前工作目录下的 `config.yaml`

初次部署建议：

```bash
cp config.example.yaml config.yaml
mkdir -p auths logs
```

如果你打算把认证文件直接放在仓库目录内，建议把 `config.yaml` 里的 `auth-dir` 明确改成：

```yaml
auth-dir: "./auths"
```

不要让“配置里的 `auth-dir`”和“你实际保存 OAuth/API Key 文件的位置”分离。最常见的故障就是服务能启动，但启动日志里显示 `0 auth entries`。

配置中最关键的部署项：

- `host`
- `port`
- `tls`
- `remote-management`
- `auth-dir`
- `api-keys`
- `logging-to-file`
- `pprof`
- `proxy-url`
- `request-retry`
- `routing`
- `ws-auth`

## 4. 本地直接运行

### 4.1 启动

```bash
go run ./cmd/server
```

指定配置文件：

```bash
go run ./cmd/server -config ./config.yaml
```

启动后先看一眼日志里的 auth 计数，例如：

```text
server clients and configuration updated: 1 clients (1 auth entries + ...)
```

如果这里是 `0 auth entries`，优先检查：

- `config.yaml` 的 `auth-dir` 是否指向真实目录
- 认证文件是否真的在那个目录下
- 认证文件是否是 `.json`

### 4.2 常用登录命令

Gemini:

```bash
go run ./cmd/server -login
```

Codex OAuth:

```bash
go run ./cmd/server -codex-login
```

Claude OAuth:

```bash
go run ./cmd/server -claude-login
```

其他 provider 也通过同样的 flag 体系进入登录流程，定义见 [cmd/server/main.go](/software/CLIProxyAPI/cmd/server/main.go)。

### 4.3 TUI

如果只想使用管理界面：

```bash
go run ./cmd/server -tui
```

如果想让 TUI 自己带起内嵌服务：

```bash
go run ./cmd/server -tui -standalone
```

## 5. Docker 部署

### 5.1 Dockerfile 行为

[Dockerfile](/software/CLIProxyAPI/Dockerfile) 是双阶段构建：

- 第一阶段使用 `golang:1.26-alpine` 编译二进制
- 第二阶段使用 `alpine:3.22.0`

镜像内关键路径：

- 程序：`/CLIProxyAPI/CLIProxyAPI`
- 配置样例：`/CLIProxyAPI/config.example.yaml`
- 工作目录：`/CLIProxyAPI`

默认暴露：

- `8317`

### 5.2 Docker Compose

仓库自带 Compose 文件 [docker-compose.yml](/software/CLIProxyAPI/docker-compose.yml)。

默认映射：

- `8317:8317`
- `8085:8085`
- `1455:1455`
- `54545:54545`
- `51121:51121`
- `11451:11451`

默认挂载：

- `./config.yaml -> /CLIProxyAPI/config.yaml`
- `./auths -> /root/.cli-proxy-api`
- `./auths -> /CLIProxyAPI/auths`
- `./logs -> /CLIProxyAPI/logs`

启动：

```bash
docker compose up -d
```

查看日志：

```bash
docker compose logs -f
```

如果容器里配置使用的是仓库相对路径，例如：

```yaml
auth-dir: "./auths"
```

那就必须确保容器内 `/CLIProxyAPI/auths` 也能看到同一批文件。当前仓库的默认 compose 已经同时挂载了：

- `/root/.cli-proxy-api`
- `/CLIProxyAPI/auths`

这样无论你使用默认 home 目录方案，还是仓库内 `./auths` 方案，都不会出现“本地能用、容器读不到 auth”的错配。

### 5.3 脚本化构建

[docker-build.sh](/software/CLIProxyAPI/docker-build.sh) 提供两种模式：

- 拉取预构建镜像直接启动
- 本地构建镜像后启动

它还支持 `--with-usage`，在重建容器前后导出并回灌 usage 数据。

## 6. 管理 API 与安全建议

### 6.1 管理 API 启用条件

管理 API 前缀是 `/v0/management`。

只有以下任一条件成立时才会注册：

- `remote-management.secret-key` 已配置
- 环境变量 `MANAGEMENT_PASSWORD` 已配置

### 6.2 推荐安全配置

公网部署时建议：

- `host` 绑定内网地址或 `127.0.0.1`，再通过反向代理暴露
- 设置强随机管理密钥
- 保持 `remote-management.allow-remote: false`
- 只通过反向代理按需开放业务接口
- `pprof.enable: false`，或仅监听 `127.0.0.1`
- 对 `/management.html` 和 `/v0/management/*` 做额外访问控制

### 6.3 管理接口鉴权规则

管理中间件实现见 [internal/api/handlers/management/handler.go](/software/CLIProxyAPI/internal/api/handlers/management/handler.go)。

认证方式：

- `Authorization: Bearer <key>`
- `X-Management-Key: <key>`

本地请求还可以接受运行时 local password。

远程请求默认受 `allow-remote` 限制，并带失败计数与临时封禁逻辑。

## 7. TLS 与反向代理

### 7.1 内建 TLS

配置项：

```yaml
tls:
  enable: true
  cert: "/path/to/fullchain.pem"
  key: "/path/to/privkey.pem"
```

启用后服务直接 `ListenAndServeTLS`。

### 7.2 反向代理建议

如果用 Nginx、Caddy、Traefik 等前置反代，更推荐：

- CLIProxyAPI 仅监听内网或本机
- TLS 在反向代理终结
- 反代层做访问控制、日志、限流

如果要对外开放 WebSocket 路径，记得一并代理：

- `/v1/ws`
- `/v1/responses`

## 8. 凭据持久化后端

### 8.1 默认文件存储

默认使用文件存储，auth 文件保存在 `auth-dir`。

优点：

- 简单
- 易于备份和人工排查

缺点：

- 不适合多实例共享

### 8.2 Postgres

通过环境变量启用：

- `PGSTORE_DSN`
- `PGSTORE_SCHEMA`
- `PGSTORE_LOCAL_PATH`

特点：

- 配置和 auth 存数据库
- 本地仍保留镜像工作目录

适合：

- 单实例但希望配置持久化更强
- 后续扩展多实例共享

### 8.3 Git

通过环境变量启用：

- `GITSTORE_GIT_URL`
- `GITSTORE_GIT_USERNAME`
- `GITSTORE_GIT_TOKEN`
- `GITSTORE_LOCAL_PATH`

特点：

- auth/config 存在 git 仓库
- 本地改动会提交并推送
- 适合把配置与凭据管理纳入 Git 工作流

注意：

- 这不是通用 secrets manager，仓库权限要非常严格

### 8.4 Object Store

通过环境变量启用：

- `OBJECTSTORE_ENDPOINT`
- `OBJECTSTORE_ACCESS_KEY`
- `OBJECTSTORE_SECRET_KEY`
- `OBJECTSTORE_BUCKET`
- `OBJECTSTORE_LOCAL_PATH`

适合需要对象存储统一托管的场景。

## 9. 模型目录更新

默认情况下，服务启动时会调用 `registry.StartModelsUpdater(...)`，后台更新模型目录。

如果想仅使用内置模型目录，可在启动时加：

```bash
go run ./cmd/server -local-model
```

TUI standalone 模式下也支持同样逻辑。

## 10. 健康检查与可观测性

### 10.1 根路径

根路径 `/` 会返回基本服务信息，可用于非常轻量的活性探测。

### 10.2 Keep-Alive

当服务通过运行时 local password 启动特定 keep-alive 模式时，会注册 `/keep-alive`。这个能力主要用于内嵌场景，不建议当作公网健康检查。

### 10.3 日志

日志策略由配置控制：

- `logging-to-file`
- `logs-max-total-size-mb`
- `error-logs-max-files`

如果使用 Compose，默认日志目录映射到宿主机 `./logs`。

### 10.4 pprof

启用方式：

```yaml
pprof:
  enable: true
  addr: "127.0.0.1:8316"
```

建议只绑定 localhost。

## 11. 升级与重启建议

升级时建议保留三类数据：

- `config.yaml`
- `auth-dir`
- `logs`

如果使用 Compose：

1. 先确认挂载目录都在宿主机
2. 拉新镜像或本地构建
3. 重启容器
4. 观察 `/`、日志和必要的 `/v1/models`

如果使用 `docker-build.sh --with-usage`，脚本会尝试保留 usage 统计。

## 12. 常见部署坑

- 没有配置 management key，却期待 `/v0/management/*` 可访问
- 只映射了主端口，没有持久化 `auth-dir`
- 在容器里使用默认 `auth-dir`，结果重建后 OAuth 凭据丢失
- 公网暴露了管理接口，同时开启 `allow-remote`
- 忘记给 WebSocket 路径做反代升级配置
- 修改了配置文件但没注意 watcher 会热更新，导致运行时行为立即变化
- 启用了远端 store，却仍按“本地文件唯一真相”排查问题

## 13. 最小可用部署建议

单机最小可用方案：

- 使用 Docker Compose
- 把 `config.yaml`、`auths/`、`logs/` 挂到宿主机
- 只暴露业务端口
- 管理 API 仅 localhost 可访问
- 用反向代理统一对外暴露 HTTPS

如果后续要做多实例，再考虑 Postgres 或 Object Store 方案。
