#!/usr/bin/env bash
set -euo pipefail

# 从 fatedier/frp 上游发布 tag 升级当前维护分支（保留 XUDP 扩展）。
#
# 用法:
#   ./scripts/upgrade-from-upstream.sh <上游tag> [--build] [--dry-run]
#
# 环境变量:
#   PROXY   git 拉取使用的代理（可选）。默认读取仓库根目录 .env
#           （参考 .env.example），未配置则不使用代理。
#
# 流程: fetch tag -> merge -> 冲突检查 -> (可选)容器内编译 -> 回归提示
# 详见 UPSTREAM_SYNC.md。

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 读取 .env（如果存在）
if [ -f "$REPO_ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +a
fi

PROXY="${PROXY:-}"
TAG="${1:?用法: upgrade-from-upstream.sh <tag> [--build] [--dry-run]}"

BUILD=0
DRY=0
for arg in "${@:2}"; do
  case "$arg" in
    --build) BUILD=1 ;;
    --dry-run) DRY=1 ;;
    *)
      echo "未知参数: $arg" >&2
      exit 1
      ;;
  esac
done

cd "$REPO_ROOT"

say() { echo "==> $*"; }
saydry() { echo "==> [dry-run] $*"; }

# 0) 真实执行前检查工作区是否干净
if [ "$DRY" -eq 0 ]; then
  if [ -n "$(git status --porcelain)" ]; then
    echo "!! 工作区有未提交改动，请先提交或 stash 再升级" >&2
    git status --short >&2
    exit 1
  fi
fi

echo "==> 当前分支: $(git rev-parse --abbrev-ref HEAD)"
echo "==> 目标 tag: $TAG"

# 1) 拉取上游 tag
if [ "$DRY" -eq 1 ]; then
  if [ -n "$PROXY" ]; then
    saydry "git -c http.proxy=$PROXY fetch origin tag $TAG"
  else
    saydry "git fetch origin tag $TAG"
  fi
else
  say "拉取上游 tag $TAG"
  if [ -n "$PROXY" ]; then
    git -c "http.proxy=$PROXY" -c "https.proxy=$PROXY" fetch origin tag "$TAG"
  else
    git fetch origin tag "$TAG"
  fi
fi

# 2) 合并
if [ "$DRY" -eq 1 ]; then
  saydry "git merge $TAG"
else
  say "合并 $TAG 到当前分支"
  if ! git merge "$TAG"; then
    echo "!! 合并产生冲突，请按 UPSTREAM_SYNC.md 第 5 节解决：" >&2
    git status --short >&2
    exit 1
  fi
fi

# 3) 冲突检查（dry-run 跳过）
if [ "$DRY" -eq 0 ]; then
  if conflicts=$(git diff --name-only --diff-filter=U 2>/dev/null) && [ -n "$conflicts" ]; then
    echo "!! 存在未解决冲突：" >&2
    echo "$conflicts" >&2
    exit 1
  fi
fi

# 4) 可选：容器内编译 frps/frpc
if [ "$BUILD" -eq 1 ]; then
  if [ "$DRY" -eq 1 ]; then
    saydry "docker exec -w /workspace/src frp-dev go build frps/frpc"
  else
    say "容器内编译 frps/frpc"
    docker exec -w /workspace/src frp-dev bash -lc '
      CGO_ENABLED=0 go build -buildvcs=false -trimpath -ldflags "-s -w" \
        -tags "frps,noweb" -o /workspace/bin/frps ./cmd/frps &&
      CGO_ENABLED=0 go build -buildvcs=false -trimpath -ldflags "-s -w" \
        -tags "frpc,noweb" -o /workspace/bin/frpc ./cmd/frpc'
  fi
fi

cat <<'EOF'

==> 升级步骤完成，请按 UPSTREAM_SYNC.md 完成后续检查：
  1. pkg/xudp 三个新文件是否受上游 nathole/msg API 变更影响
     （编译通过不代表语义正确）
  2. 三容器回归：P2P 与 relay 两条路径（UPSTREAM_SYNC.md 第 6 节）
  3. 通过后打自己的 tag：git tag xudp-<版本>
EOF
