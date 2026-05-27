#!/usr/bin/env bash
#
# New API Kubernetes 清理脚本
#
# 用法:
#   ./cleanup.sh              删除 K8s 资源（保留本机 hostPath 数据）
#   ./cleanup.sh --purge-data  同时删除本机数据目录
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 与 deploy.sh 保持一致
NAMESPACE="new-api"
DATA_HOST_PATH="/data"
PG_DATA_HOST_PATH="/data/pgdata"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

PURGE_DATA=0
if [[ "${1:-}" == "--purge-data" ]]; then
  PURGE_DATA=1
elif [[ -n "${1:-}" ]]; then
  error "未知参数: $1（可用: --purge-data）"
  exit 1
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "缺少命令: $1"
    exit 1
  fi
}

confirm() {
  local prompt="$1"
  read -r -p "${prompt} [y/N] " answer
  [[ "${answer}" == "y" || "${answer}" == "Y" ]]
}

delete_k8s_resources() {
  if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    warn "命名空间 ${NAMESPACE} 不存在，跳过 K8s 清理"
    return
  fi

  info "[1/3] 删除 New API..."
  kubectl -n "${NAMESPACE}" delete deployment new-api --ignore-not-found --wait=true --timeout=120s
  kubectl -n "${NAMESPACE}" delete service new-api --ignore-not-found
  kubectl -n "${NAMESPACE}" delete pvc new-api-data --ignore-not-found

  info "[2/3] 删除 Redis..."
  kubectl -n "${NAMESPACE}" delete deployment redis --ignore-not-found --wait=true --timeout=120s
  kubectl -n "${NAMESPACE}" delete service redis --ignore-not-found

  info "[3/3] 删除 PostgreSQL..."
  kubectl -n "${NAMESPACE}" delete statefulset postgres --ignore-not-found --wait=true --timeout=120s
  kubectl -n "${NAMESPACE}" delete service postgres --ignore-not-found

  info "删除 ConfigMap / Secret..."
  kubectl -n "${NAMESPACE}" delete configmap new-api-config --ignore-not-found
  kubectl -n "${NAMESPACE}" delete secret new-api-secrets --ignore-not-found

  info "删除命名空间 ${NAMESPACE}..."
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found --wait=true --timeout=120s
}

purge_local_data() {
  info "删除本机数据目录..."
  for dir in "${DATA_HOST_PATH}" "${PG_DATA_HOST_PATH}"; do
    if [[ -d "${dir}" ]]; then
      info "  rm -rf ${dir}"
      rm -rf "${dir}"
    else
      warn "  目录不存在，跳过: ${dir}"
    fi
  done
}

main() {
  require_cmd kubectl

  warn "即将清理命名空间: ${NAMESPACE}"
  if [[ "${PURGE_DATA}" == "1" ]]; then
    warn "将同时删除本机目录: ${DATA_HOST_PATH} ${PG_DATA_HOST_PATH}"
  else
    info "本机 hostPath 数据将保留（如需删除请加 --purge-data）"
  fi

  if ! confirm "确认继续?"; then
    info "已取消"
    exit 0
  fi

  delete_k8s_resources

  if [[ "${PURGE_DATA}" == "1" ]]; then
    purge_local_data
  fi

  info "清理完成"
}

main "$@"
