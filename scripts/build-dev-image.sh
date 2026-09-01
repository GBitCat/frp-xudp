#!/usr/bin/env bash
set -euo pipefail

# 构建 frp 开发环境镜像。
#
# 用法:
#   ./scripts/build-dev-image.sh [镜像名:tag]
#
# 代理配置（可选）:
#   默认不代理。如需代理，通过环境变量 PROXY 或仓库根目录 .env
#   （参考 .env.example）配置，例如:
#     PROXY=http://host:port ./scripts/build-dev-image.sh
#
# 注意: 配置代理时，容器内下载需要访问宿主机代理，
#       因此构建必须使用 --network=host。

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 读取 .env（如果存在）
if [ -f "$ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

PROXY="${PROXY:-}"
TAG="${1:-frp-dev:ubuntu-26.04}"

BUILD_ARGS=()
if [ -n "$PROXY" ]; then
  export http_proxy="$PROXY" https_proxy="$PROXY" HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY"
  BUILD_ARGS+=(
    --build-arg http_proxy
    --build-arg https_proxy
    --build-arg HTTP_PROXY
    --build-arg HTTPS_PROXY
  )
fi

docker build \
  --network=host \
  "${BUILD_ARGS[@]}" \
  -t "${TAG}" \
  -f "$ROOT/Dockerfile" \
  "$ROOT"

echo "==> 构建完成: ${TAG}"
