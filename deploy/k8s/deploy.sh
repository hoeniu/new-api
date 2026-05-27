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

# New API 镜像（与 docker-compose 默认一致，可按需替换）
NEW_API_IMAGE="registry.cn-qingdao.aliyuncs.com/niuhong/hoeniu:new-api-v1"

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

# 本地数据目录（hostPath 挂载到节点本机，与 docker-compose ./data 一致）
DATA_HOST_PATH="/data"

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

apply_manifest() {
  local file="$1"
  info "Applying ${file}..."
  kubectl apply -f "$file"
}

render_new_api_manifest() {
  sed "s|__NEW_API_IMAGE__|${NEW_API_IMAGE}|g" \
    "${SCRIPT_DIR}/new-api.yaml" \
    | sed "s|nodePort: 30080|nodePort: ${NODE_PORT}|g" \
    | sed "s|__DATA_HOST_PATH__|${DATA_HOST_PATH}|g"
}

main() {
  require_cmd kubectl
  validate_config

  mkdir -p "${DATA_HOST_PATH}"
  info "本地数据目录: ${DATA_HOST_PATH}"

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
  apply_manifest "${SCRIPT_DIR}/postgres.yaml"
  apply_manifest "${SCRIPT_DIR}/redis.yaml"

  info "部署 New API..."
  render_new_api_manifest | kubectl apply -f -

  info "等待 PostgreSQL 就绪..."
  kubectl -n "${NAMESPACE}" rollout status statefulset/postgres --timeout=300s

  info "等待 Redis 就绪..."
  kubectl -n "${NAMESPACE}" rollout status deployment/redis --timeout=180s

  info "等待 New API 就绪..."
  kubectl -n "${NAMESPACE}" rollout status deployment/new-api --timeout=300s

  NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
  if [[ -z "${NODE_IP}" ]]; then
    NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')"
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
  warn "生产环境请修改脚本顶部的默认密码与 Token！"
}

main "$@"
