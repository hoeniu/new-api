# SeaweedFS S3 存储部署

宿主机 Docker + systemd 部署，与 `install.sh` 中的 Kubernetes / vLLM **独立**（vLLM 仍用本地 `hostPath` 模型目录）。

## 目录结构

```
storage/
  config.sh          # 部署参数（IP、peers、密钥等）
  install.sh         # 一键安装
  templates/         # filer.toml、security.toml、config.json、systemd 单元
```

## 安装

1. 编辑 `config.sh`（至少设置 `STORAGE_NODE_IP`、`STORAGE_MASTER_PEERS`）
2. Filer 元数据使用本地 **leveldb2**（`templates/filer.toml`，目录 `/data/filerldb2`）
3. gRPC mTLS 证书：默认由 `install.sh` 自动生成到 `${STORAGE_DATA_ROOT}/data/cert/`；生产环境可自备证书并设 `STORAGE_GRPC_TLS_AUTO_CERT=false`
4. 在存储节点上执行：

```bash
sudo bash /path/to/claw-gataway/k8s/storage/install.sh
```

或从 k8s 目录：

```bash
sudo ./install.sh storage
```

## 多节点

在每台机器上分别执行，设置：

- `STORAGE_NODE_IP` — 本机 IP
- `STORAGE_COMPONENTS` — 本机运行的组件（如仅 `master,volume` 或全套）

Master peers 三台需一致：`10.199.117.2:7200,10.199.117.3:7200,10.199.117.4:7200`

## 与 install.sh 联动

完整 K8s 部署时，在 `install.config.sh` 设置：

```bash
DEPLOY_STORAGE="true"
```

会在 K8s/vLLM 步骤之后调用本目录的 `install.sh`（需 root）。
