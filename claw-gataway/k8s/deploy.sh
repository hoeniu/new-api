#!/usr/bin/env bash
#
# New API Kubernetes 一键部署脚本
# 使用前请修改下方「必填配置」中的环境变量，然后执行: ./deploy.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# 必填配置 — 部署前请修改以下变量
# =============================================================================

# Kubernetes 命名空间
NAMESPACE="new-api"

# New API 镜像
NEW_API_IMAGE="registry-public.lenovo.com/newapi/new-api:new-api-v1"

# PostgreSQL / Redis 镜像
POSTGRES_IMAGE="registry-public.lenovo.com/newapi/postgres:15"
REDIS_IMAGE="registry-public.lenovo.com/newapi/redis:latest"

# 管理员账号（首次部署自动初始化，跳过 Web 向导）
INIT_ADMIN_USERNAME="admin"
INIT_ADMIN_PASSWORD="ChangeMe123456"

# Web Access Token：用于 API 调用鉴权（Authorization 请求头，最长 32 字符）
# 示例: curl -H "Authorization: ${INIT_WEB_ACCESS_TOKEN}" -H "New-Api-User: 1" http://<host>:30080/api/user/self
INIT_WEB_ACCESS_TOKEN="w2h6nb+FO1cmYTg4aYvfjvflMkRyyZRn"

# 使用模式: external（对外运营，默认）| self（自用）| demo（演示站点）
INIT_USAGE_MODE="external"

# Session 密钥（至少 32 字符，生产环境务必修改）
SESSION_SECRET="r7MG1tbacA4eg2fAJDvrE0qri2w1ztLqCTq5HI50"

# PostgreSQL
POSTGRES_USER="root"
POSTGRES_PASSWORD="123456"
POSTGRES_DB="new-api"

# Redis
REDIS_PASSWORD="123456"

# NodePort 对外端口（30000-32767）
NODE_PORT="30080"

# 本地数据目录（hostPath 挂载到节点本机）
DATA_HOST_PATH="/data"
PG_DATA_HOST_PATH="/data/pgdata"

# vLLM 模型服务（Helm chart-helm，本地 hostPath 挂载）
DEPLOY_VLLM="true"
VLLM_RELEASE_NAME="vllm"
VLLM_MODEL_NAME="qwen2.5-7b"
VLLM_MODEL_HOST_PATH="/data/models/${VLLM_MODEL_NAME}"
# GPU: auto | true | false
VLLM_GPU_ENABLED="auto"
# 仅当集群已创建 RuntimeClass 时填写（kubectl get runtimeclass）
VLLM_GPU_RUNTIME_CLASS=""

# vLLM 自动注册到 New API（渠道 + API Token）
AUTO_REGISTER_VLLM="true"
VLLM_CHANNEL_NAME="vllm"
VLLM_CHANNEL_BASE_URL="http://vllm-service.new-api.svc.cluster.local/v1"
VLLM_CHANNEL_KEY="vllm"
VLLM_TOKEN_NAME="auto-vllm"
NEW_API_ROOT_USER_ID="1"

SQL_DSN="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}"
REDIS_CONN_STRING="redis://:${REDIS_PASSWORD}@redis:6379"

# =============================================================================
# 以下为部署逻辑，一般无需修改
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "缺少命令: $1"
    exit 1
  fi
}

validate_config() {
  if [[ ${#INIT_ADMIN_USERNAME} -gt 12 ]]; then
    error "INIT_ADMIN_USERNAME 长度不能超过 12 个字符"
    exit 1
  fi
  if [[ ${#INIT_ADMIN_PASSWORD} -lt 8 ]]; then
    error "INIT_ADMIN_PASSWORD 长度至少 8 个字符"
    exit 1
  fi
  if [[ ${#INIT_WEB_ACCESS_TOKEN} -gt 32 ]]; then
    error "INIT_WEB_ACCESS_TOKEN 长度不能超过 32 个字符"
    exit 1
  fi
  if [[ ${#SESSION_SECRET} -lt 32 ]]; then
    error "SESSION_SECRET 长度至少 32 个字符"
    exit 1
  fi
  case "$INIT_USAGE_MODE" in
    external|self|demo) ;;
    *)
      error "INIT_USAGE_MODE 必须是 external、self 或 demo"
      exit 1
      ;;
  esac
}

calc_total_steps() {
  TOTAL_STEPS=3
  if [[ "${DEPLOY_VLLM}" == "true" ]]; then
    TOTAL_STEPS=4
    if [[ "${AUTO_REGISTER_VLLM}" == "true" ]]; then
      TOTAL_STEPS=5
    fi
  fi
}

apply_manifest() {
  local file="$1"
  info "Applying ${file}..."
  kubectl apply -f "$file"
}

render_postgres_manifest() {
  sed "s|__POSTGRES_IMAGE__|${POSTGRES_IMAGE}|g" "${SCRIPT_DIR}/postgres.yaml" \
    | sed "s|__PG_DATA_HOST_PATH__|${PG_DATA_HOST_PATH}|g"
}

render_redis_manifest() {
  sed "s|__REDIS_IMAGE__|${REDIS_IMAGE}|g" "${SCRIPT_DIR}/redis.yaml"
}

render_new_api_manifest() {
  sed "s|__NEW_API_IMAGE__|${NEW_API_IMAGE}|g" \
    "${SCRIPT_DIR}/new-api.yaml" \
    | sed "s|nodePort: 30080|nodePort: ${NODE_PORT}|g" \
    | sed "s|__DATA_HOST_PATH__|${DATA_HOST_PATH}|g"
}

deploy_vllm() {
  require_cmd helm

  info "[4/${TOTAL_STEPS}] 部署 vLLM 模型 (${VLLM_MODEL_NAME})..."
  mkdir -p "${VLLM_MODEL_HOST_PATH}"
  info "vLLM 模型目录: ${VLLM_MODEL_HOST_PATH}"

  local gpu_enabled="${VLLM_GPU_ENABLED}"
  if [[ "${gpu_enabled}" == "auto" ]]; then
    if kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null \
      | awk '$1+0>0 { found=1 } END { exit !found }'; then
      gpu_enabled="true"
      info "检测到 GPU 节点"
    else
      gpu_enabled="false"
      warn "未检测到 GPU，vLLM 将以 CPU 模式部署"
    fi
  fi

  local -a helm_args=(
    upgrade --install "${VLLM_RELEASE_NAME}" "${SCRIPT_DIR}/chart-helm"
    -n "${NAMESPACE}"
    --set "servedModelName=${VLLM_MODEL_NAME}"
    --set "extraInit.storage.hostPath=${VLLM_MODEL_HOST_PATH}"
    --set "gpu.enabled=${gpu_enabled}"
  )

  if [[ "${gpu_enabled}" == "true" ]]; then
    helm_args+=(--set "gpu.count=1")
    if [[ -n "${VLLM_GPU_RUNTIME_CLASS}" ]]; then
      helm_args+=(--set "gpu.runtimeClassName=${VLLM_GPU_RUNTIME_CLASS}")
    fi
  else
    helm_args+=(
      --set "resources.requests.cpu=2"
      --set "resources.limits.cpu=4"
      --set "resources.requests.memory=8Gi"
      --set "resources.limits.memory=16Gi"
    )
  fi

  helm "${helm_args[@]}"

  info "等待 vLLM 就绪（模型加载可能较久）..."
  kubectl -n "${NAMESPACE}" rollout status "deployment/${VLLM_RELEASE_NAME}-deployment-vllm" --timeout=1200s
}

wait_new_api_api() {
  local attempt
  for attempt in $(seq 1 30); do
    if curl -sf "http://${NODE_IP}:${NODE_PORT}/api/status" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  error "New API 接口未就绪: http://${NODE_IP}:${NODE_PORT}/api/status"
  exit 1
}

register_vllm_in_new_api() {
  require_cmd curl
  require_cmd python3

  info "[${TOTAL_STEPS}/${TOTAL_STEPS}] 自动注册 vLLM 渠道与 API Token..."
  wait_new_api_api

  REGISTER_RESULT="$(
    REGISTER_NODE_IP="${NODE_IP}" \
    NODE_PORT="${NODE_PORT}" \
    INIT_WEB_ACCESS_TOKEN="${INIT_WEB_ACCESS_TOKEN}" \
    NEW_API_ROOT_USER_ID="${NEW_API_ROOT_USER_ID}" \
    VLLM_CHANNEL_NAME="${VLLM_CHANNEL_NAME}" \
    VLLM_CHANNEL_BASE_URL="${VLLM_CHANNEL_BASE_URL}" \
    VLLM_CHANNEL_KEY="${VLLM_CHANNEL_KEY}" \
    VLLM_MODEL_NAME="${VLLM_MODEL_NAME}" \
    VLLM_TOKEN_NAME="${VLLM_TOKEN_NAME}" \
    python3 <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

BASE = f"http://{os.environ['REGISTER_NODE_IP']}:{os.environ['NODE_PORT']}"
AUTH_HEADERS = {
    "Authorization": os.environ["INIT_WEB_ACCESS_TOKEN"],
    "New-Api-User": os.environ["NEW_API_ROOT_USER_ID"],
    "Content-Type": "application/json",
}


def api_request(method, path, body=None):
    data = None
    headers = dict(AUTH_HEADERS)
    if body is not None:
        data = json.dumps(body).encode()
    req = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        payload = exc.read().decode()
        raise RuntimeError(f"{method} {path} failed ({exc.code}): {payload}") from exc


def ensure_success(resp, action):
    if not resp.get("success"):
        raise RuntimeError(f"{action} failed: {json.dumps(resp, ensure_ascii=False)}")


def find_by_name(items, name):
    for item in items or []:
        if item.get("name") == name:
            return item
    return None


channel_name = os.environ["VLLM_CHANNEL_NAME"]
channel_search = api_request("GET", f"/api/channel/search?keyword={channel_name}&page_size=50")
ensure_success(channel_search, "search channel")
channel_items = (channel_search.get("data") or {}).get("items") or []
existing_channel = find_by_name(channel_items, channel_name)

if existing_channel:
    channel_action = "exists"
else:
    create_channel = api_request("POST", "/api/channel/", {
        "mode": "single",
        "channel": {
            "name": channel_name,
            "type": 1,
            "key": os.environ["VLLM_CHANNEL_KEY"],
            "base_url": os.environ["VLLM_CHANNEL_BASE_URL"],
            "models": os.environ["VLLM_MODEL_NAME"],
            "group": "default",
            "status": 1,
            "auto_ban": 0,
        },
    })
    ensure_success(create_channel, "create channel")
    channel_action = "created"

token_name = os.environ["VLLM_TOKEN_NAME"]
token_search = api_request("GET", f"/api/token/search?keyword={token_name}&page_size=50")
ensure_success(token_search, "search token")
token_items = (token_search.get("data") or {}).get("items") or []
existing_token = find_by_name(token_items, token_name)

if existing_token:
    token_id = existing_token["id"]
    token_action = "exists"
else:
    create_token = api_request("POST", "/api/token/", {
        "name": token_name,
        "unlimited_quota": True,
        "expired_time": -1,
        "group": "default",
        "model_limits_enabled": False,
    })
    ensure_success(create_token, "create token")
    token_search = api_request("GET", f"/api/token/search?keyword={token_name}&page_size=50")
    ensure_success(token_search, "search token after create")
    token_items = (token_search.get("data") or {}).get("items") or []
    created_token = find_by_name(token_items, token_name)
    if not created_token:
        raise RuntimeError("token created but not found")
    token_id = created_token["id"]
    token_action = "created"

key_resp = api_request("POST", f"/api/token/{token_id}/key", {})
ensure_success(key_resp, "get token key")
api_key = (key_resp.get("data") or {}).get("key", "")
if not api_key:
    raise RuntimeError("token key is empty")

print(json.dumps({
    "channel_action": channel_action,
    "token_action": token_action,
    "api_key": api_key,
}, ensure_ascii=False))
PY
  )"

  GENERATED_API_TOKEN="$(echo "${REGISTER_RESULT}" | python3 -c "import json,sys; print(json.load(sys.stdin)['api_key'])")"
  CHANNEL_ACTION="$(echo "${REGISTER_RESULT}" | python3 -c "import json,sys; print(json.load(sys.stdin)['channel_action'])")"
  TOKEN_ACTION="$(echo "${REGISTER_RESULT}" | python3 -c "import json,sys; print(json.load(sys.stdin)['token_action'])")"

  info "渠道「${VLLM_CHANNEL_NAME}」: ${CHANNEL_ACTION}"
  info "令牌「${VLLM_TOKEN_NAME}」: ${TOKEN_ACTION}"
}

main() {
  require_cmd kubectl
  validate_config
  calc_total_steps

  mkdir -p "${DATA_HOST_PATH}" "${PG_DATA_HOST_PATH}"
  info "New API 数据目录: ${DATA_HOST_PATH}"
  info "PostgreSQL 数据目录: ${PG_DATA_HOST_PATH}"
  if [[ "${DEPLOY_VLLM}" == "true" ]]; then
    info "vLLM 模型目录: ${VLLM_MODEL_HOST_PATH}"
  fi

  info "创建命名空间 ${NAMESPACE}..."
  kubectl apply -f "${SCRIPT_DIR}/namespace.yaml"

  info "创建 Secret（管理员、Token、数据库、Redis）..."
  kubectl -n "${NAMESPACE}" create secret generic new-api-secrets \
    --from-literal=INIT_ADMIN_USERNAME="${INIT_ADMIN_USERNAME}" \
    --from-literal=INIT_ADMIN_PASSWORD="${INIT_ADMIN_PASSWORD}" \
    --from-literal=INIT_WEB_ACCESS_TOKEN="${INIT_WEB_ACCESS_TOKEN}" \
    --from-literal=INIT_USAGE_MODE="${INIT_USAGE_MODE}" \
    --from-literal=SESSION_SECRET="${SESSION_SECRET}" \
    --from-literal=POSTGRES_USER="${POSTGRES_USER}" \
    --from-literal=POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
    --from-literal=POSTGRES_DB="${POSTGRES_DB}" \
    --from-literal=REDIS_PASSWORD="${REDIS_PASSWORD}" \
    --from-literal=SQL_DSN="${SQL_DSN}" \
    --from-literal=REDIS_CONN_STRING="${REDIS_CONN_STRING}" \
    --dry-run=client -o yaml | kubectl apply -f -

  apply_manifest "${SCRIPT_DIR}/configmap.yaml"

  info "[1/${TOTAL_STEPS}] 部署 PostgreSQL..."
  render_postgres_manifest | kubectl apply -f -
  info "等待 PostgreSQL 就绪..."
  kubectl -n "${NAMESPACE}" rollout status statefulset/postgres --timeout=300s

  info "[2/${TOTAL_STEPS}] 部署 Redis..."
  render_redis_manifest | kubectl apply -f -
  info "等待 Redis 就绪..."
  kubectl -n "${NAMESPACE}" rollout status deployment/redis --timeout=180s

  info "[3/${TOTAL_STEPS}] 部署 New API..."
  render_new_api_manifest | kubectl apply -f -
  info "等待 New API 就绪..."
  kubectl -n "${NAMESPACE}" rollout status deployment/new-api --timeout=300s

  NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
  if [[ -z "${NODE_IP}" ]]; then
    NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')"
  fi

  if [[ "${DEPLOY_VLLM}" == "true" ]]; then
    deploy_vllm
    if [[ "${AUTO_REGISTER_VLLM}" == "true" ]]; then
      register_vllm_in_new_api
    fi
  else
    info "跳过 vLLM 部署（DEPLOY_VLLM=${DEPLOY_VLLM}）"
  fi

  echo ""
  info "部署完成！"
  echo ""
  echo "  Web 地址:     http://${NODE_IP}:${NODE_PORT}"
  echo "  管理员账号:   ${INIT_ADMIN_USERNAME}"
  echo "  管理员密码:   ${INIT_ADMIN_PASSWORD}"
  echo "  Access Token: ${INIT_WEB_ACCESS_TOKEN}"
  echo ""
  echo "  API 调用示例:"
  echo "    curl -H \"Authorization: ${INIT_WEB_ACCESS_TOKEN}\" \\"
  echo "         -H \"New-Api-User: 1\" \\"
  echo "         http://${NODE_IP}:${NODE_PORT}/api/user/self"
  echo ""
  if [[ "${DEPLOY_VLLM}" == "true" ]]; then
    echo "  vLLM 渠道:    ${VLLM_CHANNEL_NAME} → ${VLLM_CHANNEL_BASE_URL}"
    echo "  vLLM 模型:    ${VLLM_MODEL_NAME}"
    echo "  模型目录:     ${VLLM_MODEL_HOST_PATH}"
    if [[ "${AUTO_REGISTER_VLLM}" == "true" && -n "${GENERATED_API_TOKEN:-}" ]]; then
      echo "  API Token:    sk-${GENERATED_API_TOKEN}"
      echo ""
      echo "  模型调用示例:"
      echo "    curl -H \"Authorization: Bearer sk-${GENERATED_API_TOKEN}\" \\"
      echo "         -H \"Content-Type: application/json\" \\"
      echo "         -d '{\"model\":\"${VLLM_MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"你好\"}]}' \\"
      echo "         http://${NODE_IP}:${NODE_PORT}/v1/chat/completions"
    fi
    echo ""
    warn "请确保模型文件已放入 ${VLLM_MODEL_HOST_PATH}（含 config.json 等权重文件）"
  fi
  warn "生产环境请修改脚本顶部的默认密码与 Token！"
}

main "$@"
