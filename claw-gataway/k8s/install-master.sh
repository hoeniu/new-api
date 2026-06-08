#!/usr/bin/env bash
#
# New API Kubernetes 一键部署脚本
# 使用前请修改 install.config.sh，然后执行: ./install.sh
#
# 仅安装 SeaweedFS 存储 + CSI（宿主机 systemd + Helm）:
#   sudo ./install.sh storage
# 或在完整部署时设置 DEPLOY_STORAGE=true
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALL_CONFIG="${SCRIPT_DIR}/install.config.sh"
if [[ ! -f "${INSTALL_CONFIG}" ]]; then
  INSTALL_CONFIG="${SCRIPT_DIR}/install-master-config.sh"
fi
if [[ ! -f "${INSTALL_CONFIG}" ]]; then
  echo "[ERROR] 缺少配置文件: install.config.sh 或 install-master-config.sh" >&2
  exit 1
fi
# shellcheck source=install.config.sh
source "${INSTALL_CONFIG}"

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
  if [[ "${DEPLOY_VLLM:-false}" == "true" ]]; then
    if ! [[ "${VLLM_REPLICA_COUNT:-1}" =~ ^[1-9][0-9]*$ ]]; then
      error "VLLM_REPLICA_COUNT 必须是正整数"
      exit 1
    fi
    if ! [[ "${VLLM_GPU_COUNT:-1}" =~ ^[1-9][0-9]*$ ]]; then
      error "VLLM_GPU_COUNT 必须是正整数"
      exit 1
    fi
    if [[ "${VLLM_AUTOSCALING_ENABLED:-false}" == "true" ]]; then
      if ! [[ "${VLLM_AUTOSCALING_MIN_REPLICAS:-1}" =~ ^[1-9][0-9]*$ ]]; then
        error "VLLM_AUTOSCALING_MIN_REPLICAS 必须是正整数"
        exit 1
      fi
      if ! [[ "${VLLM_AUTOSCALING_MAX_REPLICAS:-1}" =~ ^[1-9][0-9]*$ ]]; then
        error "VLLM_AUTOSCALING_MAX_REPLICAS 必须是正整数"
        exit 1
      fi
      if (( VLLM_AUTOSCALING_MAX_REPLICAS < VLLM_AUTOSCALING_MIN_REPLICAS )); then
        error "VLLM_AUTOSCALING_MAX_REPLICAS 不得小于 VLLM_AUTOSCALING_MIN_REPLICAS"
        exit 1
      fi
    fi
  fi
}

calc_total_steps() {
  TOTAL_STEPS=3
  if [[ "${DEPLOY_VLLM}" == "true" ]]; then
    TOTAL_STEPS=4
    if [[ "${AUTO_REGISTER_VLLM}" == "true" ]]; then
      TOTAL_STEPS=5
    fi
  fi
  if [[ "${DEPLOY_STORAGE}" == "true" ]]; then
    TOTAL_STEPS=$((TOTAL_STEPS + 1))
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

  local helm_replica_count="${VLLM_REPLICA_COUNT:-1}"
  local helm_gpu_count="${VLLM_GPU_COUNT:-2}"
  local autoscaling_enabled="${VLLM_AUTOSCALING_ENABLED:-false}"
  local autoscaling_min="${VLLM_AUTOSCALING_MIN_REPLICAS:-1}"
  local autoscaling_max="${VLLM_AUTOSCALING_MAX_REPLICAS:-4}"
  local required_gpus=$(( helm_replica_count * helm_gpu_count ))

  info "[4/${TOTAL_STEPS}] 部署 vLLM 模型 (${VLLM_MODEL_NAME})..."
  mkdir -p "${VLLM_MODEL_HOST_PATH}"
  info "vLLM 模型目录: ${VLLM_MODEL_HOST_PATH}"

  if [[ "${autoscaling_enabled}" == "true" ]]; then
    required_gpus=$(( autoscaling_min * helm_gpu_count ))
    info "vLLM HPA: ${autoscaling_min}-${autoscaling_max} 副本，每 Pod ${helm_gpu_count} GPU"
  else
    info "vLLM 副本: ${helm_replica_count}，每 Pod ${helm_gpu_count} GPU（集群至少需要 ${required_gpus} 张 GPU）"
  fi

  local gpu_enabled="${VLLM_GPU_ENABLED}"
  if [[ "${gpu_enabled}" == "auto" ]]; then
    if kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null \
      | awk -v need="${required_gpus}" '{ s+=$1+0 } END { exit !(s>=need) }'; then
      gpu_enabled="true"
      info "检测到集群 GPU 数量满足 vLLM 需求（≥ ${required_gpus}）"
    else
      gpu_enabled="false"
      warn "集群 GPU 不足 ${required_gpus} 张，vLLM 将以 CPU 模式部署"
    fi
  fi

  local deploy_replicas="${helm_replica_count}"
  if [[ "${autoscaling_enabled}" == "true" ]]; then
    deploy_replicas="${autoscaling_min}"
  fi

  local -a helm_args=(
    upgrade --install "${VLLM_RELEASE_NAME}" "${SCRIPT_DIR}/chart-helm"
    -n "${NAMESPACE}"
    --set "servedModelName=${VLLM_MODEL_NAME}"
    --set "image.repository=${VLLM_IMAGE_REPO}"
    --set "image.tag=${VLLM_IMAGE_TAG}"
    --set "trustRemoteCode=true"
    --set-json "extraArgs=${VLLM_EXTRA_ARGS_JSON}"
    --set "extraInit.storage.hostPath=${VLLM_MODEL_HOST_PATH}"
    --set "gpu.enabled=${gpu_enabled}"
    --set "replicaCount=${deploy_replicas}"
  )

  if [[ "${autoscaling_enabled}" == "true" ]]; then
    helm_args+=(
      --set "autoscaling.enabled=true"
      --set "autoscaling.minReplicas=${autoscaling_min}"
      --set "autoscaling.maxReplicas=${autoscaling_max}"
    )
  else
    helm_args+=(--set "autoscaling.enabled=false")
  fi

  if [[ "${gpu_enabled}" == "true" ]]; then
    helm_args+=(--set "gpu.count=${helm_gpu_count}")
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

  info "[${TOTAL_STEPS}/${TOTAL_STEPS}] 自动注册 vLLM 渠道、Token 与模型定价..."
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
    AUTO_SETUP_MODEL_PRICING="${AUTO_SETUP_MODEL_PRICING}" \
    VLLM_MODEL_RATIO="${VLLM_MODEL_RATIO}" \
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


def get_option_json(key):
    resp = api_request("GET", "/api/option/")
    ensure_success(resp, "get options")
    for item in resp.get("data") or []:
        if item.get("key") == key:
            raw = item.get("value") or "{}"
            try:
                return json.loads(raw) if raw.strip() else {}
            except json.JSONDecodeError:
                return {}
    return {}


def upsert_option_ratio(key, model_name, ratio):
    payload = get_option_json(key)
    payload[model_name] = float(ratio)
    update = api_request("PUT", "/api/option/", {
        "key": key,
        "value": json.dumps(payload, ensure_ascii=False),
    })
    ensure_success(update, f"update option {key}")


channel_name = os.environ["VLLM_CHANNEL_NAME"]
channel_search = api_request("GET", f"/api/channel/search?keyword={channel_name}&page_size=50")
ensure_success(channel_search, "search channel")
channel_items = (channel_search.get("data") or {}).get("items") or []
existing_channel = find_by_name(channel_items, channel_name)

if existing_channel:
    expected_base_url = os.environ["VLLM_CHANNEL_BASE_URL"]
    if existing_channel.get("base_url") != expected_base_url:
        existing_channel["base_url"] = expected_base_url
        existing_channel["models"] = os.environ["VLLM_MODEL_NAME"]
        update_channel = api_request("PUT", "/api/channel/", existing_channel)
        ensure_success(update_channel, "update channel")
        channel_action = "updated"
    else:
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
model_name = os.environ["VLLM_MODEL_NAME"]
token_search = api_request("GET", f"/api/token/search?keyword={token_name}&page_size=50")
ensure_success(token_search, "search token")
token_items = (token_search.get("data") or {}).get("items") or []
existing_token = find_by_name(token_items, token_name)

if existing_token:
    token_id = existing_token["id"]
    if (
        not existing_token.get("model_limits_enabled")
        or existing_token.get("model_limits") != model_name
    ):
        existing_token["model_limits_enabled"] = True
        existing_token["model_limits"] = model_name
        update_token = api_request("PUT", "/api/token/", existing_token)
        ensure_success(update_token, "update token model limits")
        token_action = "updated"
    else:
        token_action = "exists"
else:
    create_token = api_request("POST", "/api/token/", {
        "name": token_name,
        "unlimited_quota": True,
        "expired_time": -1,
        "group": "default",
        "model_limits_enabled": True,
        "model_limits": model_name,
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

pricing_action = "skipped"
model_ratio = os.environ.get("VLLM_MODEL_RATIO", "1")
if os.environ.get("AUTO_SETUP_MODEL_PRICING", "true").lower() == "true":
    upsert_option_ratio("ModelRatio", model_name, model_ratio)
    upsert_option_ratio("CompletionRatio", model_name, model_ratio)
    pricing_action = "configured"

print(json.dumps({
    "channel_action": channel_action,
    "token_action": token_action,
    "pricing_action": pricing_action,
    "model_ratio": model_ratio,
    "api_key": api_key,
}, ensure_ascii=False))
PY
  )"

  GENERATED_API_TOKEN="$(echo "${REGISTER_RESULT}" | python3 -c "import json,sys; print(json.load(sys.stdin)['api_key'])")"
  CHANNEL_ACTION="$(echo "${REGISTER_RESULT}" | python3 -c "import json,sys; print(json.load(sys.stdin)['channel_action'])")"
  TOKEN_ACTION="$(echo "${REGISTER_RESULT}" | python3 -c "import json,sys; print(json.load(sys.stdin)['token_action'])")"
  PRICING_ACTION="$(echo "${REGISTER_RESULT}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('pricing_action','skipped'))")"

  info "渠道「${VLLM_CHANNEL_NAME}」: ${CHANNEL_ACTION}"
  info "令牌「${VLLM_TOKEN_NAME}」: ${TOKEN_ACTION}（模型限制: ${VLLM_MODEL_NAME}）"
  if [[ "${PRICING_ACTION}" == "configured" ]]; then
    info "模型定价: ${VLLM_MODEL_NAME} ModelRatio=${VLLM_MODEL_RATIO} CompletionRatio=${VLLM_MODEL_RATIO}"
  fi
}

resolve_storage_node_ip() {
  if [[ -n "${STORAGE_NODE_IP}" ]]; then
    echo "${STORAGE_NODE_IP}"
    return 0
  fi
  if [[ -n "${NODE_IP:-}" ]]; then
    echo "${NODE_IP}"
    return 0
  fi
  local ip
  ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
  if [[ -z "${ip}" ]]; then
    ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}' 2>/dev/null || true)"
  fi
  if [[ -z "${ip}" ]]; then
    error "无法解析 STORAGE_NODE_IP，请在 install.config.sh 中设置 STORAGE_NODE_IP"
    exit 1
  fi
  echo "${ip}"
}

resolve_seaweedfs_filer() {
  if [[ -n "${SEAWEEDFS_FILER}" ]]; then
    echo "${SEAWEEDFS_FILER}"
    return 0
  fi
  echo "$(resolve_storage_node_ip):${STORAGE_FILER_PORT}"
}

create_csi_tls_secret() {
  local cert_dir="${STORAGE_DATA_ROOT}/data/cert"
  local ca_crt="${cert_dir}/ca.crt"
  local server_crt="${cert_dir}/server.crt"
  local server_key="${cert_dir}/server.key"

  if [[ ! -f "${ca_crt}" || ! -f "${server_crt}" || ! -f "${server_key}" ]]; then
    error "CSI TLS 证书不存在: ${cert_dir}（请先完成宿主机 SeaweedFS 安装）"
    exit 1
  fi

  info "创建/更新 CSI TLS Secret: ${CSI_NAMESPACE}/${CSI_TLS_SECRET_NAME}"
  kubectl -n "${CSI_NAMESPACE}" create secret generic "${CSI_TLS_SECRET_NAME}" \
    --from-file=tls.crt="${server_crt}" \
    --from-file=tls.key="${server_key}" \
    --from-file=ca.crt="${ca_crt}" \
    --dry-run=client -o yaml | kubectl apply -f -
}

deploy_storage_csi() {
  if [[ "${DEPLOY_STORAGE_CSI}" != "true" ]]; then
    info "跳过 SeaweedFS CSI（DEPLOY_STORAGE_CSI=${DEPLOY_STORAGE_CSI}）"
    return 0
  fi

  require_cmd helm
  require_cmd kubectl

  local chart="${SCRIPT_DIR}/storage/helm/seaweedfs-csi-driver"
  if [[ ! -d "${chart}" ]]; then
    error "未找到 CSI Helm chart: ${chart}"
    exit 1
  fi

  local filer
  filer="$(resolve_seaweedfs_filer)"
  info "部署 SeaweedFS CSI Driver（filer=${filer}, StorageClass=${STORAGE_CLASS_NAME}）..."

  if [[ -n "${CSI_TLS_SECRET_NAME}" && "${CSI_SECURITY_ENABLED}" == "true" ]]; then
    create_csi_tls_secret
  fi

  local -a helm_args=(
    upgrade --install "${CSI_RELEASE_NAME}" "${chart}"
    -n "${CSI_NAMESPACE}"
    --create-namespace
    --set "seaweedfsFiler=${filer}"
    --set "storageClassName=${STORAGE_CLASS_NAME}"
    --set "security.enabled=${CSI_SECURITY_ENABLED}"
  )

  if [[ -n "${CSI_TLS_SECRET_NAME}" ]]; then
    helm_args+=(--set "tlsSecret=${CSI_TLS_SECRET_NAME}")
  else
    helm_args+=(--set "tlsSecret=")
  fi

  helm "${helm_args[@]}"

  info "等待 CSI Controller 就绪..."
  kubectl -n "${CSI_NAMESPACE}" rollout status "deployment/${CSI_RELEASE_NAME}-controller" --timeout=300s
  info "等待 CSI Node 就绪..."
  kubectl -n "${CSI_NAMESPACE}" rollout status "daemonset/${CSI_RELEASE_NAME}-node" --timeout=300s
}

deploy_storage_host() {
  local storage_install="${SCRIPT_DIR}/storage/install.sh"
  if [[ ! -f "${storage_install}" ]]; then
    error "未找到存储安装脚本: ${storage_install}"
    exit 1
  fi

  local node_ip
  node_ip="$(resolve_storage_node_ip)"
  info "安装 SeaweedFS 存储（宿主机 ${node_ip}，见 storage/config.sh）..."

  STORAGE_NODE_IP="${node_ip}" \
  STORAGE_DATA_ROOT="${STORAGE_DATA_ROOT}" \
  STORAGE_S3_PORT="${STORAGE_S3_PORT}" \
  STORAGE_S3_ACCESS_KEY="${STORAGE_S3_ACCESS_KEY}" \
  STORAGE_S3_SECRET_KEY="${STORAGE_S3_SECRET_KEY}" \
    bash "${storage_install}"
}

print_storage_summary() {
  local node_ip filer s3_endpoint
  node_ip="$(resolve_storage_node_ip)"
  filer="$(resolve_seaweedfs_filer)"
  s3_endpoint="http://${node_ip}:${STORAGE_S3_PORT}"
  echo "  Filer:           ${filer}"
  echo "  S3 端点:         ${s3_endpoint}"
  echo "  S3 Access Key:   ${STORAGE_S3_ACCESS_KEY}"
  echo "  S3 Secret Key:   ${STORAGE_S3_SECRET_KEY}"
  echo "  StorageClass:    ${STORAGE_CLASS_NAME}"
  if [[ "${DEPLOY_STORAGE_CSI}" == "true" ]]; then
    echo "  CSI Release:     ${CSI_RELEASE_NAME} (${CSI_NAMESPACE})"
  fi
}

deploy_storage() {
  local step_label="${1:-}"
  if [[ -n "${step_label}" ]]; then
    info "[${step_label}] SeaweedFS 宿主机存储 + CSI..."
  fi
  deploy_storage_host
  deploy_storage_csi
}

main() {
  if [[ "${1:-}" == "storage" ]]; then
    require_cmd kubectl
    deploy_storage
    echo ""
    info "SeaweedFS 存储与 CSI 安装完成"
    print_storage_summary
    echo ""
    echo "  AWS CLI 示例:"
    echo "    export AWS_ACCESS_KEY_ID=${STORAGE_S3_ACCESS_KEY}"
    echo "    export AWS_SECRET_ACCESS_KEY=${STORAGE_S3_SECRET_KEY}"
    echo "    aws --endpoint-url http://$(resolve_storage_node_ip):${STORAGE_S3_PORT} s3 ls"
    exit 0
  fi

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

  if [[ "${DEPLOY_STORAGE}" == "true" ]]; then
    deploy_storage "${TOTAL_STEPS}/${TOTAL_STEPS}"
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
    if [[ "${VLLM_AUTOSCALING_ENABLED:-false}" == "true" ]]; then
      echo "  vLLM 副本:    HPA ${VLLM_AUTOSCALING_MIN_REPLICAS:-1}-${VLLM_AUTOSCALING_MAX_REPLICAS:-4} × ${VLLM_GPU_COUNT:-2} GPU/Pod"
    else
      echo "  vLLM 副本:    ${VLLM_REPLICA_COUNT:-1} × ${VLLM_GPU_COUNT:-2} GPU/Pod"
    fi
    if [[ "${AUTO_REGISTER_VLLM}" == "true" && -n "${GENERATED_API_TOKEN:-}" ]]; then
      echo "  API Token:    sk-${GENERATED_API_TOKEN}"
      echo "  模型限制:     ${VLLM_MODEL_NAME}"
      if [[ "${AUTO_SETUP_MODEL_PRICING}" == "true" ]]; then
        echo "  模型倍率:     ${VLLM_MODEL_NAME} = ${VLLM_MODEL_RATIO}"
      fi
      echo ""
      echo "  模型调用示例:"
      echo "    curl -H \"Authorization: Bearer sk-${GENERATED_API_TOKEN}\" \\"
      echo "         -H \"Content-Type: application/json\" \\"
      echo "         -d '{\"model\":\"${VLLM_MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"你好\"}]}' \\"
      echo "         http://${NODE_IP}:${NODE_PORT}/v1/chat/completions"
      if [[ "${AUTO_SETUP_MODEL_PRICING}" == "true" ]]; then
        echo ""
        echo "  手动设置模型倍率示例 (Root):"
        echo "    curl -X PUT -H \"Authorization: ${INIT_WEB_ACCESS_TOKEN}\" \\"
        echo "         -H \"New-Api-User: ${NEW_API_ROOT_USER_ID}\" \\"
        echo "         -H \"Content-Type: application/json\" \\"
        echo "         -d '{\"key\":\"ModelRatio\",\"value\":\"{\\\"${VLLM_MODEL_NAME}\\\":${VLLM_MODEL_RATIO}}\"}' \\"
        echo "         http://${NODE_IP}:${NODE_PORT}/api/option/"
      fi
    fi
    echo ""
    warn "请确保模型文件已放入 ${VLLM_MODEL_HOST_PATH}（含 config.json 等权重文件）"
  fi
  if [[ "${DEPLOY_STORAGE}" == "true" ]]; then
    print_storage_summary
    echo ""
    echo "  动态卷示例:"
    echo "    storageClassName: ${STORAGE_CLASS_NAME}"
  fi
  warn "生产环境请修改 install.config.sh 中的默认密码与 Token！"
}

main "$@"
