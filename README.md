# http-dns-api

基于 Go 的轻量 HTTP 服务：对给定域名做 DNS 解析（跟随 CNAME），返回规范名、CNAME 链与 IPv4/IPv6 地址列表（JSON）。可与仓库内 `yaml/` 下的 Kubernetes 清单（CronJob 同步 CoreDNS / 网关路由等）配合使用。

## 环境要求

| 场景 | 要求 |
|------|------|
| 本地运行 | [Go 1.22+](https://go.dev/dl/) |
| 容器运行 | Docker |
| 集群部署 | `kubectl`，以及推送到你可访问的镜像仓库 |

监听地址由环境变量 **`PORT`** 控制（见下文）；容器镜像默认使用 **`38080`**。

## API 说明

| 方法 | 路径 | 说明 |
|------|------|------|
| `GET` | `/health` | 健康检查，返回 `{"status":"ok"}` |
| `GET` | `/?domain=<域名>` | 解析域名；成功时返回 `domain`、`canonical`、`cname_chain`、`ips` 等字段 |

示例：

```bash
# 未设置 PORT 时，程序默认监听 :8080
curl -sS "http://127.0.0.1:8080/health"
curl -sS "http://127.0.0.1:8080/?domain=www.example.com"
```

解析失败或参数错误时返回 JSON，`error` 字段含说明；部分情况 HTTP 状态码为 `422`（Unprocessable Entity）。

## 本地运行（不构建镜像）

在项目根目录：

```bash
go run .
```

指定端口（与 Dockerfile 默认一致时可使用 `38080`）：

```bash
PORT=38080 go run .
```

服务使用系统 DNS（容器内通常来自 `/etc/resolv.conf`）。

## Docker 构建与运行

```bash
docker build -t http-dns-api:local .
docker run --rm -p 38080:38080 -e PORT=38080 http-dns-api:local
```

```bash
curl -sS "http://127.0.0.1:38080/?domain=www.example.com"
```

## Docker Compose

根目录 `docker-compose.yaml` 中镜像名、端口需按你的环境修改后：

```bash
docker compose up -d
```

## 服务器侧构建脚本（`build.sh`）

适用于在固定目录下拉取上游源码、构建镜像、更新 Compose 中的 `image` 并重启服务。使用前请根据实际环境修改：

- `wget` 的 GitHub Raw 地址（或改为本地已有源码则删除 `wget` 步骤）
- 镜像仓库地址与命名空间
- `dockerconposeFile` 与 `cd` 路径（脚本中为 `/data/dockercompose/http-dns-api`）

脚本依赖：`wget`、`docker`、`docker-compose`（或兼容的 `docker compose`）、`sed`、`grep`。

## Kubernetes（`yaml/`）

统一部署清单见 `yaml/deploy.yaml`（RBAC、ConfigMap、CronJob 等）。CronJob 内嵌逻辑来自 `yaml/sync.sh`：定期请求本服务的 `/?domain=...`，将结果写入 ConfigMap（网关路由、CoreDNS 等）。**部署前请按需修改**清单中的命名空间、`API_BASE`、`GW_FIXED_IP`、镜像地址等。

若你修改了 `sync.sh` 或 `yaml/gateway-route-daemon/apply-host-routes.sh`，需要重新生成带嵌入内容的 YAML：

```bash
cd yaml
python build_all.py
```

然后应用：

```bash
kubectl apply -f yaml/deploy.yaml
```

（具体 `namespace`、资源名以清单为准。）

### 辅助镜像 `Dockerfile.k8s-helpers`

为 CronJob / 网关路由守护等提供 **bash、curl、jq、iproute2** 等工具的 Alpine 镜像。构建与推送后，将 `deploy.yaml` 等中的 `image` 改为你的仓库地址。

## 仓库结构（简要）

| 路径 | 说明 |
|------|------|
| `main.go` | HTTP 服务入口与路由 |
| `Dockerfile` | 多阶段构建，运行阶段为 `scratch` |
| `docker-compose.yaml` | 单机编排示例 |
| `build.sh` | 服务器侧拉取、构建、更新 Compose 的示例脚本 |
| `yaml/deploy.yaml` | Kubernetes 统一部署示例 |
| `yaml/sync.sh` | 同步逻辑源码，由 `embed_sync.py` 嵌入 `deploy.yaml` |
| `yaml/build_all.py` | 重新生成 `deploy.yaml` 与 `gateway-route-daemon.yaml` |
