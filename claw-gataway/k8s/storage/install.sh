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
  # 容器内进程通常非 root，需保证可写
  chmod -R a+rwx \
    "${base}/log" \
    "${base}/data/master" \
    "${base}/data/filerldb2" \
    "${base}/data/volume"
  # leveldb2 元数据目录（与 filer.toml 中 dir 一致）
  mkdir -p "${base}/data/filerldb2"
  chmod a+rwx "${base}/data/filerldb2"
}

ensure_grpc_certs() {
  local cert_dir="${STORAGE_DATA_ROOT}/data/cert"
  local ca_crt="${cert_dir}/ca.crt"
  local server_crt="${cert_dir}/server.crt"
  local server_key="${cert_dir}/server.key"

  if [[ "${STORAGE_GRPC_TLS_AUTO_CERT}" != "true" ]]; then
    if [[ ! -f "${ca_crt}" || ! -f "${server_crt}" || ! -f "${server_key}" ]]; then
      error "未启用自动生成证书 (STORAGE_GRPC_TLS_AUTO_CERT=false)，请手动放置 ${cert_dir}/ 下的 ca.crt、server.crt、server.key"
      exit 1
    fi
    return 0
  fi

  if [[ "${STORAGE_GRPC_TLS_REGENERATE}" != "true" ]] \
    && [[ -f "${ca_crt}" && -f "${server_crt}" && -f "${server_key}" ]]; then
    info "gRPC TLS 证书已存在: ${cert_dir}"
    return 0
  fi

  require_cmd openssl
  info "生成 gRPC 自签名 TLS 证书 (节点 IP: ${STORAGE_NODE_IP}) -> ${cert_dir}"
  mkdir -p "${cert_dir}"

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN

  openssl genrsa -out "${tmp}/ca.key" 4096 2>/dev/null
  openssl req -new -x509 -days 3650 -key "${tmp}/ca.key" -out "${tmp}/ca.crt" \
    -subj "/CN=SeaweedFS-CA" 2>/dev/null
  openssl genrsa -out "${tmp}/server.key" 2048 2>/dev/null

  local san_idx=1
  local alt_names="IP.${san_idx} = ${STORAGE_NODE_IP}"
  san_idx=$((san_idx + 1))
  alt_names+=$'\n'"IP.${san_idx} = 127.0.0.1"
  san_idx=$((san_idx + 1))
  alt_names+=$'\n'"DNS.1 = localhost"

  local peer ip_host
  IFS=',' read -r -a _peers <<< "${STORAGE_MASTER_PEERS}"
  for peer in "${_peers[@]}"; do
    ip_host="${peer%%:*}"
    ip_host="$(echo "${ip_host}" | xargs)"
    [[ -z "${ip_host}" || "${ip_host}" == "${STORAGE_NODE_IP}" || "${ip_host}" == "127.0.0.1" ]] && continue
    alt_names+=$'\n'"IP.${san_idx} = ${ip_host}"
    san_idx=$((san_idx + 1))
  done

  cat > "${tmp}/server.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = seaweedfs
[v3_req]
subjectAltName = @alt_names
[alt_names]
${alt_names}
EOF

  openssl req -new -key "${tmp}/server.key" -out "${tmp}/server.csr" -config "${tmp}/server.cnf" 2>/dev/null
  openssl x509 -req -in "${tmp}/server.csr" -CA "${tmp}/ca.crt" -CAkey "${tmp}/ca.key" \
    -CAcreateserial -out "${tmp}/server.crt" -days 3650 -extensions v3_req -extfile "${tmp}/server.cnf" 2>/dev/null

  install -m 0644 "${tmp}/ca.crt" "${ca_crt}"
  install -m 0644 "${tmp}/server.crt" "${server_crt}"
  install -m 0600 "${tmp}/server.key" "${server_key}"
  chmod -R a+rX "${cert_dir}"

  info "gRPC TLS 证书已生成（含 SAN: ${STORAGE_NODE_IP}, 127.0.0.1）"
}

install_configs() {
  local conf="${STORAGE_DATA_ROOT}/data/conf"
  ensure_grpc_certs
  info "生成配置文件 -> ${conf}"
  render_file "${STORAGE_DIR}/templates/filer.toml" "${conf}/filer.toml"
  render_file "${STORAGE_DIR}/templates/security.toml" "${conf}/security.toml"
  render_file "${STORAGE_DIR}/templates/config.json" "${conf}/config.json"
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
