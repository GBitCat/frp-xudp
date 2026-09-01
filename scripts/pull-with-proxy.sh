#!/usr/bin/env bash
set -euo pipefail

# 通过代理拉取 Docker 镜像并导入本地 Docker。
#
# 用法:
#   ./scripts/pull-with-proxy.sh <image[:tag]> [输出文件名]
#
# 代理配置（必需）:
#   本脚本依赖代理工作，请通过环境变量 PROXY 或仓库根目录 .env
#   （参考 .env.example）配置，例如:
#     PROXY=http://host:port ./scripts/pull-with-proxy.sh ubuntu:26.04
#
# 背景: 本机 Docker 守护进程未配置代理（修改 /etc/docker/daemon.json 需要 root），
#       所以这里用 crane 走代理把镜像拉成 tar 包，再 docker load 导入。

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 读取 .env（如果存在）
if [ -f "$ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

PROXY="${PROXY:-}"
if [ -z "$PROXY" ]; then
  echo "!! 未配置代理：本脚本需要通过代理拉取镜像。" >&2
  echo "   如需代理，请设置 PROXY 环境变量，或在仓库根目录 .env 中配置（参考 .env.example）。" >&2
  exit 1
fi

IMAGE="${1:?用法: pull-with-proxy.sh <image[:tag]>}"

case "$(uname -m)" in
  x86_64|amd64) CRANE_ARCH="x86_64" ;;
  aarch64|arm64) CRANE_ARCH="aarch64" ;;
  *) echo "不支持的架构: $(uname -m)" >&2; exit 1 ;;
esac

CRANE_DIR="${CRANE_DIR:-/tmp/crane}"
CRANE="${CRANE_DIR}/crane"

if [ ! -x "${CRANE}" ]; then
  mkdir -p "${CRANE_DIR}"
  echo "==> 通过已配置代理下载 crane 工具"
  curl -fsSL -x "${PROXY}" \
    "https://github.com/google/go-containerregistry/releases/latest/download/go-containerregistry_Linux_${CRANE_ARCH}.tar.gz" \
    -o "${CRANE_DIR}/crane.tar.gz"
  tar -xzf "${CRANE_DIR}/crane.tar.gz" -C "${CRANE_DIR}" crane
  rm -f "${CRANE_DIR}/crane.tar.gz"
fi

OUT="${2:-/tmp/$(echo "${IMAGE}" | tr '/:' '__').tar}"

echo "==> 通过已配置代理拉取 ${IMAGE}"
HTTP_PROXY="${PROXY}" HTTPS_PROXY="${PROXY}" NO_PROXY="localhost,127.0.0.1,::1" \
  "${CRANE}" pull "${IMAGE}" "${OUT}"

echo "==> docker load 导入 ${IMAGE}"
docker load -i "${OUT}"
echo "==> 完成: ${IMAGE}"
