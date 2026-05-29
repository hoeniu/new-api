#!/usr/bin/env bash
#
# 构建/同步镜像并推送到 Lenovo 镜像仓库 (registry-public.lenovo.com/newapi)
#
# 用法:
#   ./build-push.sh          # 推送全部（new-api + postgres + redis）
#   ./build-push.sh app      # 仅构建推送 new-api
#   ./build-push.sh base     # 仅同步推送 postgres + redis
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# =============================================================================
# 镜像配置
# =============================================================================
REGISTRY="registry-public.lenovo.com/newapi"

# New API（本地构建）
LOCAL_APP_IMAGE="new-api:local"
NEW_API_TAG="new-api-v1"
NEW_API_REMOTE="${REGISTRY}/new-api:${NEW_API_TAG}"

# PostgreSQL / Redis（从镜像源 pull 后 re-tag 推送）
POSTGRES_SRC="docker.m.daocloud.io/library/postgres:15"
POSTGRES_REMOTE="${REGISTRY}/postgres:15"

REDIS_SRC="ccr.ccs.tencentyun.com/library/redis:latest"
REDIS_REMOTE="${REGISTRY}/redis:latest"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

docker_cmd() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    sudo docker "$@"
  fi
}

pull_tag_push() {
  local src="$1"
  local dst="$2"
  info "拉取: ${src}"
  docker_cmd pull "${src}"
  info "打标签: ${dst}"
  docker_cmd tag "${src}" "${dst}"
  info "推送: ${dst}"
  docker_cmd push "${dst}"
}

push_base_images() {
  pull_tag_push "${POSTGRES_SRC}" "${POSTGRES_REMOTE}"
  pull_tag_push "${REDIS_SRC}" "${REDIS_REMOTE}"
}

push_app_image() {
  info "项目目录: ${PROJECT_ROOT}"
  info "构建镜像: ${LOCAL_APP_IMAGE}"
  docker_cmd build -t "${LOCAL_APP_IMAGE}" -f "${PROJECT_ROOT}/Dockerfile" "${PROJECT_ROOT}"

  info "打标签: ${NEW_API_REMOTE}"
  docker_cmd tag "${LOCAL_APP_IMAGE}" "${NEW_API_REMOTE}"

  info "推送: ${NEW_API_REMOTE}"
  docker_cmd push "${NEW_API_REMOTE}"
}

print_summary() {
  echo ""
  info "完成！已推送镜像："
  [[ "${PUSH_APP:-0}" == "1" ]] && echo "  ${NEW_API_REMOTE}"
  [[ "${PUSH_BASE:-0}" == "1" ]] && echo "  ${POSTGRES_REMOTE}" && echo "  ${REDIS_REMOTE}"
  echo ""
  echo "  deploy.sh 中对应配置:"
  [[ "${PUSH_APP:-0}" == "1" ]] && echo "    NEW_API_IMAGE=\"${NEW_API_REMOTE}\""
  [[ "${PUSH_BASE:-0}" == "1" ]] && echo "    POSTGRES_IMAGE=\"${POSTGRES_REMOTE}\"" && echo "    REDIS_IMAGE=\"${REDIS_REMOTE}\""
}

main() {
  local mode="${1:-all}"

  case "${mode}" in
    app)
      PUSH_APP=1
      PUSH_BASE=0
      push_app_image
      ;;
    base)
      PUSH_APP=0
      PUSH_BASE=1
      push_base_images
      ;;
    all)
      PUSH_APP=1
      PUSH_BASE=1
      push_base_images
      push_app_image
      ;;
    *)
      error "未知参数: ${mode}（可用: app | base | all）"
      exit 1
      ;;
  esac

  print_summary
}

main "$@"
