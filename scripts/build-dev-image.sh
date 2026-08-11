#!/usr/bin/env bash
set -euo pipefail

# 构建 frp 开发环境镜像。
#
# 用法:
#   ./scripts/build-dev-image.sh [镜像名:tag]
# 环境变量:
#   PROXY: 构建与容器内下载使用的代理，默认 http://127.0.0.1:8118
#
# 注意: 必须使用 --network=host，否则容器内的 127.0.0.1 指向容器自己，
#       无法访问宿主机的 8118 代理。

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROXY="${PROXY:-http://127.0.0.1:8118}"
TAG="${1:-frp-dev:ubuntu-26.04}"

docker build \
  --network=host \
  --build-arg "PROXY=${PROXY}" \
  -t "${TAG}" \
  -f "${ROOT}/Dockerfile" \
  "${ROOT}"

echo "==> 构建完成: ${TAG}"
