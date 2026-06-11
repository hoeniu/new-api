# Docker 镜像构建说明

本文说明如何从源码构建 new-api 的 Docker 镜像，并在本地或私有仓库中使用。

## 前置条件

- **Docker** 20.10+（多架构构建需 **Buildx**）
- 磁盘空间建议 ≥ 5GB（会拉取 Bun、Go、Debian 等基础镜像）
- 在**仓库根目录**执行所有命令

## 构建流程概览

根目录 `Dockerfile` 采用多阶段构建：

| 阶段 | 作用 |
|------|------|
| `builder` | 用 Bun 构建 `web/default` 前端 |
| `builder-classic` | 用 Bun 构建 `web/classic` 前端 |
| `builder2` | Go 编译后端，嵌入上述前端产物 |
| 最终镜像 | 基于 `debian:bookworm-slim`，暴露 **3000** 端口 |

基础镜像使用 `docker.1ms.run` 加速；Go 依赖默认使用 `goproxy.cn`。

## 1. 设置版本号（建议）

构建会读取根目录 `VERSION` 文件，用于：

- 前端 `VITE_REACT_APP_VERSION`
- 后端 `-ldflags` 中的 `common.Version`

```bash
cd /path/to/new-api

# 示例：写入版本号
echo "v1.0.0" > VERSION
```

> 若 `VERSION` 为空，构建仍可完成，但版本信息不会写入产物。

## 2. 本地构建（单架构）

**amd64（x86_64）：**

```bash
docker build -t new-api:local .
```

**指定标签（便于推送私有仓库）：**

```bash
docker build -t your-registry.example.com/your-namespace/new-api:v1.0.0 .
```

**arm64（Apple Silicon / ARM 服务器）：**

```bash
docker build --platform linux/arm64 -t new-api:local-arm64 .
```

## 3. 网络受限时的构建参数

Go 模块下载失败时，可覆盖代理：

```bash
docker build \
  --build-arg GOPROXY=https://goproxy.io,direct \
  --build-arg GOSUMDB=sum.golang.org \
  -t new-api:local .
```

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `GOPROXY` | `https://goproxy.cn,direct` | Go 模块代理 |
| `GOSUMDB` | `sum.golang.google.cn` | Go checksum 数据库 |
| `TARGETOS` | `linux` | 目标系统 |
| `TARGETARCH` | `amd64` | 目标架构 |

## 4. 多架构构建并推送

与 CI（`.github/workflows/docker-build.yml`）类似，需 Buildx：

```bash
# 创建并使用 buildx 实例（首次）
docker buildx create --name new-api-builder --use

# 登录目标仓库
docker login your-registry.example.com

# 构建并推送 amd64 + arm64
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t your-registry.example.com/your-namespace/new-api:v1.0.0 \
  --push \
  .
```

仅本地加载、不推送（单平台调试）：

```bash
docker buildx build --platform linux/amd64 -t new-api:local --load .
```

## 5. 推送已有镜像

若已本地构建完成：

```bash
docker tag new-api:local your-registry.example.com/your-namespace/new-api:v1.0.0
docker push your-registry.example.com/your-namespace/new-api:v1.0.0
```

## 6. 用 Docker Compose 构建并运行

当前 `docker-compose.yml` 默认使用已有镜像。若要从源码构建，可将 `new-api` 服务改为：

```yaml
services:
  new-api:
    build:
      context: .
      dockerfile: Dockerfile
    image: new-api:local
    # ... 其余配置不变
```

然后：

```bash
docker compose up -d --build
```

> 生产部署前请修改 `docker-compose.yml` 中的默认密码（PostgreSQL、Redis、DSN 等）。

## 7. 开发用镜像（仅后端）

`Dockerfile.dev` 不构建前端，适合配合本地前端 dev server 使用：

```bash
docker compose -f docker-compose.dev.yml up -d --build
```

Go 代码变更后重新构建：

```bash
docker compose -f docker-compose.dev.yml up -d --build new-api
```

前端开发：

```bash
cd web/default && bun install && bun run dev
# 访问 http://localhost:3001（API 自动代理到 :3000）
```

## 8. 运行验证

**快速试跑：**

```bash
docker run --rm -p 3000:3000 -v $(pwd)/data:/data new-api:local
```

**健康检查：**

```bash
curl http://localhost:3000/api/status
```

**Compose 全栈（含 PostgreSQL、Redis）：**

```bash
docker compose up -d
# 访问 http://localhost:3000
```

## 9. 常见问题

### 构建很慢

- 首次会下载 Bun、Go、Debian 及 npm/go 依赖，属正常现象
- 可加 `--progress=plain` 查看详细日志：

```bash
docker build --progress=plain -t new-api:local .
```

### 前端构建失败

- 确认 `web/default/bun.lock`、`web/classic/bun.lock` 存在
- 网络问题可配置 Docker 代理或使用 VPN

### Go 下载超时

- 使用 `--build-arg GOPROXY=...` 切换代理（见上文第 3 节）

### 构建上下文

`.dockerignore` 已排除 `node_modules`、`dist`、`.git`、`docs` 等；前端会在镜像内重新构建，无需本地先 `bun run build`。

## 10. 推荐流程示例

```bash
cd /path/to/new-api

# 1. 写版本
echo "v1.0.0" > VERSION

# 2. 构建
docker build -t new-api:local .

# 3. 推送（可选）
docker tag new-api:local your-registry.example.com/your-namespace/new-api:v1.0.0
docker push your-registry.example.com/your-namespace/new-api:v1.0.0

# 4. 启动
docker compose up -d
```

## 相关文件

| 文件 | 说明 |
|------|------|
| `Dockerfile` | 生产镜像（前端 + 后端完整构建） |
| `Dockerfile.dev` | 开发镜像（仅后端，前端占位页） |
| `docker-compose.yml` | 生产 Compose 配置 |
| `docker-compose.dev.yml` | 开发 Compose 配置 |
| `.dockerignore` | 构建上下文排除规则 |
| `.github/workflows/docker-build.yml` | CI 多架构构建与推送 |

## 参考

- [README.zh_CN.md](../../README.zh_CN.md) — 快速开始与部署方式
- [宝塔面板部署](BT.md)
- 官方镜像：`calciumion/new-api:latest`
