#!/usr/bin/env bash
set -euo pipefail

# 通过 127.0.0.1:8118 代理拉取 Docker 镜像并导入本地 Docker。
#
# 用法:
#   PROXY=http://127.0.0.1:8118 ./scripts/pull-with-proxy.sh <image[:tag]> [输出文件名]
#
# 背景: 本机 Docker 守护进程没有配置代理（修改 /etc/docker/daemon.json 需要 root），
#       所以这里用 crane 走代理把镜像拉成 tar 包，再 docker load 导入。

PROXY="${PROXY:-http://127.0.0.1:8118}"
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
  echo "==> 通过 ${PROXY} 下载 crane 工具"
  curl -fsSL -x "${PROXY}" \
    "https://github.com/google/go-containerregistry/releases/latest/download/go-containerregistry_Linux_${CRANE_ARCH}.tar.gz" \
    -o "${CRANE_DIR}/crane.tar.gz"
  tar -xzf "${CRANE_DIR}/crane.tar.gz" -C "${CRANE_DIR}" crane
  rm -f "${CRANE_DIR}/crane.tar.gz"
fi

OUT="${2:-/tmp/$(echo "${IMAGE}" | tr '/:' '__').tar}"

echo "==> 通过 ${PROXY} 拉取 ${IMAGE}"
HTTP_PROXY="${PROXY}" HTTPS_PROXY="${PROXY}" NO_PROXY="localhost,127.0.0.1,::1" \
  "${CRANE}" pull "${IMAGE}" "${OUT}"

echo "==> docker load 导入 ${IMAGE}"
docker load -i "${OUT}"
echo "==> 完成: ${IMAGE}"
