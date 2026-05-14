# 需求 §3–§7 与站内接口对照（多接口聚合联调）

对应 **`Token-Hub-模型网关对接需求.md`** 中「查询 API Key 用量」「租户整体」「按日趋势」「模型分布」「Key 排行」等段落。

联调脚本：**[`usage-prd-smoke.sh`](./usage-prd-smoke.sh)**（拉日志聚合，需 `bash` + `curl` + `python3`）。  
Bearer 直连站内 REST 联调：**[`usage-api-smoke.sh`](./usage-api-smoke.sh)**（`TEST_SK` / `TEST_ACCESS_TOKEN` 环境变量，见脚本头注释）。

---

## 站内已实现 REST（`UserAuth` + `New-Api-User`，**不读 `logs`**）

数据源：**`quota_data`**（主库，依赖「数据导出」写入）+ **`tokens`**（令牌表）。与消费日志口径不同，见各接口 `data_source` / `non_log_note`。

以下路径均在 **`GET /api/usage/...`** 下，需 **`start_timestamp`**、**`end_timestamp`**（Unix 秒）。管理员可额外传 **`username`**。

| 路径 | PRD | 数据源 | 说明 |
|------|-----|--------|------|
| **`/api/usage/by_key`** | §3 | **`tokens`** | 返回令牌 **累计** `used_quota`/`remain_quota` 等；**`by_model` 恒为空**（无单 Key+时间+模型维度的非日志存储）。 |
| **`/api/usage/overview`** | §4 | **`quota_data` + `tokens`** | 窗口内 `token_used`/`count` 合计；**`active_keys`** = `accessed_time` 落在窗口的令牌数；可选 **`compare_prev=1`**。 |
| **`/api/usage/trend/daily`** | §5 | **`quota_data`** | 按小时桶 `created_at` 聚合成自然日；**`timezone_offset`** 默认 `28800`。 |
| **`/api/usage/by_model`** | §6 | **`quota_data`** | 按 `model_name` 汇总 `token_used`、占比；无失败拆分。 |
| **`/api/usage/keys/ranking`** | §7 | **`tokens`** | 默认按 **`used_quota` 累计** 排序；**`rank_by=accessed_in_range`** 先筛窗口内有访问再排序。 |

若需「时间窗内按 Key 消耗 / 输入输出拆分 / 失败率」等日志级口径，仍须 **`/api/log/self`** 等（见下文脚本路径）。

### 仅用 sk 查询令牌信息（不经用户登录）

| 方法 | 路径 | Header |
|------|------|--------|
| `GET` | **`/api/usage/token/`** | **`Authorization: Bearer sk-...`** |

返回令牌 **名称、额度累计、模型限制、过期时间** 等（见 `GetTokenUsage`）。与 **`/api/usage/by_key`**（需 `UserAuth` + `token_name`）数据源不同：本接口用 **sk 查库**，适合 OpenAI 客户端式「只带 Key」自检。

---

## 核心结论（脚本侧拉日志仍可用）

除下列 **站内聚合 REST** 外，仍可用分页拉取 **`/api/log/self`** 等在调用方自行聚合（适合自定义口径或导出）。

1. **`GET /api/log/self`** / 管理员 **`GET /api/log/`**：**`type=2`**、**`type=5`**，Query 含时间、`token_name`、`group`、`model_name`（LIKE）等。  
2. **`GET /api/token/`**：令牌 **`total`**（`tokens` 表计数）。  
3. **`GET /api/data/self`**：可选对照（需数据导出、跨度 ≤ 1 个月）。

---

## PRD 段落 → 数据口径

| PRD | 说明 | 脚本中实现 |
|-----|------|------------|
| **§3** 单 Key 用量 | 时间范围 + 按模型 | 设置 **`TOKEN_NAME`**，拉取带 `token_name` 的日志后聚合。 |
| **§4** 租户整体 | 项目/租户 → 映射为网关 **单个用户** 名下全部 Key | **`TOKEN_NAME` 留空**；`SCOPE=self` 查当前 `New-Api-User` 用户；`SCOPE=admin` 需管理员 + **`USERNAME`**。 |
| **§5** 按自然日趋势 | 从消费日志 **`created_at`** 按 **`TZ`**（默认 `Asia/Shanghai`）换日聚合。 |
| **§6** 模型分布 | 与 §4 同一批消费日志，按 **`model_name`** 汇总 + Token 占比。 |
| **§7** Key 排行 | 同一批日志按 **`token_name`** 汇总，按总 Token 排序，输出 Top N 与 **`created_at` 最大值** 作最近调用时间。 |
| **§4 环比** | 上一等长周期 | 设置 **`COMPARE_PREV=1`**，脚本再拉上一时间窗并打印对比（粗粒度）。 |

成功/失败：**消费条数** vs **错误条数** 为粗口径（与 **`usage-key.md`** 一致）；可按业务再细化。

---

## 环境变量

| 变量 | 说明 |
|------|------|
| **`SCOPE`** | `self`（默认）或 **`admin`**（走 `/api/log/` 且必须 **`USERNAME`**）。 |
| **`TOKEN_NAME`** | 非空时只做「单 Key」范围（§3）；空为租户级（§4–§7）。 |
| **`USERNAME`** | `SCOPE=admin` 时必填（目标用户名）。 |
| **`BASE`**、`START_TS`、`END_TS`、`PAGE_SIZE`、`MAX_PAGES` | 同 `usage-key.sh`。 |
| **`LOG_GROUP`** | 可选，对应日志 **`group`** 列。 |
| **`MODEL_NAME_LIKE`** | 可选，传给接口的 **`model_name`**（用户侧为 LIKE）。 |
| **`TOP_N`** | 排行条数，默认 `20`。 |
| **`TZ`** | 按日聚合时区，默认 `Asia/Shanghai`。 |
| **`COMPARE_PREV`** | 设为 `1` 时拉取上一等长周期并输出环比摘要。 |
| **`WITH_DATA_SELF`** | 设为 `1` 且 `SCOPE=self`、跨度 ≤30 天时请求 **`GET /api/data/self`** 打印原始序列（对照用）。 |

鉴权：与 `usage-key.sh` 相同（**`ACCESS_TOKEN`** 或 **`LOGIN_USERNAME`** / **`LOGIN_PASSWORD`** + Cookie + **`New-Api-User`**）。

---

## 限制说明

- 受 **`logSearchCountLimit`**（如 1 万条）等站内限制，极大日志量下需缩短时间窗或走离线数仓。  
- 若关闭消费日志，`type=2` 可能为空。  
- **`/api/log/stat`** 的 rpm/tpm 为近实时窗口，**不能**替代历史区间聚合。
