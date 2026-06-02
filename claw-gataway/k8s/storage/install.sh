#!/usr/bin/env bash
#
# SeaweedFS S3 存储一键安装（systemd + Docker，宿主机部署，与 K8s/vLLM 无关）
#
# 用法:
#   sudo ./install.sh              # 使用 config.sh 中的配置安装
#   sudo STORAGE_NODE_IP=10.x.x.x ./install.sh
#
# 多节点: 在每台存储节点上分别执行，设置各自的 STORAGE_NODE_IP 与 STORAGE_COMPONENTS
#
set -euo pipefail

STORAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${STORAGE_DIR}/config.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    error "请使用 root 执行: sudo $0"
    exit 1
  fi
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "缺少命令: $1"
    exit 1
  fi
}

component_enabled() {
  local name="$1"
  [[ ",${STORAGE_COMPONENTS}," == *",${name},"* ]]
}

grpc_port() {
  echo $(( $1 + 10000 ))
}

MASTER_GRPC_PORT="$(grpc_port "${STORAGE_MASTER_PORT}")"
VOLUME_GRPC_PORT="$(grpc_port "${STORAGE_VOLUME_PORT}")"
FILER_GRPC_PORT="$(grpc_port "${STORAGE_FILER_PORT}")"
S3_GRPC_PORT="$(grpc_port "${STORAGE_S3_PORT}")"

redis_addrs_json() {
  local IFS=,
  local out=""
  for addr in ${STORAGE_REDIS_SENTINEL_ADDRS}; do
    addr="$(echo "${addr}" | xargs)"
    [[ -z "${addr}" ]] && continue
    if [[ -n "${out}" ]]; then
      out+=", "
    fi
    out+="\"${addr}\""
  done
  echo "[${out}]"
}

render_file() {
  local src="$1"
  local dst="$2"
  local content
  content="$(cat "${src}")"
  content="${content//__STORAGE_DATA_ROOT__/${STORAGE_DATA_ROOT}}"
  content="${content//__NODE_IP__/${STORAGE_NODE_IP}}"
  content="${content//__MASTER_PEERS__/${STORAGE_MASTER_PEERS}}"
  content="${content//__SEAWEEDFS_IMAGE__/${STORAGE_SEAWEEDFS_IMAGE}}"
  content="${content//__WRAPPER_IMAGE__/${STORAGE_WRAPPER_IMAGE}}"
  content="${content//__MASTER_PORT__/${STORAGE_MASTER_PORT}}"
  content="${content//__MASTER_GRPC_PORT__/${MASTER_GRPC_PORT}}"
  content="${content//__VOLUME_PORT__/${STORAGE_VOLUME_PORT}}"
  content="${content//__VOLUME_GRPC_PORT__/${VOLUME_GRPC_PORT}}"
  content="${content//__FILER_PORT__/${STORAGE_FILER_PORT}}"
  content="${content//__FILER_GRPC_PORT__/${FILER_GRPC_PORT}}"
  content="${content//__S3_PORT__/${STORAGE_S3_PORT}}"
  content="${content//__S3_GRPC_PORT__/${S3_GRPC_PORT}}"
  content="${content//__WRAPPER_PORT__/${STORAGE_WRAPPER_PORT}}"
  content="${content//__VOLUME_MAX__/${STORAGE_VOLUME_MAX}}"
  content="${content//__VOLUME_DATA_CENTER__/${STORAGE_VOLUME_DATA_CENTER}}"
  content="${content//__VOLUME_RACK__/${STORAGE_VOLUME_RACK}}"
  content="${content//__VOLUME_SIZE_LIMIT_MB__/${STORAGE_VOLUME_SIZE_LIMIT_MB}}"
  content="${content//__DEFAULT_REPLICATION__/${STORAGE_DEFAULT_REPLICATION}}"
  content="${content//__JWT_FILER_KEY__/${STORAGE_JWT_FILER_KEY}}"
  content="${content//__WRAPPER_SECRET_KEY__/${STORAGE_WRAPPER_SECRET_KEY}}"
  content="${content//__S3_ACCESS_KEY__/${STORAGE_S3_ACCESS_KEY}}"
  content="${content//__S3_SECRET_KEY__/${STORAGE_S3_SECRET_KEY}}"
  content="${content//__REDIS_SENTINEL_MASTER__/${STORAGE_REDIS_SENTINEL_MASTER}}"
  content="${content//__REDIS_PASSWORD__/${STORAGE_REDIS_PASSWORD}}"
  content="${content//__REDIS_SENTINEL_ADDRS_JSON__/$(redis_addrs_json)}"
  printf '%s\n' "${content}" > "${dst}"
}

create_directories() {
  local base="${STORAGE_DATA_ROOT}"
  info "创建数据目录: ${base}"
  mkdir -p \
    "${base}/data/master" \
    "${base}/data/conf" \
    "${base}/data/cert" \
    "${base}/data/volume" \
    "${base}/data/filerldb2" \
    "${base}/log/master" \
    "${base}/log/volume" \
    "${base}/log/filer" \
    "${base}/log/s3"
}

install_configs() {
  local conf="${STORAGE_DATA_ROOT}/data/conf"
  info "生成配置文件 -> ${conf}"
  render_file "${STORAGE_DIR}/templates/filer.toml" "${conf}/filer.toml"
  render_file "${STORAGE_DIR}/templates/security.toml" "${conf}/security.toml"
  render_file "${STORAGE_DIR}/templates/config.json" "${conf}/config.json"

  if [[ ! -f "${STORAGE_DATA_ROOT}/data/cert/ca.crt" ]]; then
    warn "未检测到 TLS 证书 (${STORAGE_DATA_ROOT}/data/cert/)，请放置 ca.crt / server.crt / server.key"
  fi
}

install_systemd_unit() {
  local name="$1"
  local src="${STORAGE_DIR}/templates/systemd/${name}.service"
  local dst="/lib/systemd/system/${name}.service"
  if [[ ! -f "${src}" ]]; then
    error "缺少模板: ${src}"
    exit 1
  fi
  info "安装 systemd 单元: ${dst}"
  render_file "${src}" "${dst}"
}

start_component() {
  local unit="$1"
  info "启动 ${unit}..."
  systemctl daemon-reload
  systemctl enable "${unit}"
  systemctl restart "${unit}"
  sleep 2
  if ! systemctl is-active --quiet "${unit}"; then
    error "${unit} 启动失败，查看: journalctl -u ${unit} -n 50 --no-pager"
    exit 1
  fi
  info "${unit} 运行中"
}

pull_images() {
  info "拉取镜像..."
  docker pull "${STORAGE_SEAWEEDFS_IMAGE}"
  if component_enabled wrapper; then
    docker pull "${STORAGE_WRAPPER_IMAGE}"
  fi
}

print_usage() {
  local s3_endpoint="http://${STORAGE_NODE_IP}:${STORAGE_S3_PORT}"
  local wrapper_endpoint="http://${STORAGE_NODE_IP}:${STORAGE_WRAPPER_PORT}"
  echo ""
  info "SeaweedFS 存储安装完成！"
  echo ""
  echo "  本节点 IP:       ${STORAGE_NODE_IP}"
  echo "  数据目录:        ${STORAGE_DATA_ROOT}"
  echo "  已安装组件:      ${STORAGE_COMPONENTS}"
  echo "  Master peers:    ${STORAGE_MASTER_PEERS}"
  echo ""
  if component_enabled s3; then
    echo "  S3 API 端点:     ${s3_endpoint}"
    echo "  S3 Access Key:   ${STORAGE_S3_ACCESS_KEY}"
    echo "  S3 Secret Key:   ${STORAGE_S3_SECRET_KEY}"
    echo ""
    echo "  AWS CLI 示例:"
    echo "    export AWS_ACCESS_KEY_ID=${STORAGE_S3_ACCESS_KEY}"
    echo "    export AWS_SECRET_ACCESS_KEY=${STORAGE_S3_SECRET_KEY}"
    echo "    aws --endpoint-url ${s3_endpoint} s3 ls"
    echo "    aws --endpoint-url ${s3_endpoint} s3 mb s3://my-bucket"
    echo "    aws --endpoint-url ${s3_endpoint} s3 cp ./file.txt s3://my-bucket/"
    echo ""
    echo "  curl 健康检查 (需 bucket 已存在):"
    echo "    curl -sI \"${s3_endpoint}/my-bucket/\""
  fi
  if component_enabled wrapper; then
    echo ""
    echo "  Wrapper 网关:    ${wrapper_endpoint}"
    echo "  Wrapper Secret:  ${STORAGE_WRAPPER_SECRET_KEY}"
  fi
  if component_enabled filer; then
    echo ""
    echo "  Filer HTTP:      http://${STORAGE_NODE_IP}:${STORAGE_FILER_PORT}/"
    echo "  Filer 配置:      ${STORAGE_DATA_ROOT}/data/conf/filer.toml"
  fi
  echo ""
  echo "  服务管理:"
  echo "    systemctl status s3-master s3-volume s3-filer s3-s3 s3-wrapper"
  echo "    journalctl -u s3-s3 -f"
  echo ""
  echo "  配置文件:        ${STORAGE_DATA_ROOT}/data/conf/"
  echo "  修改配置后:      systemctl restart s3-filer s3-s3"
  echo ""
  warn "存储与 vLLM 独立部署；vLLM 仍使用本地 hostPath 模型目录，请勿改为 S3 挂载。"
  warn "生产环境请修改 config.sh 中的密码、JWT 与 S3 密钥！"
}

main() {
  require_root
  require_cmd docker
  require_cmd systemctl

  info "SeaweedFS 存储安装开始"
  info "节点 IP: ${STORAGE_NODE_IP}"
  info "组件: ${STORAGE_COMPONENTS}"

  create_directories
  install_configs
  pull_images

  if component_enabled master; then
    install_systemd_unit s3-master
    start_component s3-master.service
  fi
  if component_enabled volume; then
    install_systemd_unit s3-volume
    start_component s3-volume.service
  fi
  if component_enabled filer; then
    install_systemd_unit s3-filer
    start_component s3-filer.service
  fi
  if component_enabled s3; then
    install_systemd_unit s3-s3
    start_component s3-s3.service
  fi
  if component_enabled wrapper; then
    install_systemd_unit s3-wrapper
    start_component s3-wrapper.service
  fi

  print_usage
}

main "$@"
