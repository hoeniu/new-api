# new-api 部署售卖与容量规划指南（PostgreSQL + Redis）

> 结合 [功能对照](llm-proxy-spec-comparison.md)、[使用场景](llm-proxy-use-scenarios.md) 与仓库 `docker-compose.yml` 整理。  
> **容量数字为工程经验预估**，用于选型与报价，**非 SLA 承诺**；上线前请用真实流量压测校准。

---

## 1. 售卖 / 交付方式建议

| 模式 | 典型客户 | 部署形态 | 计费建议 | 说明 |
|------|----------|----------|----------|------|
| **A. 一体机标准版** | 政企内网、实验室、单业务 | **单节点**（PG + Redis + new-api 同机或同 compose） | 买断 + 年维保 / 按核数订阅 | 对应架构图「轻量 Proxy」；配置在 DB，非单文件 yaml |
| **B. 私有化专业版** | 多部门、多业务线 | **单节点高配** 或 **2 节点 API + 独立 PG/Redis** | 项目制 + 维保 | 要 RPM/TPM、消费日志、对账 |
| **C. 私有化高可用版** | 7×24、对外 SaaS 底座 | **多 API 节点 + LB + PG 主从 + Redis 哨兵/主从** | 项目制 + SLA 档位 | 必须统一 `SESSION_SECRET`、`CRYPTO_SECRET` |
| **D. 托管运营版** | 不想自建运维 | 服务商多租户 **多节点集群** | 按 Token / 按 Key / 包月额度 | 与产品内「令牌额度、倍率」一致 |
| **E. 仅网关转售** | 已有用户体系 | 单/多节点 API，对接客户 IdP | 按并发或通道数 | 少用控制台，主要走 OpenAI 兼容 API |

**与 LLM Proxy 说明文档的差异（报价时需说明）：**

- **没有**「模型聚合」独立配置 → 高阶方案用多渠道 + `model_mapping`（见使用场景 S5），实施工时计入。
- **没有**中央配置文件交付物 → 交付物为：compose/Helm、`.env` 模板、初始化 SQL、运维手册。

---

## 2. 部署拓扑：单节点 vs 多节点

### 2.1 单节点（一体机 / 试点）

```mermaid
flowchart LR
  subgraph one_box["一台物理机 / 一台 VM"]
    API[new-api :3000]
    PG[(PostgreSQL)]
    RD[(Redis)]
  end
  Client[业务系统 / SDK] --> API
  API --> PG
  API --> RD
  API --> Upstream[上游 LLM / vLLM / 公有云]
```

**特点**

- 运维最简单，成本最低。
- 瓶颈通常在：**磁盘 IO（日志表）**、**上游延迟**，而非网关 CPU。
- Redis 建议仍部署：令牌 **RPM/TPM**、渠道缓存、多机扩展前习惯一致。

**参考**：仓库根目录 `docker-compose.yml`（`new-api` + `postgres:15` + `redis`）。

---

### 2.2 多节点（水平扩展 API）

```mermaid
flowchart TB
  Client[业务系统] --> LB[Nginx / SLB / HAProxy]
  LB --> API1[new-api 节点 1]
  LB --> API2[new-api 节点 2]
  LB --> API3[new-api 节点 N]
  API1 --> PG[(PostgreSQL 共用)]
  API2 --> PG
  API3 --> PG
  API1 --> RD[(Redis 共用)]
  API2 --> RD
  API3 --> RD
  API1 --> Upstream[上游模型]
  API2 --> Upstream
  API3 --> Upstream
```

**特点**

- **无状态**：API 进程可水平加；**状态在 PG + Redis**。
- 配置、渠道、令牌 **只写一份库**，各节点读同一 `SQL_DSN`。
- 管理后台登录依赖 **`SESSION_SECRET` 各节点相同**（见 README 多机部署说明）。
- 公用 Redis 须配置 **`CRYPTO_SECRET`**，否则缓存密文无法跨节点解密。

**不适合多节点拆分的部分**

- PostgreSQL、Redis 本身仍需高可用方案（主从、云 RDS、哨兵），不是简单「多复制几个 new-api」就完事。

---

## 3. 推荐部署方式（PG + Redis）

### 3.1 Docker Compose（首选：一体机 / 小规模）

| 组件 | 镜像建议 | 端口 |
|------|----------|------|
| new-api | 项目镜像或自建 | 3000 |
| PostgreSQL | `postgres:15` | 内网 5432 |
| Redis | `redis:7` + 密码 | 内网 6379 |

**步骤概要**

1. 修改 `docker-compose.yml` 中 **所有默认密码**（PG、Redis、DSN）。
2. 环境变量至少：`SQL_DSN`、`REDIS_CONN_STRING`、`SESSION_SECRET`（≥32 字符随机）。
3. 多节点时每实例增加：`NODE_NAME=node-1`（审计区分）、相同 `SESSION_SECRET` / `CRYPTO_SECRET`。
4. 生产建议：`BATCH_UPDATE_ENABLED=true`，按需开 `ERROR_LOG_ENABLED`；生产勿关闭必要限流（开发用 `.env.example` 里关闭 429 仅本地）。
5. 数据卷：`pg_data`、`./data`、`./logs` 持久化；**磁盘容量重点给 PG**。

### 3.2 裸机 / VM（systemd）

1. 安装 PostgreSQL 15+、Redis 7+。
2. 单二进制或容器只跑 new-api，`.env` 指向 `127.0.0.1` 的 PG/Redis。
3. 前置 Nginx：TLS 终结、`proxy_read_timeout` 对流式建议 **300s+**（与 `STREAMING_TIMEOUT` 一致）。
4. `SQL_MAX_OPEN_CONNS` / `SQL_MAX_IDLE_CONNS`：多节点时按 `节点数 × 每进程连接上限` 调整 PG `max_connections`。

### 3.3 Kubernetes（中大规模）

| 工作负载 | 副本 | 说明 |
|----------|------|------|
| Deployment `new-api` | 2～N | HPA 可按 CPU/自定义指标 |
| StatefulSet 或云 RDS | PG | 不建议无运维团队自管 PG Pod |
| Redis | 云缓存 / Sentinel | 小内存即可 |
| Ingress | 1 | WebSocket/SSE 需支持长连接 |

Secret 统一存放：`SQL_DSN`、`REDIS_CONN_STRING`、`SESSION_SECRET`、`CRYPTO_SECRET`。

---

## 4. 能力预估（经验值）

### 4.1 先理解瓶颈

| 层级 | 通常瓶颈 | 说明 |
|------|----------|------|
| 上游 LLM | **首 Token 延迟、并发限额** | 网关再强也被上游卡住 |
| new-api 进程 | 中长连接内存、goroutine | **流式**占连接时间长 |
| PostgreSQL | **消费日志写入** | `LogConsumeEnabled=true` 时每次调用写库 |
| Redis | 一般不是瓶颈 | RPM/TPM 计数，内存占用小 |
| 磁盘 | **日志表、quota_data 膨胀** | 需保留策略与清理 |

网关本身多为 **IO 等待型**；CPU 在纯代理场景下往往有余量，**不要按「CPU 核数 = LLM 算力」**向客户承诺。

### 4.2 单节点能力区间（PG + Redis，经验预估）

假设：8C16G 物理机或同规格 VM，NVMe SSD，开启消费日志，典型 chat 流式为主。

| 指标 | 保守 | 中等 | 激进 | 备注 |
|------|------|------|------|------|
| **并发流式连接** | 300～500 | 500～1 000 | 1 000～2 000 | 视上游响应速度、是否大图/长上下文 |
| **短请求 QPS**（非流式、小 body） | 100～300 | 300～800 | 800+ | 受 PG 写日志拖累明显 |
| **管理端并发用户** | 20～50 | 50～100 | 100+ | 与 API 中继争抢 PG 连接 |
| **注册令牌规模** | 1 万 Key | 5 万 Key | 10 万+ | 表本身不大；限流 key 在 Redis |
| **日调用量（写日志）** | 10～30 万次 | 30～100 万次 | 100 万+ | **磁盘与 PG 维护成为关键** |

**4C8G 一体机（S 档）**：约为上表「保守」档的 **50%～70%**；更适合 **≤30 并发流式**、日调用 **≤10 万** 的内网试点。

**16C32G（L 档）**：约为「中等」～「激进」之间；仍建议 **日志归档 / 分库 / 关闭全量日志** 才能撑更高日量。

### 4.3 多节点能力叠加

| 项目 | 计算方式 |
|------|----------|
| **API 中继并发** | 近似 **线性叠加**（N 个等价节点 × 单节点并发 × 0.7～0.9 效率） |
| **管理后台** | 任意节点均可；需 **粘性会话** 或接受重新登录 |
| **PostgreSQL** | **不随 API 节点线性扩展**；需升配或读写分离、日志分表 |
| **Redis** | 2～4GB 内存多数场景够用；RPM/TPM Key 数量随令牌数增 |

**示例**：2 × 8C16G API 节点 + 独立 8C32G PG 机 + 2C4G Redis → 经验上 **800～1 500 并发流式**（仍取决于上游与是否写日志）。

---

## 5. 硬件设计：单机（PC / 服务器）

### 5.1 规格档位（PostgreSQL + Redis + new-api 同机）

| 档位 | 场景 | CPU | 内存 | 系统盘 | 数据盘（PG+日志） | 网络 |
|------|------|-----|------|--------|-------------------|------|
| **S 试点** | 内网一体机、PoC | **4 核** | **8 GB** | 100 GB SSD | 与系统盘同盘 **≥200 GB** | 千兆 |
| **M 标准** | 部门级、中小 SaaS | **8 核** | **16 GB** | 100 GB SSD | **500 GB NVMe** 独立挂载到 PG `data` | 千兆 |
| **L 生产** | 高日志量、多租户 | **16 核** | **32 GB** | 100 GB SSD | **1 TB NVMe**（PG）+ 可选冷备盘 | 千兆/万兆 |
| **XL 超重日志** | 百万级日调用 | **32 核** | **64 GB** | 100 GB SSD | **2 TB NVMe** 或 PG 专用阵列 | 万兆 |

**CPU**

- 优先 **高主频、多核均衡**（Intel Xeon / AMD EPYC / 桌面 i7/i9 亦可用于 S 档）。
- 无需 GPU（网关不跑推理）。

**内存**

- **PostgreSQL**：`shared_buffers` 建议物理内存 **15%～25%**（M 档约 4 GB，L 档约 8 GB）。
- **Redis**：**1～2 GB** 足够多数 RPM/TPM；预留 **maxmemory-policy allkeys-lru**。
- **new-api**：单实例常驻约 **200～500 MB**，流式并发按每连接 **2～8 MB** 粗算（视请求体大小）。
- **公式（粗算）**：`总内存 ≥ 4GB(PG+OS) + 2GB(Redis) + 0.5GB(new-api) + 并发数×5MB`。

**磁盘（最关键）**

| 用途 | 建议 |
|------|------|
| 系统 + 程序 | SSD **≥100 GB** |
| PostgreSQL 数据 | **独立 NVMe**；随机写 IOPS 越高越好 |
| 日志增长 | 按 **每条消费日志 1～5 KB** 粗算：日 50 万次 ≈ **0.5～2.5 GB/天**（未含索引） |
| 保留 90 天 | M 档至少 **200 GB 专用于 PG**；L 档 **500 GB～1 TB** |
| `./logs` 文件 | 若 `ERROR_LOG_ENABLED`，另备 **10～50 GB** |

**不推荐**

- 机械盘单独跑高写入 PG；
- S 档内存 **<8 GB** 仍开高并发 + 全量消费日志。

---

## 6. 硬件设计：多节点分工

### 6.1 推荐角色划分

| 角色 | 数量 | CPU | 内存 | 磁盘 | 说明 |
|------|------|-----|------|------|------|
| **LB** | 2（主备）或云 SLB | 2 核 | 2 GB | 20 GB | Nginx / 云负载均衡；**流式超时 ≥300s** |
| **new-api** | 2～N | **8 核/节点** | **16 GB/节点** | 50 GB | 无状态；可不落本地业务数据 |
| **PostgreSQL** | 1 主 + 1 备 | **8～16 核** | **32～64 GB** | **1 TB NVMe** | 连接数 ≥ `N×100`（默认每节点 max open 较高时需下调） |
| **Redis** | 1 主 + 1 备或 Sentinel | **2～4 核** | **4～8 GB** | 20 GB SSD | 持久化 AOF 可选；密码 + `CRYPTO_SECRET` |

### 6.2 多节点时各层设计要点

**API 节点（可横向加）**

- 每台 **8C16G** 起；**不存 PostgreSQL 数据**。
- 环境变量：`NODE_NAME` 唯一；`SESSION_SECRET`、`CRYPTO_SECRET`、`SQL_DSN`、`REDIS_CONN_STRING` **完全一致**。
- 建议 `MEMORY_CACHE_ENABLED=true` 且 **共用 Redis**（渠道缓存一致）。
- 前置 LB **不要用短超时**；健康检查 `GET /api/status`。

**PostgreSQL（共享，慎扩容）**

- `max_connections`：例如 3 节点 × 每节点 `SQL_MAX_OPEN_CONNS=200` → 需 **≥600**（再加管理连接余量）。
- 索引维护、**定期清理 logs**（见使用场景 S11）。
- 可选：`LOG_SQL_DSN` 指向 **独立日志库**（减轻主库写压力，需运维能力）。

**Redis（共享）**

- 仅放限流、缓存；**4 GB 内存**对十万级 Key 通常足够。
- 必须设 **`requirepass`** 与 **`CRYPTO_SECRET`**（多机部署 README 要求）。

**磁盘不在 API 节点堆日志库**

- 大表在 PG 机；API 节点仅应用日志文件（可选）。

### 6.3 多节点规模示例

| 目标并发流式（经验） | API 节点 | API 单机规格 | PG 规格 | Redis |
|----------------------|----------|--------------|---------|-------|
| ~500 | 1（+备机可选） | 8C16G | 8C16G, 500GB NVMe | 2C4G |
| ~1 000 | 2 | 8C16G | 8C32G, 1TB NVMe | 2C4G |
| ~2 000 | 3～4 | 8C16G | 16C64G, 1～2TB NVMe | 4C8G |
| ~5 000+ | 6+ & 架构评审 | 16C32G | 专用 DBA / 分库分表 | 哨兵集群 |

---

## 7. 环境变量清单（生产最小集）

| 变量 | 单节点 | 多节点 | 说明 |
|------|--------|--------|------|
| `SQL_DSN` | 必填 | 必填，**相同** | `postgresql://user:pass@host:5432/new-api` |
| `REDIS_CONN_STRING` | 强烈建议 | 必填，**相同** | 启用 RPM/TPM、推荐缓存 |
| `SESSION_SECRET` | 建议 | **必填** | 随机长串；多机不一致会导致登录错乱 |
| `CRYPTO_SECRET` | 用 Redis 时建议 | **必填** | 多机共用 Redis 时解密缓存 |
| `NODE_NAME` | 可选 | **建议** | 审计区分节点 |
| `BATCH_UPDATE_ENABLED` | `true` | `true` | 批量写库，减 PG 压力 |
| `SQL_MAX_OPEN_CONNS` | 默认或 100～200 | **按节点数下调** | 避免打满 PG `max_connections` |
| `DataExportEnabled` / 间隔 | 按需 | 按需 | 看板 `quota_data`，默认约 5 分钟 |

---

## 8. 售卖套餐与硬件对照（示例）

| 套餐名 | 部署 | 参考硬件 | 经验能力（声明非 SLA） | 适用 |
|--------|------|----------|------------------------|------|
| **标准一体机** | 单节点 compose | S：4C8G, 200GB SSD | ≤30 并发流式，日 ≤10 万 call | 实验室、单业务 |
| **专业单机** | 单节点 | M：8C16G, 500GB NVMe | ≤80 并发，日 10～50 万 | 部门私有化 |
| **高可用双活** | 2 API + PG 主备 + Redis | 2×8C16G + 8C32G PG | ≤150 并发，日 50～100 万 | 生产对外 |
| **集群扩展** | N API + 托管 RDS | N×8C16G + 云 PG/Redis | 按 §4.3 线性粗算 | 托管 SaaS |

**增值服务（报价项）**

- 模型聚合等价实施（多渠道 + mapping）；
- `LOG_SQL_DSN` 日志库拆分；
- 监控告警（Prometheus + 日志盘阈值）；
- 压测报告（客户流量模型）。

---

## 9. 运维检查清单

**上线前**

- [ ] 修改所有默认密码（PG、Redis、DSN）
- [ ] `SESSION_SECRET` / `CRYPTO_SECRET` 已设置（多节点）
- [ ] Redis 可用，令牌 RPM/TPM 实测生效
- [ ] Nginx `proxy_read_timeout` ≥ 流式超时
- [ ] 磁盘监控：PG 数据目录、剩余 >30%

**运行期**

- [ ] 定期清理消费日志（系统设置 → 日志清理）或 cron
- [ ] 关注 PG 连接数、慢查询
- [ ] 上游 429/5xx 与网关渠道重试策略（运营设置）
- [ ] 多节点 `NODE_NAME` 与审计日志可追溯

---

## 10. 相关文档

- [Lenovo API 网关一体机 · HTML 幻灯片](lenovo-api-gateway-aio-deck.html)（浏览器打开，支持预览/播放）
- [功能对照](llm-proxy-spec-comparison.md)
- [使用场景与操作](llm-proxy-use-scenarios.md)
- [宝塔安装](installation/BT.md)
- 仓库 `docker-compose.yml`、`.env.example`、`README.zh_CN.md`（多机部署章节）

---

*容量与硬件建议随版本、是否写日志、上游模型类型变化；重大商用前请在目标环境做 24h 压测并保留 PG 扩容预算。*
