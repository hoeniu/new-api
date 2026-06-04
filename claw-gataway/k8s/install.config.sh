#!/usr/bin/env bash
# New API K8s 部署配置 — 部署前请修改本文件
# 由 install.sh / cleanup.sh 加载，一般无需直接执行

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
VLLM_MODEL_NAME="Qwen3.5-35B-A3B-FP8"
VLLM_MODEL_HOST_PATH="/data/models/${VLLM_MODEL_NAME}"
# vLLM 镜像（Qwen3.5 MoE 架构 qwen3_5_moe 需 vLLM >= 0.17.1，推荐 v0.19.0）
VLLM_IMAGE_REPO="registry-public.lenovo.com/newapi/new-api"
VLLM_IMAGE_TAG="vllmopenai0.22"
# 额外启动参数（JSON 数组，每项为一个 CLI 参数）
VLLM_EXTRA_ARGS_JSON='["--tensor-parallel-size","2","--enable-expert-parallel","--language-model-only","--reasoning-parser","qwen3","--max-model-len","8192","--gpu-memory-utilization","0.90"]'
# GPU: auto | true | false
VLLM_GPU_ENABLED="auto"
# 仅当集群已创建 RuntimeClass 时填写（kubectl get runtimeclass）
VLLM_GPU_RUNTIME_CLASS=""

# vLLM 自动注册到 New API（渠道 + API Token）
AUTO_REGISTER_VLLM="true"
VLLM_CHANNEL_NAME="vllm"
VLLM_CHANNEL_BASE_URL="http://vllm-service.new-api.svc.cluster.local"
VLLM_CHANNEL_KEY="vllm"
VLLM_TOKEN_NAME="auto-vllm"
NEW_API_ROOT_USER_ID="1"
# 自动设置模型倍率（ModelRatio / CompletionRatio，默认均为 1）
AUTO_SETUP_MODEL_PRICING="true"
VLLM_MODEL_RATIO="1"

# SeaweedFS S3 存储（宿主机 Docker+systemd）+ CSI Helm（动态 PV）
# S3 密钥与节点 IP 在此配置；其余见 storage/config.sh。仅存储+CSI: sudo ./install.sh storage
DEPLOY_STORAGE="true"
# SeaweedFS 节点 IP（Filer 地址）；留空则使用 K8s 首节点 InternalIP
STORAGE_NODE_IP="192.168.137.114"
STORAGE_DATA_ROOT="/data/server/s3"
STORAGE_FILER_PORT="7202"
STORAGE_S3_PORT="7203"
# S3 访问密钥（写入 storage/config.json）
STORAGE_S3_ACCESS_KEY="admin"
STORAGE_S3_SECRET_KEY="ChangeMeS3SecretKey"
# Filer host:port（留空则 ${STORAGE_NODE_IP}:${STORAGE_FILER_PORT}）
SEAWEEDFS_FILER=""
STORAGE_CLASS_NAME="seaweedfs-storage"
# CSI Helm（集群内动态卷，依赖上方宿主机 Filer 已就绪）
DEPLOY_STORAGE_CSI="true"
CSI_RELEASE_NAME="seaweedfs-csi-driver"
CSI_NAMESPACE="kube-system"
CSI_TLS_SECRET_NAME="seaweedfs-tls"
CSI_SECURITY_ENABLED="true"

# 由上方数据库 / Redis 变量派生，一般无需修改
SQL_DSN="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}"
REDIS_CONN_STRING="redis://:${REDIS_PASSWORD}@redis:6379"
