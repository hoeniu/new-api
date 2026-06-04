#!/usr/bin/env bash
#
# New API Kubernetes 清理脚本
#
# 用法:
#   ./cleanup.sh                    删除 K8s 资源 + CSI（保留本机 hostPath / SeaweedFS 数据）
#   ./cleanup.sh --purge-data         同时删除 New API / PostgreSQL 本机目录
#   sudo ./cleanup.sh --purge-storage  同时停止宿主机 SeaweedFS（systemd + Docker）
#   sudo ./cleanup.sh storage         仅卸载 CSI + 宿主机 SeaweedFS（不删 new-api 命名空间）
#   可组合: ./cleanup.sh --purge-data --purge-storage
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALL_CONFIG="${SCRIPT_DIR}/install.config.sh"
if [[ ! -f "${INSTALL_CONFIG}" ]]; then
  echo "[ERROR] 缺少配置文件: ${INSTALL_CONFIG}" >&2
  exit 1
fi
# shellcheck source=install.config.sh
source "${INSTALL_CONFIG}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

PURGE_DATA=0
PURGE_STORAGE=0
STORAGE_ONLY=0

parse_args() {
  for arg in "$@"; do
    case "${arg}" in
      --purge-data)
        PURGE_DATA=1
        ;;
      --purge-storage)
        PURGE_STORAGE=1
        ;;
      storage)
        STORAGE_ONLY=1
        PURGE_STORAGE=1
        ;;
      "")
        ;;
      *)
        error "未知参数: ${arg}（可用: --purge-data | --purge-storage | storage）"
        exit 1
        ;;
    esac
  done
}

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

delete_csi() {
  if ! command -v helm >/dev/null 2>&1; then
    warn "未安装 helm，跳过 CSI Helm 卸载"
  elif helm -n "${CSI_NAMESPACE}" status "${CSI_RELEASE_NAME}" >/dev/null 2>&1; then
    info "卸载 SeaweedFS CSI Helm Release (${CSI_NAMESPACE}/${CSI_RELEASE_NAME})..."
    helm -n "${CSI_NAMESPACE}" uninstall "${CSI_RELEASE_NAME}" --wait --timeout=300s
  else
    warn "CSI Release ${CSI_RELEASE_NAME} 不存在，跳过 Helm 卸载"
  fi

  if kubectl -n "${CSI_NAMESPACE}" get secret "${CSI_TLS_SECRET_NAME}" >/dev/null 2>&1; then
    info "删除 CSI TLS Secret (${CSI_NAMESPACE}/${CSI_TLS_SECRET_NAME})..."
    kubectl -n "${CSI_NAMESPACE}" delete secret "${CSI_TLS_SECRET_NAME}" --ignore-not-found
  fi

  if kubectl get storageclass "${STORAGE_CLASS_NAME}" >/dev/null 2>&1; then
    warn "StorageClass ${STORAGE_CLASS_NAME} 仍存在（可能有 PV 未删除），可手动: kubectl delete storageclass ${STORAGE_CLASS_NAME}"
  fi
}

delete_k8s_resources() {
  if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    warn "命名空间 ${NAMESPACE} 不存在，跳过 K8s 应用清理"
    return
  fi

  if command -v helm >/dev/null 2>&1; then
    if helm -n "${NAMESPACE}" status "${VLLM_RELEASE_NAME}" >/dev/null 2>&1; then
      info "卸载 vLLM Helm Release (${VLLM_RELEASE_NAME})..."
      helm -n "${NAMESPACE}" uninstall "${VLLM_RELEASE_NAME}" --wait --timeout=300s
    fi
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

stop_storage_unit() {
  local unit="$1"
  if systemctl list-unit-files "${unit}.service" >/dev/null 2>&1; then
    info "  停止并禁用 ${unit}.service"
    systemctl stop "${unit}.service" 2>/dev/null || true
    systemctl disable "${unit}.service" 2>/dev/null || true
  fi
  if [[ -f "/lib/systemd/system/${unit}.service" ]]; then
    rm -f "/lib/systemd/system/${unit}.service"
  fi
}

delete_storage_host() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    error "删除宿主机 SeaweedFS 需要 root: sudo $0 --purge-storage"
    exit 1
  fi

  require_cmd systemctl
  require_cmd docker

  info "停止宿主机 SeaweedFS 服务..."
  # 逆序停止（wrapper/s3 依赖 filer）
  local -a units=(s3-wrapper s3-s3 s3-filer s3-volume s3-master)
  for unit in "${units[@]}"; do
    stop_storage_unit "${unit}"
  done
  systemctl daemon-reload

  info "删除 SeaweedFS Docker 容器..."
  local -a containers=(s3-wrapper s3-s3 s3-filer s3-volume s3-master)
  for c in "${containers[@]}"; do
    docker rm -f "${c}" >/dev/null 2>&1 || true
  done

  if [[ -d "${STORAGE_DATA_ROOT}" ]]; then
    info "  rm -rf ${STORAGE_DATA_ROOT}"
    rm -rf "${STORAGE_DATA_ROOT}"
  else
    warn "  SeaweedFS 数据目录不存在，跳过: ${STORAGE_DATA_ROOT}"
  fi
}

purge_local_data() {
  info "删除 New API / PostgreSQL 本机数据目录..."
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
  parse_args "$@"
  require_cmd kubectl

  if [[ "${STORAGE_ONLY}" == "1" ]]; then
    warn "即将清理: SeaweedFS CSI + 宿主机存储"
    warn "将删除目录: ${STORAGE_DATA_ROOT}"
  else
    warn "即将清理: 命名空间 ${NAMESPACE} + SeaweedFS CSI"
    if [[ "${PURGE_DATA}" == "1" ]]; then
      warn "将同时删除: ${DATA_HOST_PATH} ${PG_DATA_HOST_PATH}"
    else
      info "New API / PG hostPath 将保留（加 --purge-data 可删除）"
    fi
    if [[ "${PURGE_STORAGE}" == "1" ]]; then
      warn "将同时停止宿主机 SeaweedFS 并删除: ${STORAGE_DATA_ROOT}（需 root）"
    else
      info "宿主机 SeaweedFS 数据将保留（加 --purge-storage 可删除）"
    fi
  fi

  if ! confirm "确认继续?"; then
    info "已取消"
    exit 0
  fi

  if [[ "${STORAGE_ONLY}" == "1" ]]; then
    delete_csi
    delete_storage_host
  else
    delete_k8s_resources
    delete_csi
    if [[ "${PURGE_STORAGE}" == "1" ]]; then
      delete_storage_host
    fi
    if [[ "${PURGE_DATA}" == "1" ]]; then
      purge_local_data
    fi
  fi

  info "清理完成"
}

main "$@"
