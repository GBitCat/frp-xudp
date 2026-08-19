#!/usr/bin/env bash
set -euo pipefail

# 将当前维护分支前向合并到上游开发分支的新提交。
#
# 默认目标固定为 upstream/dev。只允许显式的 <remote>/<branch> 目标，
# 不接受 tag 或任意 ref。dry-run 不 fetch，但会对本地远端跟踪分支运行
# merge-base 和 merge-tree 预检。

usage() {
	cat <<'EOF'
用法: upgrade-from-upstream.sh [REMOTE/BRANCH] [选项]

选项:
  --target REMOTE/BRANCH  显式远端分支目标（默认 upstream/dev）
  --allow-branch BRANCH   dry-run 时覆盖允许的本地分支（真实模式禁止）
  --build                 同步完成后在 frp-dev 容器编译；仅构建失败退出 20
  --dry-run               不 fetch、不 merge；执行真实 merge-base/merge-tree 预检
  -h, --help              显示帮助

环境变量:
  UPSTREAM_SYNC_ALLOWED_BRANCH  与 --allow-branch 相同，仅 dry-run 可用
  PROXY                         fetch 使用的 HTTP/HTTPS 代理（可选）

tag 仅用于兼容性对照和发布里程碑，不是本脚本的合并目标。
EOF
}

die() {
	echo "!! $*" >&2
	exit 1
}

say() {
	echo "==> $*"
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_SPEC="upstream/dev"
TARGET_WAS_SET=0
ALLOWED_BRANCH="beta"
BRANCH_OVERRIDE_USED=0
if [ "${UPSTREAM_SYNC_ALLOWED_BRANCH+x}" = x ]; then
	ALLOWED_BRANCH="$UPSTREAM_SYNC_ALLOWED_BRANCH"
	BRANCH_OVERRIDE_USED=1
fi
PROXY="${PROXY:-}"
BUILD=0
DRY=0
BUILD_FAILURE_EXIT=20

set_target() {
	[ "$TARGET_WAS_SET" -eq 0 ] || die "目标只能指定一次"
	TARGET_SPEC="$1"
	TARGET_WAS_SET=1
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--target)
			[ "$#" -ge 2 ] || die "--target 缺少 REMOTE/BRANCH"
			set_target "$2"
			shift 2
			;;
		--allow-branch)
			[ "$#" -ge 2 ] || die "--allow-branch 缺少 BRANCH"
			ALLOWED_BRANCH="$2"
			BRANCH_OVERRIDE_USED=1
			shift 2
			;;
		--build)
			BUILD=1
			shift
			;;
		--dry-run)
			DRY=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		--*|-*)
			die "未知参数: $1"
			;;
		*)
			set_target "$1"
			shift
			;;
	esac
done

if [ "$DRY" -eq 0 ] && [ "$BRANCH_OVERRIDE_USED" -eq 1 ]; then
	die "真实模式强制在 beta 分支执行；--allow-branch 和 UPSTREAM_SYNC_ALLOWED_BRANCH 仅允许用于 dry-run"
fi

case "$TARGET_SPEC" in
	refs/*) die "不接受 tag 或显式 ref 目标: $TARGET_SPEC" ;;
	*/*) ;;
	*) die "目标必须是 REMOTE/BRANCH；不接受 tag: $TARGET_SPEC" ;;
esac

REMOTE="${TARGET_SPEC%%/*}"
REMOTE_BRANCH="${TARGET_SPEC#*/}"

# remote 使用保守字符集；branch 再交给 git 的 ref 格式校验。
[[ "$REMOTE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
	die "不安全或非法的远端名: $REMOTE"
git check-ref-format "refs/remotes/$REMOTE/check" >/dev/null 2>&1 ||
	die "不安全或非法的远端名: $REMOTE"
[ -n "$REMOTE_BRANCH" ] || die "目标分支不能为空"
git check-ref-format "refs/heads/$REMOTE_BRANCH" >/dev/null 2>&1 ||
	die "不安全或非法的远端分支名: $REMOTE_BRANCH"
git check-ref-format "refs/heads/$ALLOWED_BRANCH" >/dev/null 2>&1 ||
	die "不安全或非法的允许分支名: $ALLOWED_BRANCH"
case "$PROXY" in
	*$'\n'*|*$'\r'*) die "PROXY 不能包含换行符" ;;
esac

cd "$REPO_ROOT"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "脚本不在 Git 工作树中"
git config --get "remote.$REMOTE.url" >/dev/null 2>&1 || die "远端不存在: $REMOTE"

CURRENT_BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" ||
	die "当前为 detached HEAD；只允许分支 $ALLOWED_BRANCH"
[ "$CURRENT_BRANCH" = "$ALLOWED_BRANCH" ] ||
	die "当前分支为 $CURRENT_BRANCH；只允许在 $ALLOWED_BRANCH 上执行"

TARGET_REF="refs/remotes/$REMOTE/$REMOTE_BRANCH"
BASELINE_OID="$(git rev-parse --verify "$TARGET_REF^{commit}" 2>/dev/null)" ||
	die "缺少本地基线 $TARGET_SPEC；请先人工核对并建立该远端跟踪分支"
START_HEAD="$(git rev-parse --verify HEAD^{commit})"

list_untracked_build_tag_files() {
	local file
	declare -A seen=()
	while IFS= read -r -d '' file; do
		[ "${seen[$file]+present}" != present ] || continue
		seen["$file"]=1
		if grep -Eq '^//go:build[[:space:]]+' -- "$file"; then
			printf '%s\n' "$file"
		fi
	done < <(
		git ls-files --others --exclude-standard -z -- '*.go'
		git ls-files --others --ignored --exclude-standard -z -- '*.go'
	)
}

require_clean_release_inputs() {
	local build_tag_files status
	build_tag_files="$(list_untracked_build_tag_files)"
	if [ -n "$build_tag_files" ]; then
		echo "!! 存在未跟踪或被 ignored 的 Go build-tag 文件，真实升级/发布前必须纳入版本控制：" >&2
		echo "$build_tag_files" >&2
		exit 1
	fi

	status="$(git status --porcelain --untracked-files=all)"
	if [ -n "$status" ]; then
		echo "!! 工作树不干净，拒绝真实升级；请先提交或安全保存改动" >&2
		echo "$status" >&2
		exit 1
	fi
}

if [ "$DRY" -eq 0 ]; then
	require_clean_release_inputs
fi

MERGE_TREE_OUTPUT=""
FETCH_PORCELAIN_OUTPUT=""

cleanup_bootstrap_temp_files() {
	local rc=$?
	trap - EXIT
	[ -z "$MERGE_TREE_OUTPUT" ] || rm -f -- "$MERGE_TREE_OUTPUT"
	[ -z "$FETCH_PORCELAIN_OUTPUT" ] || rm -f -- "$FETCH_PORCELAIN_OUTPUT"
	exit "$rc"
}

if MERGE_TREE_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/frp-upstream-merge-tree.XXXXXX")"; then
	:
else
	mktemp_rc=$?
	echo "!! 无法创建 merge-tree 临时输出文件（mktemp 退出码 $mktemp_rc）" >&2
	exit "$mktemp_rc"
fi
trap cleanup_bootstrap_temp_files EXIT
if FETCH_PORCELAIN_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/frp-upstream-fetch-porcelain.XXXXXX")"; then
	:
else
	mktemp_rc=$?
	echo "!! 无法创建 fetch porcelain 临时输出文件（mktemp 退出码 $mktemp_rc）；将清理已创建的 merge-tree 临时文件" >&2
	exit "$mktemp_rc"
fi
FETCH_REF=""
FETCH_REF_OWNED=0
FETCH_REF_EXPECTED_OID=""

cleanup_fetch_ref() {
	local current_oid
	[ -n "$FETCH_REF" ] || return 0

	if [ "$FETCH_REF_OWNED" -ne 1 ]; then
		if git show-ref --verify --quiet "$FETCH_REF"; then
			echo "!! 警告：发现未建立 owned expected OID 的临时引用 $FETCH_REF" >&2
			echo "!! 该引用可能是不完整 fetch 或并发操作的结果；为避免误删，已保留，请人工核对后以明确 OID 做 CAS 清理" >&2
		fi
		return 0
	fi

	if [ -z "$FETCH_REF_EXPECTED_OID" ]; then
		echo "!! 警告：临时 fetch 引用 $FETCH_REF 被标记 owned，但 expected OID 缺失；为避免误删，已保留并请人工核对" >&2
		return 0
	fi

	current_oid="$(git rev-parse --verify "$FETCH_REF" 2>/dev/null || true)"
	[ -n "$current_oid" ] || return 0
	if [ "$current_oid" != "$FETCH_REF_EXPECTED_OID" ]; then
		echo "!! 警告：临时 fetch 引用 $FETCH_REF 已从本进程期望的 $FETCH_REF_EXPECTED_OID 变为 $current_oid" >&2
		echo "!! 为避免误删并发结果，已保留该引用；请人工核对" >&2
		return 0
	fi

	if git update-ref -d "$FETCH_REF" "$FETCH_REF_EXPECTED_OID" >/dev/null 2>&1; then
		return 0
	fi

	current_oid="$(git rev-parse --verify "$FETCH_REF" 2>/dev/null || true)"
	if [ -z "$current_oid" ]; then
		return 0
	fi
	echo "!! 警告：无法以期望 OID $FETCH_REF_EXPECTED_OID CAS 删除临时 fetch 引用 $FETCH_REF（当前为 $current_oid）" >&2
	echo "!! 为避免误删，已保留该引用；请人工核对" >&2
}

cleanup() {
	local rc=$?
	trap - EXIT
	cleanup_fetch_ref
	rm -f -- "$MERGE_TREE_OUTPUT" "$FETCH_PORCELAIN_OUTPUT"
	exit "$rc"
}
trap cleanup EXIT

parse_fetch_porcelain() {
	local line flag payload old_oid new_oid local_ref extra object_type
	local record_count=0 target_count=0 oid_length="${#BASELINE_OID}"
	PORCELAIN_CANDIDATE_OID=""

	while IFS= read -r line || [ -n "$line" ]; do
		record_count=$((record_count + 1))
		[ "${#line}" -ge 3 ] || die "fetch porcelain 第 $record_count 行格式无效：字段不足"
		flag="${line:0:1}"
		[ "${line:1:1}" = " " ] ||
			die "fetch porcelain 第 $record_count 行格式无效：flag 后不是单个空格"
		case "$flag" in
			' '|\*|+|-|t|=|!) ;;
			*) die "fetch porcelain 第 $record_count 行包含未知 flag: $flag" ;;
		esac

		payload="${line:2}"
		IFS=' ' read -r old_oid new_oid local_ref extra <<<"$payload"
		[ -n "$old_oid" ] && [ -n "$new_oid" ] && [ -n "$local_ref" ] &&
			[ -z "${extra:-}" ] && [ "$payload" = "$old_oid $new_oid $local_ref" ] ||
			die "fetch porcelain 第 $record_count 行格式无效：必须恰好包含 old-OID、new-OID、local-ref 三个字段"
		[ "$local_ref" = "$FETCH_REF" ] ||
			die "fetch porcelain 包含非目标引用记录: $local_ref（期望 $FETCH_REF）"

		target_count=$((target_count + 1))
		[ "$target_count" -eq 1 ] || die "fetch porcelain 包含重复的目标引用记录: $FETCH_REF"
		[[ "$old_oid" =~ ^[0-9a-f]+$ ]] && [ "${#old_oid}" -eq "$oid_length" ] ||
			die "fetch porcelain old OID 格式无效"
		[[ "$old_oid" =~ ^0+$ ]] ||
			die "fetch porcelain old OID 必须为当前对象格式长度的全零 OID；临时引用在 fetch 前已确认不存在"
		[[ "$new_oid" =~ ^[0-9a-f]+$ ]] && [ "${#new_oid}" -eq "$oid_length" ] ||
			die "fetch porcelain new OID 格式无效"
		[[ ! "$new_oid" =~ ^0+$ ]] || die "fetch porcelain new OID 不能为零 OID"
		object_type="$(git cat-file -t "$new_oid" 2>/dev/null)" ||
			die "fetch porcelain new OID 对象不存在: $new_oid"
		[ "$object_type" = commit ] ||
			die "fetch porcelain new OID 不是 commit: $new_oid（类型 $object_type）"
		PORCELAIN_CANDIDATE_OID="$new_oid"
	done <"$FETCH_PORCELAIN_OUTPUT"

	[ "$record_count" -eq 1 ] ||
		die "fetch porcelain 必须恰好包含一条记录，实际为 $record_count 条"
	[ "$target_count" -eq 1 ] && [ -n "$PORCELAIN_CANDIDATE_OID" ] ||
		die "fetch porcelain 缺少目标引用记录: $FETCH_REF"
}

validate_forward_target() {
	local baseline="$1" candidate="$2"
	git cat-file -e "$candidate^{commit}" 2>/dev/null || die "目标不是提交: $candidate"
	if ! git merge-base --is-ancestor "$baseline" "$candidate"; then
		die "远端目标已相对当前基线分叉或回退，拒绝更新: $baseline !-> $candidate"
	fi
}

require_merge_tree_capability() {
	local rc
	if git merge-tree --write-tree --name-only --messages \
		"$START_HEAD" "$START_HEAD" >"$MERGE_TREE_OUTPUT" 2>&1; then
		return
	else
		rc=$?
	fi
	echo "!! merge-tree 能力预检失败（退出码 $rc）；需要支持 --write-tree、--name-only 和 --messages 的 Git：" >&2
	sed -n '1,200p' "$MERGE_TREE_OUTPUT" >&2
	exit 1
}

preflight_merge() {
	local head_oid="$1" target_oid="$2" merge_base relation rc
	merge_base="$(git merge-base "$head_oid" "$target_oid" 2>/dev/null)" ||
		die "beta 与目标没有共同祖先，拒绝合并"

	if git merge-base --is-ancestor "$target_oid" "$head_oid"; then
		relation="目标已包含在当前 beta"
	elif git merge-base --is-ancestor "$head_oid" "$target_oid"; then
		relation="beta 可快进到目标"
	else
		relation="beta 与目标各有提交，需要普通 merge"
	fi

	say "merge-base: $merge_base（$relation）"
	if git merge-tree --write-tree --name-only --messages \
		"$head_oid" "$target_oid" >"$MERGE_TREE_OUTPUT" 2>&1; then
		say "merge-tree 预检通过（未改动工作树或分支）"
	else
		rc=$?
		if [ "$rc" -eq 1 ]; then
			echo "!! merge-tree 预检发现冲突，拒绝继续：" >&2
		else
			echo "!! merge-tree 工具执行错误（退出码 $rc），无法判定是否冲突，拒绝继续：" >&2
		fi
		sed -n '1,200p' "$MERGE_TREE_OUTPUT" >&2
		exit 1
	fi
}

merge_candidate() {
	local rc merge_start_head merge_start_status current_head current_status
	local current_head_ok=0 current_status_ok=0
	merge_start_head="$(git rev-parse --verify HEAD^{commit})" ||
		die "merge 前无法记录 HEAD，拒绝执行"
	merge_start_status="$(git status --porcelain --untracked-files=all)"
	[ -z "$merge_start_status" ] ||
		die "merge 前工作树不再干净，拒绝执行"

	if git merge --no-edit "$CANDIDATE_OID"; then
		return
	else
		rc=$?
	fi

	if git rev-parse --quiet --verify MERGE_HEAD >/dev/null 2>&1; then
		echo "!! git merge 失败（退出码 $rc），检测到 MERGE_HEAD；正在自动执行 git merge --abort" >&2
		if git merge --abort; then
			die "git merge 失败，已自动 abort；HEAD/工作树已恢复，脚本未更新 $TARGET_REF"
		fi
		echo "!! git merge --abort 失败；仓库可能仍处于 merge 状态，请勿继续操作，先人工恢复" >&2
		echo "!! 脚本尚未更新 $TARGET_REF；请同时核对该引用仍为安全基线 $BASELINE_OID" >&2
		exit 1
	fi

	if current_head="$(git rev-parse --verify HEAD^{commit} 2>/dev/null)"; then
		current_head_ok=1
	else
		current_head=""
	fi
	if current_status="$(git status --porcelain --untracked-files=all 2>/dev/null)"; then
		current_status_ok=1
	else
		current_status=""
	fi
	if [ "$current_head_ok" -eq 1 ] && [ "$current_status_ok" -eq 1 ] && \
		[ "$current_head" = "$merge_start_head" ] && [ "$current_status" = "$merge_start_status" ]; then
		die "git merge 失败（退出码 $rc）且未检测到 MERGE_HEAD；安全失败：HEAD/index/worktree 与 merge 前一致，脚本未更新 $TARGET_REF"
	fi

	echo "!! git merge 失败（退出码 $rc）且未检测到 MERGE_HEAD；需人工恢复：HEAD/index/worktree 与 merge 前记录不一致或无法完整验证" >&2
	echo "!! merge 前 HEAD: $merge_start_head；当前 HEAD: ${current_head:-<无法读取>}" >&2
	if [ "$current_status_ok" -ne 1 ]; then
		echo "!! 当前状态：<无法读取>（脚本绝不 reset）" >&2
	elif [ "$current_status" != "$merge_start_status" ]; then
		echo "!! 当前状态（脚本绝不 reset）：" >&2
		if [ -n "$current_status" ]; then
			echo "$current_status" >&2
		else
			echo "<clean，但与 merge 前记录不一致>" >&2
		fi
	fi
	echo "!! 脚本尚未更新 $TARGET_REF；请停止后续操作并人工核对、恢复" >&2
	exit 1
}

advance_tracking_ref() {
	local current_oid
	if git update-ref "$TARGET_REF" "$CANDIDATE_OID" "$BASELINE_OID"; then
		say "远端跟踪引用已原子前移: $BASELINE_OID -> $CANDIDATE_OID"
		return
	fi

	current_oid="$(git rev-parse --verify "$TARGET_REF^{commit}" 2>/dev/null || true)"
	if [ "$current_oid" = "$CANDIDATE_OID" ]; then
		say "远端跟踪引用已被并发操作安全前移到同一候选，无需覆盖"
		return
	fi
	echo "!! merge 已成功，但 $TARGET_REF 在此期间被并发修改为 ${current_oid:-<缺失>}" >&2
	echo "!! 为避免覆盖并发结果，脚本未更新该引用；当前分支已包含候选 $CANDIDATE_OID，请先人工核对引用再重试" >&2
	exit 1
}

say "当前分支: $CURRENT_BRANCH"
say "上游目标: $TARGET_SPEC"
say "本地基线: $BASELINE_OID"

require_merge_tree_capability

CANDIDATE_OID="$BASELINE_OID"
if [ "$DRY" -eq 1 ]; then
	say "[dry-run] 不 fetch；使用本地 $TARGET_SPEC"
else
	FETCH_REF="refs/frp-upstream-sync/$$-${MERGE_TREE_OUTPUT##*.}"
	git check-ref-format "$FETCH_REF" >/dev/null 2>&1 || die "无法构造安全的临时 fetch 引用"
	if git show-ref --verify --quiet "$FETCH_REF"; then
		die "进程唯一临时 fetch 引用意外已存在: $FETCH_REF"
	fi
	say "fetch 精确分支 refs/heads/$REMOTE_BRANCH 到临时引用 $FETCH_REF（--no-tags、禁写 FETCH_HEAD）"
	fetch_rc=0
	if [ -n "$PROXY" ]; then
		if git -c "http.proxy=$PROXY" -c "https.proxy=$PROXY" \
			fetch --porcelain --no-tags --no-write-fetch-head --refmap= "$REMOTE" \
			"refs/heads/$REMOTE_BRANCH:$FETCH_REF" >"$FETCH_PORCELAIN_OUTPUT"; then
			:
		else
			fetch_rc=$?
		fi
	else
		if git fetch --porcelain --no-tags --no-write-fetch-head --refmap= "$REMOTE" \
			"refs/heads/$REMOTE_BRANCH:$FETCH_REF" >"$FETCH_PORCELAIN_OUTPUT"; then
			:
		else
			fetch_rc=$?
		fi
	fi
	if [ "$fetch_rc" -ne 0 ]; then
		die "fetch 失败（git 退出码 $fetch_rc）；未建立 owned expected OID，不会使用、认领或删除失败 fetch 可能留下的临时引用"
	fi
	# 候选与 expected OID 只能来自 fetch 的事务输出，绝不从当前 ref 现读认领。
	parse_fetch_porcelain
	FETCH_REF_EXPECTED_OID="$PORCELAIN_CANDIDATE_OID"
	CANDIDATE_OID="$PORCELAIN_CANDIDATE_OID"
	current_fetch_oid="$(git rev-parse --verify "$FETCH_REF" 2>/dev/null || true)"
	if [ -z "$current_fetch_oid" ]; then
		die "fetch porcelain 候选为 $FETCH_REF_EXPECTED_OID，但当前临时引用不可读；未建立所有权并保留遗留引用"
	fi
	[ "$current_fetch_oid" = "$FETCH_REF_EXPECTED_OID" ] ||
		die "fetch porcelain 候选 $FETCH_REF_EXPECTED_OID 与当前临时引用 $current_fetch_oid 不一致；未建立所有权并保留当前引用"
	FETCH_REF_OWNED=1
	validate_forward_target "$BASELINE_OID" "$CANDIDATE_OID"
	say "目标通过前向校验: $BASELINE_OID -> $CANDIDATE_OID"
fi

preflight_merge "$START_HEAD" "$CANDIDATE_OID"

if [ "$DRY" -eq 1 ]; then
	if [ "$BUILD" -eq 1 ]; then
		say "[dry-run] 跳过容器编译"
	fi
	cat <<'EOF'

==> dry-run 完成：已执行真实 merge-base/merge-tree 预检；未 fetch、未 merge。
EOF
	exit 0
fi

# fetch 与预检之后、真实 merge 之前再次验证所有可变条件。
[ "$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" = "$ALLOWED_BRANCH" ] ||
	die "预检后当前分支发生变化，拒绝 merge"
[ "$(git rev-parse --verify HEAD^{commit})" = "$START_HEAD" ] ||
	die "预检后 HEAD 发生变化，拒绝 merge"
[ "$(git rev-parse --verify "$TARGET_REF^{commit}")" = "$BASELINE_OID" ] ||
	die "预检后远端跟踪基线被并发修改；为避免覆盖，拒绝 merge"
[ "$(git rev-parse --verify "$FETCH_REF")" = "$FETCH_REF_EXPECTED_OID" ] ||
	die "预检后临时候选引用发生变化，拒绝 merge"
require_clean_release_inputs
validate_forward_target "$BASELINE_OID" "$CANDIDATE_OID"
preflight_merge "$START_HEAD" "$CANDIDATE_OID"

if git merge-base --is-ancestor "$CANDIDATE_OID" "$START_HEAD"; then
	say "beta 已包含目标，无需 merge"
else
	say "合并已验证的上游提交 $CANDIDATE_OID"
	merge_candidate
fi

# 只有 merge 成功（或确认无需 merge）后，才允许 CAS 更新远端跟踪引用。
advance_tracking_ref

if [ "$BUILD" -eq 1 ]; then
	say "容器内编译 frps/frpc"
	if docker exec -w /workspace/src frp-dev bash -lc '
		CGO_ENABLED=0 go build -buildvcs=false -trimpath -ldflags "-s -w" \
			-tags "frps,noweb" -o /workspace/bin/frps ./cmd/frps &&
		CGO_ENABLED=0 go build -buildvcs=false -trimpath -ldflags "-s -w" \
			-tags "frpc,noweb" -o /workspace/bin/frpc ./cmd/frpc'
	then
		:
	else
		build_rc=$?
		echo "!! 容器构建验收失败（docker 退出码 $build_rc）" >&2
		echo "!! 上游同步/merge/tracking已完成，仅构建验收失败；不会回滚已完成的同步" >&2
		exit "$BUILD_FAILURE_EXIT"
	fi
fi

cat <<'EOF'

==> 上游同步步骤完成，请按 UPSTREAM_SYNC.md 完成 XUDP 冲突清单、测试和发布门禁。
EOF
