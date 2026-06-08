#!/usr/bin/env bash
# Worker 节点部署配置 — 由 install-worker.sh 加载
# 交互式输入 Master SSH 信息；其余 vLLM / 存储参数在此修改

# Kubernetes 命名空间（与 Master 一致）
NAMESPACE="new-api"

# Master 上 New API 对外端口（用于自动注册渠道，与 install-master-config.sh 一致）
NODE_PORT="30080"

# New API 管理 Token（自动注册 vLLM 渠道时使用，与 Master 配置一致）
INIT_WEB_ACCESS_TOKEN="w2h6nb+FO1cmYTg4aYvfjvflMkRyyZRn"
NEW_API_ROOT_USER_ID="1"

# vLLM 模型服务（Helm chart-helm，hostPath 挂载在本 Worker 节点）
DEPLOY_VLLM="true"
VLLM_RELEASE_NAME="vllm-worker"
VLLM_MODEL_NAME="Qwen3.5-35B-A3B-FP8"
VLLM_MODEL_HOST_PATH="/data/models/${VLLM_MODEL_NAME}"
VLLM_IMAGE_REPO="registry-public.lenovo.com/newapi/new-api"
VLLM_IMAGE_TAG="vllmopenai0.22"
VLLM_EXTRA_ARGS_JSON='["--tensor-parallel-size","2","--enable-expert-parallel","--language-model-only","--reasoning-parser","qwen3","--max-model-len","8192","--gpu-memory-utilization","0.90"]'
# Deployment 副本数（Worker 节点上总 GPU ≥ VLLM_REPLICA_COUNT × VLLM_GPU_COUNT）
VLLM_REPLICA_COUNT="1"
# 每个 Pod 请求的 GPU 数（与 --tensor-parallel-size 对齐）
VLLM_GPU_COUNT="2"
# GPU: auto | true | false
VLLM_GPU_ENABLED="auto"
VLLM_GPU_RUNTIME_CLASS=""
# HPA 自动扩缩（GPU 场景通常固定副本）
VLLM_AUTOSCALING_ENABLED="false"
VLLM_AUTOSCALING_MIN_REPLICAS="1"
VLLM_AUTOSCALING_MAX_REPLICAS="4"

# vLLM 自动注册到 Master 上的 New API
AUTO_REGISTER_VLLM="true"
VLLM_CHANNEL_NAME="vllm-worker"
VLLM_CHANNEL_BASE_URL="http://${VLLM_RELEASE_NAME}-service.${NAMESPACE}.svc.cluster.local"
VLLM_CHANNEL_KEY="vllm"
VLLM_TOKEN_NAME="auto-vllm-worker"
AUTO_SETUP_MODEL_PRICING="true"
VLLM_MODEL_RATIO="1"

# SeaweedFS Volume（本 Worker 宿主机 Docker，仅 7201 卷组件）
DEPLOY_VOLUME="true"
# 留空则自动检测本机 IP
WORKER_NODE_IP=""
STORAGE_DATA_ROOT="/data/server/s3"
STORAGE_MASTER_PORT="7200"
STORAGE_VOLUME_PORT="7201"
# Master SeaweedFS 数据目录（用于 scp 同步 gRPC 证书）
MASTER_STORAGE_DATA_ROOT="/data/server/s3"
STORAGE_VOLUME_MAX="1536"
STORAGE_VOLUME_DATA_CENTER="xclaw1"
STORAGE_VOLUME_RACK="rack1"
STORAGE_SEAWEEDFS_IMAGE="registry-public.lenovo.com/newapi/new-api:seaweedfs430"

# SSH（也可由 install-worker.sh 交互式输入覆盖）
MASTER_SSH_USER="root"
MASTER_SSH_PORT="22"
# MASTER_HOST=""           # 交互式输入
# MASTER_SSH_PASSWORD=""   # 交互式输入
