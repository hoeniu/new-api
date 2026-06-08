#!/usr/bin/env bash
#
# Worker 节点一键部署：
#   1. 交互式输入 Master 节点 IP 与 SSH 密码
#   2. 本机 Docker 部署 SeaweedFS Volume（:7201，连接 Master :7200）
#   3. SSH 到 Master 执行 kubectl / helm 部署 vLLM（调度到本 Worker）
#
# 用法:
#   ./install-worker.sh              # 完整部署（Volume + vLLM）
#   sudo ./install-worker.sh volume  # 仅安装本机 Volume
#   ./install-worker.sh vllm         # 仅远程部署 vLLM（需已交互输入 Master 信息）
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORKER_CONFIG="${SCRIPT_DIR}/install-worker-config.sh"
if [[ ! -f "${WORKER_CONFIG}" ]]; then
  echo "[ERROR] 缺少配置文件: ${WORKER_CONFIG}" >&2
  exit 1
fi
# shellcheck source=install-worker-config.sh
source "${WORKER_CONFIG}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

VOLUME_ONLY=0
VLLM_ONLY=0
WORKER_K8S_NODE_NAME=""
MASTER_STORAGE_PEERS=""
REMOTE_CHART_DIR=""

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "缺少命令: $1"
    exit 1
  fi
}

validate_vllm_config() {
  if [[ "${DEPLOY_VLLM:-false}" != "true" ]]; then
    return 0
  fi
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
}

parse_args() {
  case "${1:-}" in
    volume)
      VOLUME_ONLY=1
      ;;
    vllm)
      VLLM_ONLY=1
      ;;
    ""|"install"|"all")
      ;;
    *)
      error "未知参数: $1（可用: volume | vllm）"
      exit 1
      ;;
  esac
}

prompt_master_credentials() {
  if [[ -z "${MASTER_HOST:-}" ]]; then
    read -r -p "Master 节点 IP: " MASTER_HOST
    if [[ -z "${MASTER_HOST}" ]]; then
      error "Master IP 不能为空"
      exit 1
    fi
  fi

  if [[ -z "${MASTER_SSH_PASSWORD:-}" ]]; then
    read -r -s -p "Master SSH 密码 (${MASTER_SSH_USER}@${MASTER_HOST}): " MASTER_SSH_PASSWORD
    echo ""
    if [[ -z "${MASTER_SSH_PASSWORD}" ]]; then
      error "SSH 密码不能为空"
      exit 1
    fi
  fi

  MASTER_STORAGE_PEERS="${MASTER_HOST}:${STORAGE_MASTER_PORT}"
  info "Master: ${MASTER_SSH_USER}@${MASTER_HOST}:${MASTER_SSH_PORT}"
  info "SeaweedFS Master peers: ${MASTER_STORAGE_PEERS}"
}

ssh_exec() {
  sshpass -p "${MASTER_SSH_PASSWORD}" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -p "${MASTER_SSH_PORT}" \
    "${MASTER_SSH_USER}@${MASTER_HOST}" "$@"
}

scp_from_master() {
  local remote_path="$1"
  local local_path="$2"
  sshpass -p "${MASTER_SSH_PASSWORD}" scp \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -P "${MASTER_SSH_PORT}" \
    "${MASTER_SSH_USER}@${MASTER_HOST}:${remote_path}" "${local_path}"
}

resolve_worker_ip() {
  if [[ -n "${WORKER_NODE_IP}" ]]; then
    echo "${WORKER_NODE_IP}"
    return 0
  fi
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  if [[ -z "${ip}" ]]; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' || true)"
  fi
  if [[ -z "${ip}" ]]; then
    error "无法自动检测 Worker IP，请在 install-worker-config.sh 设置 WORKER_NODE_IP"
    exit 1
  fi
  echo "${ip}"
}

resolve_worker_k8s_node() {
  local worker_ip="$1"
  local node_name
  node_name="$(ssh_exec "kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{\"\\t\"}{range .status.addresses[*]}{.address}{\",\"}{end}{\"\\n\"}{end}'" \
    | awk -F'\t' -v ip="${worker_ip}" '$2 ~ ip { print $1; exit }')"
  if [[ -z "${node_name}" ]]; then
    node_name="$(ssh_exec "kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{\"\\t\"}{.status.addresses[?(@.type==\"InternalIP\")].address}{\"\\n\"}{end}'" \
      | awk -v ip="${worker_ip}" '$2 == ip { print $1; exit }')"
  fi
  if [[ -z "${node_name}" ]]; then
    error "在集群中未找到 IP=${worker_ip} 的节点，请确认 Worker 已加入 Master 集群"
    exit 1
  fi
  echo "${node_name}"
}

verify_master_cluster() {
  require_cmd sshpass
  info "验证 Master SSH 与 kubectl..."
  if ! ssh_exec "command -v kubectl >/dev/null 2>&1"; then
    error "Master 上未找到 kubectl"
    exit 1
  fi
  if ! ssh_exec "kubectl get namespace '${NAMESPACE}' >/dev/null 2>&1"; then
    error "Master 集群中不存在命名空间 ${NAMESPACE}，请先执行 install-master.sh"
    exit 1
  fi
  if [[ "${DEPLOY_VLLM}" == "true" && "${VOLUME_ONLY}" != "1" ]]; then
    if ! ssh_exec "command -v helm >/dev/null 2>&1"; then
      error "Master 上未找到 helm（部署 vLLM 需要）"
      exit 1
    fi
  fi
  info "Master 集群连接正常"
}

sync_grpc_certs_from_master() {
  local cert_dir="${STORAGE_DATA_ROOT}/data/cert"
  info "从 Master 同步 gRPC TLS 证书 -> ${cert_dir}"
  mkdir -p "${cert_dir}"
  for f in ca.crt server.crt server.key; do
    if ! scp_from_master "${MASTER_STORAGE_DATA_ROOT}/data/cert/${f}" "${cert_dir}/${f}"; then
      error "无法从 Master 复制 ${f}，请确认 install-master.sh 已部署存储且路径为 ${MASTER_STORAGE_DATA_ROOT}"
      exit 1
    fi
  done
  chmod -R a+rX "${cert_dir}"
  info "TLS 证书同步完成"
}

deploy_worker_volume() {
  if [[ "${DEPLOY_VOLUME}" != "true" ]]; then
    info "跳过 Volume 部署（DEPLOY_VOLUME=${DEPLOY_VOLUME}）"
    return 0
  fi

  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    error "部署 SeaweedFS Volume 需要 root: sudo $0"
    exit 1
  fi

  local worker_ip storage_install
  worker_ip="$(resolve_worker_ip)"
  storage_install="${SCRIPT_DIR}/storage/install.sh"
  if [[ ! -f "${storage_install}" ]]; then
    error "未找到存储安装脚本: ${storage_install}"
    exit 1
  fi

  sync_grpc_certs_from_master

  info "在本机部署 SeaweedFS Volume（:${STORAGE_VOLUME_PORT} -> Master ${MASTER_STORAGE_PEERS}）..."
  STORAGE_NODE_IP="${worker_ip}" \
  STORAGE_MASTER_PEERS="${MASTER_STORAGE_PEERS}" \
  STORAGE_DATA_ROOT="${STORAGE_DATA_ROOT}" \
  STORAGE_COMPONENTS="volume" \
  STORAGE_SEAWEEDFS_IMAGE="${STORAGE_SEAWEEDFS_IMAGE}" \
  STORAGE_VOLUME_MAX="${STORAGE_VOLUME_MAX}" \
  STORAGE_VOLUME_DATA_CENTER="${STORAGE_VOLUME_DATA_CENTER}" \
  STORAGE_VOLUME_RACK="${STORAGE_VOLUME_RACK}" \
  STORAGE_GRPC_TLS_AUTO_CERT="false" \
  STORAGE_GRPC_TLS_REGENERATE="false" \
    bash "${storage_install}"

  info "Volume 部署完成（本机 ${worker_ip}:${STORAGE_VOLUME_PORT}）"
}

sync_chart_to_master() {
  REMOTE_CHART_DIR="/tmp/claw-worker-${VLLM_RELEASE_NAME}-$$"
  info "同步 Helm Chart 到 Master: ${REMOTE_CHART_DIR}"
  ssh_exec "mkdir -p '${REMOTE_CHART_DIR}'"
  tar -C "${SCRIPT_DIR}" -czf - chart-helm | ssh_exec "tar -xzf - -C '${REMOTE_CHART_DIR}'"
}

deploy_vllm_on_master() {
  if [[ "${DEPLOY_VLLM}" != "true" ]]; then
    info "跳过 vLLM 部署（DEPLOY_VLLM=${DEPLOY_VLLM}）"
    return 0
  fi

  require_cmd sshpass

  local worker_ip gpu_enabled helm_gpu_count helm_replica_count required_gpus
  local autoscaling_enabled autoscaling_min autoscaling_max deploy_replicas
  worker_ip="$(resolve_worker_ip)"
  WORKER_K8S_NODE_NAME="$(resolve_worker_k8s_node "${worker_ip}")"
  sync_chart_to_master

  helm_replica_count="${VLLM_REPLICA_COUNT:-1}"
  helm_gpu_count="${VLLM_GPU_COUNT:-2}"
  autoscaling_enabled="${VLLM_AUTOSCALING_ENABLED:-false}"
  autoscaling_min="${VLLM_AUTOSCALING_MIN_REPLICAS:-1}"
  autoscaling_max="${VLLM_AUTOSCALING_MAX_REPLICAS:-4}"
  required_gpus=$(( helm_replica_count * helm_gpu_count ))
  deploy_replicas="${helm_replica_count}"
  if [[ "${autoscaling_enabled}" == "true" ]]; then
    required_gpus=$(( autoscaling_min * helm_gpu_count ))
    deploy_replicas="${autoscaling_min}"
    info "vLLM HPA: ${autoscaling_min}-${autoscaling_max} 副本，每 Pod ${helm_gpu_count} GPU"
  else
    info "vLLM 副本: ${helm_replica_count}，每 Pod ${helm_gpu_count} GPU（本节点至少需要 ${required_gpus} 张 GPU）"
  fi

  info "Worker K8s 节点: ${WORKER_K8S_NODE_NAME} (${worker_ip})"
  info "模型目录（hostPath）: ${VLLM_MODEL_HOST_PATH}"
  mkdir -p "${VLLM_MODEL_HOST_PATH}"

  gpu_enabled="${VLLM_GPU_ENABLED}"
  if [[ "${gpu_enabled}" == "auto" ]]; then
    if ssh_exec "kubectl get nodes '${WORKER_K8S_NODE_NAME}' -o jsonpath='{.status.allocatable.nvidia\\.com/gpu}'" \
      | awk -v need="${required_gpus}" '$1+0 >= need { ok=1 } END { exit !ok }'; then
      gpu_enabled="true"
      info "Worker 节点 GPU 可用（≥ ${required_gpus} 张）"
    else
      gpu_enabled="false"
      warn "Worker 节点 GPU 不足 ${required_gpus} 张，vLLM 将以 CPU 模式部署"
    fi
  fi

  info "在 Master 上部署 vLLM Helm Release: ${VLLM_RELEASE_NAME}..."
  ssh_exec "bash -s" <<REMOTE_EOF
set -euo pipefail
NAMESPACE='${NAMESPACE}'
VLLM_RELEASE_NAME='${VLLM_RELEASE_NAME}'
VLLM_MODEL_NAME='${VLLM_MODEL_NAME}'
VLLM_MODEL_HOST_PATH='${VLLM_MODEL_HOST_PATH}'
VLLM_IMAGE_REPO='${VLLM_IMAGE_REPO}'
VLLM_IMAGE_TAG='${VLLM_IMAGE_TAG}'
VLLM_EXTRA_ARGS_JSON='${VLLM_EXTRA_ARGS_JSON}'
VLLM_GPU_RUNTIME_CLASS='${VLLM_GPU_RUNTIME_CLASS}'
WORKER_K8S_NODE_NAME='${WORKER_K8S_NODE_NAME}'
REMOTE_CHART='${REMOTE_CHART_DIR}/chart-helm'
GPU_ENABLED='${gpu_enabled}'
GPU_COUNT='${helm_gpu_count}'
REPLICA_COUNT='${deploy_replicas}'
AUTOSCALING_ENABLED='${autoscaling_enabled}'
AUTOSCALING_MIN='${autoscaling_min}'
AUTOSCALING_MAX='${autoscaling_max}'

helm_args=(
  upgrade --install "\${VLLM_RELEASE_NAME}" "\${REMOTE_CHART}"
  -n "\${NAMESPACE}"
  --set "servedModelName=\${VLLM_MODEL_NAME}"
  --set "image.repository=\${VLLM_IMAGE_REPO}"
  --set "image.tag=\${VLLM_IMAGE_TAG}"
  --set "trustRemoteCode=true"
  --set-json "extraArgs=\${VLLM_EXTRA_ARGS_JSON}"
  --set "extraInit.storage.hostPath=\${VLLM_MODEL_HOST_PATH}"
  --set "gpu.enabled=\${GPU_ENABLED}"
  --set "replicaCount=\${REPLICA_COUNT}"
  --set-json "nodeSelector={\"kubernetes.io/hostname\":\"\${WORKER_K8S_NODE_NAME}\"}"
)

if [[ "\${AUTOSCALING_ENABLED}" == "true" ]]; then
  helm_args+=(
    --set "autoscaling.enabled=true"
    --set "autoscaling.minReplicas=\${AUTOSCALING_MIN}"
    --set "autoscaling.maxReplicas=\${AUTOSCALING_MAX}"
  )
else
  helm_args+=(--set "autoscaling.enabled=false")
fi

if [[ "\${GPU_ENABLED}" == "true" ]]; then
  helm_args+=(--set "gpu.count=\${GPU_COUNT}")
  if [[ -n "\${VLLM_GPU_RUNTIME_CLASS}" ]]; then
    helm_args+=(--set "gpu.runtimeClassName=\${VLLM_GPU_RUNTIME_CLASS}")
  fi
else
  helm_args+=(
    --set "resources.requests.cpu=2"
    --set "resources.limits.cpu=4"
    --set "resources.requests.memory=8Gi"
    --set "resources.limits.memory=16Gi"
  )
fi

helm "\${helm_args[@]}"

echo "等待 vLLM Pod 就绪（模型加载可能较久）..."
kubectl -n "\${NAMESPACE}" rollout status "deployment/\${VLLM_RELEASE_NAME}-deployment-vllm" --timeout=1200s

rm -rf "\${REMOTE_CHART%/*}"
REMOTE_EOF

  info "vLLM 部署完成: ${VLLM_RELEASE_NAME} @ ${WORKER_K8S_NODE_NAME}"
}

wait_new_api_api() {
  local attempt
  for attempt in $(seq 1 30); do
    if curl -sf "http://${MASTER_HOST}:${NODE_PORT}/api/status" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  error "New API 未就绪: http://${MASTER_HOST}:${NODE_PORT}/api/status"
  exit 1
}

register_vllm_in_new_api() {
  if [[ "${AUTO_REGISTER_VLLM}" != "true" ]]; then
    return 0
  fi

  require_cmd curl
  require_cmd python3

  info "向 Master New API 注册 vLLM 渠道与 Token..."
  wait_new_api_api

  REGISTER_RESULT="$(
    REGISTER_NODE_IP="${MASTER_HOST}" \
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

  info "渠道「${VLLM_CHANNEL_NAME}」: ${CHANNEL_ACTION}"
  info "令牌「${VLLM_TOKEN_NAME}」: ${TOKEN_ACTION}（模型限制: ${VLLM_MODEL_NAME}）"
}

print_summary() {
  local worker_ip="${1:-$(resolve_worker_ip)}"
  echo ""
  info "Worker 部署完成！"
  echo ""
  echo "  Master:          ${MASTER_HOST}"
  echo "  Worker IP:       ${worker_ip}"
  if [[ -n "${WORKER_K8S_NODE_NAME}" ]]; then
    echo "  K8s 节点:        ${WORKER_K8S_NODE_NAME}"
  fi
  if [[ "${DEPLOY_VOLUME}" == "true" && "${VLLM_ONLY}" != "1" ]]; then
    echo "  SeaweedFS Volume: ${worker_ip}:${STORAGE_VOLUME_PORT} -> ${MASTER_STORAGE_PEERS}"
    echo "  Volume 服务:     systemctl status s3-volume"
  fi
  if [[ "${DEPLOY_VLLM}" == "true" && "${VOLUME_ONLY}" != "1" ]]; then
    echo "  vLLM Release:    ${VLLM_RELEASE_NAME} (${NAMESPACE})"
    echo "  vLLM 模型:       ${VLLM_MODEL_NAME}"
    echo "  模型目录:        ${VLLM_MODEL_HOST_PATH}"
    if [[ "${VLLM_AUTOSCALING_ENABLED:-false}" == "true" ]]; then
      echo "  vLLM 副本:       HPA ${VLLM_AUTOSCALING_MIN_REPLICAS:-1}-${VLLM_AUTOSCALING_MAX_REPLICAS:-4} × ${VLLM_GPU_COUNT:-2} GPU/Pod"
    else
      echo "  vLLM 副本:       ${VLLM_REPLICA_COUNT:-1} × ${VLLM_GPU_COUNT:-2} GPU/Pod"
    fi
    echo "  集群内 Service:  http://${VLLM_RELEASE_NAME}-service.${NAMESPACE}.svc.cluster.local"
    if [[ "${AUTO_REGISTER_VLLM}" == "true" && -n "${GENERATED_API_TOKEN:-}" ]]; then
      echo ""
      echo "  New API 网关:    http://${MASTER_HOST}:${NODE_PORT}"
      echo "  API Token:       sk-${GENERATED_API_TOKEN}"
      echo ""
      echo "  模型调用示例:"
      echo "    curl -H \"Authorization: Bearer sk-${GENERATED_API_TOKEN}\" \\"
      echo "         -H \"Content-Type: application/json\" \\"
      echo "         -d '{\"model\":\"${VLLM_MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"你好\"}]}' \\"
      echo "         http://${MASTER_HOST}:${NODE_PORT}/v1/chat/completions"
    fi
    warn "请确保模型文件已放入 ${VLLM_MODEL_HOST_PATH}"
  fi
}

main() {
  parse_args "${1:-}"

  if [[ "${VOLUME_ONLY}" == "1" ]]; then
    prompt_master_credentials
    deploy_worker_volume
    print_summary "$(resolve_worker_ip)"
    exit 0
  fi

  prompt_master_credentials
  verify_master_cluster

  if [[ "${VLLM_ONLY}" == "1" ]]; then
    validate_vllm_config
    deploy_vllm_on_master
    if [[ "${AUTO_REGISTER_VLLM}" == "true" ]]; then
      register_vllm_in_new_api
    fi
    print_summary "$(resolve_worker_ip)"
    exit 0
  fi

  deploy_worker_volume
  validate_vllm_config
  deploy_vllm_on_master
  if [[ "${AUTO_REGISTER_VLLM}" == "true" ]]; then
    register_vllm_in_new_api
  fi
  print_summary "$(resolve_worker_ip)"
}

main "$@"
