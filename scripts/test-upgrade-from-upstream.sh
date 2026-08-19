#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SCRIPT="$SOURCE_ROOT/scripts/upgrade-from-upstream.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/frp-upstream-sync-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0
LAST_OUTPUT=""
EXPECTED_TESTS=30

fail() {
	echo "not ok - $*" >&2
	exit 1
}

assert_eq() {
	local expected="$1" actual="$2" message="$3"
	[ "$actual" = "$expected" ] ||
		fail "$message（期望: $expected，实际: $actual）"
}

assert_clean() {
	local repo="$1" status
	status="$(git -C "$repo" status --porcelain --untracked-files=all)"
	[ -z "$status" ] || fail "工作树未恢复干净: $repo\n$status"
	if git -C "$repo" rev-parse --quiet --verify MERGE_HEAD >/dev/null 2>&1; then
		fail "MERGE_HEAD 未清理: $repo"
	fi
}

assert_no_temp_refs() {
	local repo="$1" refs
	refs="$(git -C "$repo" for-each-ref --format='%(refname)' refs/frp-upstream-sync/)"
	[ -z "$refs" ] || fail "临时 fetch 引用未清理: $refs"
}

new_fixture() {
	local name="$1"
	REPO="$TEST_ROOT/$name/repo"
	REMOTE_REPO="$TEST_ROOT/$name/upstream.git"
	FIXTURE_ROOT="$TEST_ROOT/$name"
	mkdir -p "$REPO/scripts"
	git init -q --bare "$REMOTE_REPO"
	git -C "$REPO" init -q -b beta
	git -C "$REPO" config user.name test
	git -C "$REPO" config user.email test@example.invalid
	printf 'base\n' >"$REPO/conflict.txt"
	git -C "$REPO" add conflict.txt
	git -C "$REPO" commit -q -m base
	BASE_OID="$(git -C "$REPO" rev-parse HEAD)"
	git -C "$REPO" remote add upstream "$REMOTE_REPO"
	git -C "$REPO" push -q upstream "$BASE_OID:refs/heads/dev"
	git -C "$REPO" update-ref refs/remotes/upstream/dev "$BASE_OID"
	cp "$SOURCE_SCRIPT" "$REPO/scripts/upgrade-from-upstream.sh"
	chmod +x "$REPO/scripts/upgrade-from-upstream.sh"
	git -C "$REPO" add scripts/upgrade-from-upstream.sh
	git -C "$REPO" commit -q -m harness
	SCRIPT="$REPO/scripts/upgrade-from-upstream.sh"
}

make_remote_commit() {
	local file="$1" content="$2" message="$3"
	PRODUCER="$FIXTURE_ROOT/producer"
	git clone -q --branch dev "$REMOTE_REPO" "$PRODUCER"
	git -C "$PRODUCER" config user.name test
	git -C "$PRODUCER" config user.email test@example.invalid
	mkdir -p "$(dirname "$PRODUCER/$file")"
	printf '%s\n' "$content" >"$PRODUCER/$file"
	git -C "$PRODUCER" add "$file"
	git -C "$PRODUCER" commit -q -m "$message"
	git -C "$PRODUCER" push -q origin dev
	CANDIDATE_OID="$(git -C "$PRODUCER" rev-parse HEAD)"
}

invoke() {
	local repo="$1"
	shift
	(cd "$repo" && "$repo/scripts/upgrade-from-upstream.sh" "$@")
}

expect_success() {
	local name="$1" needle="$2"
	shift 2
	local output
	if ! output="$("$@" 2>&1)"; then
		echo "not ok - $name" >&2
		echo "$output" >&2
		exit 1
	fi
	LAST_OUTPUT="$output"
	case "$output" in
		*"$needle"*) ;;
		*)
			echo "not ok - $name（输出缺少: $needle）" >&2
			echo "$output" >&2
			exit 1
			;;
	esac
	PASS=$((PASS + 1))
	echo "ok $PASS - $name"
}

expect_failure() {
	local name="$1" needle="$2"
	shift 2
	local output rc
	set +e
	output="$("$@" 2>&1)"
	rc=$?
	set -e
	if [ "$rc" -eq 0 ]; then
		echo "not ok - $name（预期失败）" >&2
		echo "$output" >&2
		exit 1
	fi
	LAST_OUTPUT="$output"
	case "$output" in
		*"$needle"*) ;;
		*)
			echo "not ok - $name（输出缺少: $needle）" >&2
			echo "$output" >&2
			exit 1
			;;
	esac
	PASS=$((PASS + 1))
	echo "ok $PASS - $name"
}

expect_failure_code() {
	local name="$1" expected_rc="$2" needle="$3"
	shift 3
	local output rc
	set +e
	output="$("$@" 2>&1)"
	rc=$?
	set -e
	if [ "$rc" -ne "$expected_rc" ]; then
		echo "not ok - $name（期望退出码: $expected_rc，实际: $rc）" >&2
		echo "$output" >&2
		exit 1
	fi
	LAST_OUTPUT="$output"
	case "$output" in
		*"$needle"*) ;;
		*)
			echo "not ok - $name（输出缺少: $needle）" >&2
			echo "$output" >&2
			exit 1
			;;
	esac
	PASS=$((PASS + 1))
	echo "ok $PASS - $name"
}

new_fixture wrong-branch
git -C "$REPO" branch -m feature/test
expect_failure "错误分支被拒绝" "只允许在 beta" invoke "$REPO" --dry-run

new_fixture branch-override
git -C "$REPO" branch -m test-beta
expect_success "显式允许分支覆盖可用于测试" "merge-tree 预检通过" \
	env UPSTREAM_SYNC_ALLOWED_BRANCH=test-beta "$SCRIPT" --dry-run

new_fixture real-branch-override
git -C "$REPO" branch -m test-beta
OVERRIDE_HEAD="$(git -C "$REPO" rev-parse HEAD)"
expect_failure "真实模式拒绝环境分支绕过" "真实模式强制在 beta" \
	env UPSTREAM_SYNC_ALLOWED_BRANCH=test-beta "$SCRIPT"
expect_failure "真实模式拒绝参数分支绕过" "真实模式强制在 beta" \
	"$SCRIPT" --allow-branch test-beta
assert_eq "$OVERRIDE_HEAD" "$(git -C "$REPO" rev-parse HEAD)" \
	"真实分支绕过测试不应改 HEAD"

new_fixture second-mktemp-failure
FAKE_BIN="$FIXTURE_ROOT/bin"
mkdir -p "$FAKE_BIN"
REAL_MKTEMP="$(command -v mktemp)"
MKTEMP_STATE="$FIXTURE_ROOT/mktemp-first-created"
FIRST_TEMP_PATH_FILE="$FIXTURE_ROOT/first-temp-path"
printf '%s\n' \
	'#!/bin/sh' \
	'if [ ! -e "$MKTEMP_STATE" ]; then' \
	'  : >"$MKTEMP_STATE"' \
	'  path=$("$REAL_MKTEMP" "$@") || exit $?' \
	'  printf "%s\\n" "$path" >"$FIRST_TEMP_PATH_FILE"' \
	'  printf "%s\\n" "$path"' \
	'  exit 0' \
	'fi' \
	'exit 71' >"$FAKE_BIN/mktemp"
chmod +x "$FAKE_BIN/mktemp"
expect_failure_code "第二个 mktemp 失败时清理第一个临时文件" 71 \
	"无法创建 fetch porcelain 临时输出文件（mktemp 退出码 71）" \
	env PATH="$FAKE_BIN:$PATH" REAL_MKTEMP="$REAL_MKTEMP" MKTEMP_STATE="$MKTEMP_STATE" \
	FIRST_TEMP_PATH_FILE="$FIRST_TEMP_PATH_FILE" "$SCRIPT" --dry-run
FIRST_TEMP_PATH="$(sed -n '1p' "$FIRST_TEMP_PATH_FILE")"
[ -n "$FIRST_TEMP_PATH" ] || fail "未记录第一个 mktemp 文件路径"
[ ! -e "$FIRST_TEMP_PATH" ] || fail "第二个 mktemp 失败后遗留了第一个临时文件: $FIRST_TEMP_PATH"

new_fixture dirty
printf 'dirty\n' >>"$REPO/conflict.txt"
DIRTY_HEAD="$(git -C "$REPO" rev-parse HEAD)"
expect_failure "真实升级拒绝 dirty 工作树" "工作树不干净" invoke "$REPO"
[ "$(git -C "$REPO" rev-parse HEAD)" = "$DIRTY_HEAD" ]

new_fixture ancestor
expect_success "祖先目标 dry-run 通过" "目标已包含在当前 beta" invoke "$REPO" --dry-run

new_fixture no-merge
NO_MERGE_HEAD="$(git -C "$REPO" rev-parse HEAD)"
expect_success "真实 fetch 后已包含目标时无需 merge" "beta 已包含目标，无需 merge" \
	invoke "$REPO"
assert_eq "$NO_MERGE_HEAD" "$(git -C "$REPO" rev-parse HEAD)" "无需 merge 时 HEAD 不应变化"
assert_eq "$BASE_OID" "$(git -C "$REPO" rev-parse refs/remotes/upstream/dev)" \
	"无需 merge 时 tracking ref 应保持候选基线"
assert_clean "$REPO"
assert_no_temp_refs "$REPO"

new_fixture diverged
EMPTY_TREE="$(git -C "$REPO" mktree </dev/null)"
DIVERGED_OID="$(printf 'diverged\n' | git -C "$REPO" commit-tree "$EMPTY_TREE")"
git -C "$REPO" push -q --force upstream "$DIVERGED_OID:refs/heads/dev"
git -C "$REPO" update-ref refs/remotes/upstream/dev "$BASE_OID"
DIVERGED_HEAD="$(git -C "$REPO" rev-parse HEAD)"
expect_failure "远端相对基线分叉被拒绝" "分叉或回退" invoke "$REPO"
[ "$(git -C "$REPO" rev-parse HEAD)" = "$DIVERGED_HEAD" ]
[ "$(git -C "$REPO" rev-parse refs/remotes/upstream/dev)" = "$BASE_OID" ]

new_fixture dry-conflict
make_remote_commit conflict.txt upstream upstream-conflict
git -C "$REPO" fetch -q --no-tags --refmap= upstream refs/heads/dev
printf 'beta\n' >"$REPO/conflict.txt"
git -C "$REPO" add conflict.txt
git -C "$REPO" commit -q -m beta-conflict
git -C "$REPO" update-ref refs/remotes/upstream/dev "$CANDIDATE_OID"
CONFLICT_HEAD="$(git -C "$REPO" rev-parse HEAD)"
expect_failure "dry-run 执行 merge-tree 并拒绝冲突" "预检发现冲突" \
	invoke "$REPO" --dry-run
assert_eq "$CONFLICT_HEAD" "$(git -C "$REPO" rev-parse HEAD)" "dry-run 冲突不应改 HEAD"
assert_clean "$REPO"

new_fixture real-conflict
make_remote_commit conflict.txt upstream upstream-conflict
printf 'beta\n' >"$REPO/conflict.txt"
git -C "$REPO" add conflict.txt
git -C "$REPO" commit -q -m beta-conflict
CONFLICT_HEAD="$(git -C "$REPO" rev-parse HEAD)"
expect_failure "真实 fetch 后冲突不更新 tracking ref" "预检发现冲突" invoke "$REPO"
assert_eq "$CONFLICT_HEAD" "$(git -C "$REPO" rev-parse HEAD)" "真实冲突不应改 HEAD"
assert_eq "$BASE_OID" "$(git -C "$REPO" rev-parse refs/remotes/upstream/dev)" \
	"真实冲突时 tracking ref 必须保持旧基线"
assert_clean "$REPO"
assert_no_temp_refs "$REPO"

new_fixture fake-fetch-head
make_remote_commit upstream.txt candidate ordinary-merge
EMPTY_TREE="$(git -C "$REPO" mktree </dev/null)"
FAKE_FETCH_OID="$(printf 'fake FETCH_HEAD\n' | git -C "$REPO" commit-tree "$EMPTY_TREE")"
printf '%s\t\tbranch fake of local\n' "$FAKE_FETCH_OID" >"$(git -C "$REPO" rev-parse --git-path FETCH_HEAD)"
FAKE_BIN="$FIXTURE_ROOT/bin"
mkdir -p "$FAKE_BIN"
REAL_GIT="$(command -v git)"
printf '%s\n' \
	'#!/bin/sh' \
	'if [ "$1" = fetch ]; then' \
	'  "$REAL_GIT" "$@"' \
	'  rc=$?' \
	'  printf "%s\\t\\tconcurrent fake FETCH_HEAD\\n" "$FAKE_FETCH_OID" >"$("$REAL_GIT" rev-parse --git-path FETCH_HEAD)"' \
	'  exit "$rc"' \
	'fi' \
	'exec "$REAL_GIT" "$@"' >"$FAKE_BIN/git"
chmod +x "$FAKE_BIN/git"
ORDINARY_START="$(git -C "$REPO" rev-parse HEAD)"
expect_success "普通 merge 只使用临时 ref 候选而忽略并发伪 FETCH_HEAD" \
	"远端跟踪引用已原子前移" env PATH="$FAKE_BIN:$PATH" REAL_GIT="$REAL_GIT" \
	FAKE_FETCH_OID="$FAKE_FETCH_OID" "$SCRIPT"
assert_eq "$CANDIDATE_OID" "$(git -C "$REPO" rev-parse refs/remotes/upstream/dev)" \
	"普通 merge 后 tracking ref 应前移到真实候选"
git -C "$REPO" merge-base --is-ancestor "$CANDIDATE_OID" HEAD ||
	fail "普通 merge 后 HEAD 未包含真实候选"
if git -C "$REPO" merge-base --is-ancestor "$FAKE_FETCH_OID" HEAD; then
	fail "伪 FETCH_HEAD 错误进入了 merge 结果"
fi
assert_eq "$FAKE_FETCH_OID" "$(sed -n '1s/[[:space:]].*//p' "$(git -C "$REPO" rev-parse --git-path FETCH_HEAD)")" \
	"--no-write-fetch-head 应保留并忽略原有 FETCH_HEAD"
[ "$(git -C "$REPO" rev-parse HEAD)" != "$ORDINARY_START" ] || fail "普通 merge 未推进 HEAD"
assert_eq "3" "$(git -C "$REPO" rev-list --parents -n 1 HEAD | wc -w | tr -d ' ')" \
	"分叉历史应产生普通双亲 merge commit"
assert_clean "$REPO"
assert_no_temp_refs "$REPO"

new_fixture fetch-failure-cleanup
make_remote_commit upstream.txt candidate fetch-failure-upstream
FAKE_BIN="$FIXTURE_ROOT/bin"
mkdir -p "$FAKE_BIN"
REAL_GIT="$(command -v git)"
printf '%s\n' \
	'#!/bin/sh' \
	'if [ "$1" = fetch ]; then' \
	'  "$REAL_GIT" "$@"' \
	'  rc=$?' \
	'  [ "$rc" -eq 0 ] || exit "$rc"' \
	'  exit 72' \
	'fi' \
	'exec "$REAL_GIT" "$@"' >"$FAKE_BIN/git"
chmod +x "$FAKE_BIN/git"
FETCH_FAILURE_HEAD="$(git -C "$REPO" rev-parse HEAD)"
expect_failure_code "fetch 返回失败但已写临时 ref 时保守保留" 1 \
	"fetch 失败（git 退出码 72）；未建立 owned expected OID" \
	env PATH="$FAKE_BIN:$PATH" REAL_GIT="$REAL_GIT" "$SCRIPT"
case "$LAST_OUTPUT" in
	*"为避免误删，已保留，请人工核对后以明确 OID 做 CAS 清理"*) ;;
	*) fail "fetch 失败遗留 ref 时缺少保守保留与人工清理告警" ;;
esac
assert_eq "$FETCH_FAILURE_HEAD" "$(git -C "$REPO" rev-parse HEAD)" \
	"fetch 失败不应改 HEAD"
assert_eq "$BASE_OID" "$(git -C "$REPO" rev-parse refs/remotes/upstream/dev)" \
	"fetch 失败不应更新 tracking ref"
RETAINED_REF="$(git -C "$REPO" for-each-ref --format='%(refname)' refs/frp-upstream-sync/)"
[ -n "$RETAINED_REF" ] || fail "故障 fetch 已写入的临时 ref 必须被保留"
assert_eq "$CANDIDATE_OID" "$(git -C "$REPO" rev-parse "$RETAINED_REF")" \
	"脚本不得改写或删除失败 fetch 遗留 ref"
assert_clean "$REPO"
git -C "$REPO" update-ref -d "$RETAINED_REF" "$CANDIDATE_OID"
assert_no_temp_refs "$REPO"

new_fixture preexisting-fetch-ref-race
make_remote_commit upstream-ancestor.txt ancestor preexisting-ref-ancestor
RACE_OLD_OID="$CANDIDATE_OID"
printf 'candidate\n' >"$PRODUCER/upstream-candidate.txt"
git -C "$PRODUCER" add upstream-candidate.txt
git -C "$PRODUCER" commit -q -m preexisting-ref-candidate
git -C "$PRODUCER" push -q origin dev
CANDIDATE_OID="$(git -C "$PRODUCER" rev-parse HEAD)"
# 仅把竞态祖先对象放入测试仓库对象库，不建立 ref 或写 FETCH_HEAD；随后由
# fake git 在真实 fetch 调用前创建临时 ref。
git -C "$REPO" fetch -q --no-tags --no-write-fetch-head --refmap= upstream "$RACE_OLD_OID"
FAKE_BIN="$FIXTURE_ROOT/bin"
mkdir -p "$FAKE_BIN"
REAL_GIT="$(command -v git)"
printf '%s\n' \
	'#!/bin/sh' \
	'if [ "$1" = fetch ]; then' \
	'  temp_ref=' \
	'  for arg in "$@"; do' \
	'    case "$arg" in' \
	'      refs/heads/*:refs/frp-upstream-sync/*) temp_ref=${arg#*:} ;;' \
	'    esac' \
	'  done' \
	'  [ -n "$temp_ref" ] || exit 77' \
	'  "$REAL_GIT" update-ref "$temp_ref" "$RACE_OLD_OID" || exit 78' \
	'  exec "$REAL_GIT" "$@"' \
	'fi' \
	'exec "$REAL_GIT" "$@"' >"$FAKE_BIN/git"
chmod +x "$FAKE_BIN/git"
PREEXISTING_RACE_HEAD="$(git -C "$REPO" rev-parse HEAD)"
expect_failure "fetch 调用窗口预建 ref 导致 porcelain old 非零时拒绝" \
	"fetch porcelain old OID 必须为当前对象格式长度的全零 OID" \
	env PATH="$FAKE_BIN:$PATH" REAL_GIT="$REAL_GIT" RACE_OLD_OID="$RACE_OLD_OID" "$SCRIPT"
assert_eq "$PREEXISTING_RACE_HEAD" "$(git -C "$REPO" rev-parse HEAD)" \
	"porcelain old 非零竞态不得推进 HEAD"
assert_eq "$BASE_OID" "$(git -C "$REPO" rev-parse refs/remotes/upstream/dev)" \
	"porcelain old 非零竞态不得更新 tracking ref"
if git -C "$REPO" merge-base --is-ancestor "$RACE_OLD_OID" HEAD; then
	fail "预建 replacement 祖先不得进入 merge"
fi
if git -C "$REPO" merge-base --is-ancestor "$CANDIDATE_OID" HEAD; then
	fail "old 非零竞态中的 candidate 不得进入 merge"
fi
RETAINED_REF="$(git -C "$REPO" for-each-ref --format='%(refname)' refs/frp-upstream-sync/)"
[ -n "$RETAINED_REF" ] || fail "old 非零竞态的临时 ref 必须被保留"
assert_eq "$CANDIDATE_OID" "$(git -C "$REPO" rev-parse "$RETAINED_REF")" \
	"真实 fetch 快进后的 candidate ref 应被保守保留"
assert_clean "$REPO"
git -C "$REPO" update-ref -d "$RETAINED_REF" "$CANDIDATE_OID"
assert_no_temp_refs "$REPO"

new_fixture fetch-return-window
make_remote_commit upstream.txt candidate fetch-return-window-upstream
REPLACEMENT_OID="$(printf 'fetch return window replacement\n' | git -C "$REPO" commit-tree \
	"$BASE_OID^{tree}" -p "$BASE_OID")"
FAKE_BIN="$FIXTURE_ROOT/bin"
mkdir -p "$FAKE_BIN"
REAL_GIT="$(command -v git)"
printf '%s\n' \
	'#!/bin/sh' \
	'if [ "$1" = fetch ]; then' \
	'  "$REAL_GIT" "$@"' \
	'  rc=$?' \
	'  [ "$rc" -eq 0 ] || exit "$rc"' \
	'  temp_ref=$("$REAL_GIT" for-each-ref --format="%(refname)" refs/frp-upstream-sync/)' \
	'  [ -n "$temp_ref" ] || exit 75' \
	'  "$REAL_GIT" update-ref "$temp_ref" "$REPLACEMENT_OID" || exit 76' \
	'  exit 0' \
	'fi' \
	'exec "$REAL_GIT" "$@"' >"$FAKE_BIN/git"
chmod +x "$FAKE_BIN/git"
WINDOW_HEAD="$(git -C "$REPO" rev-parse HEAD)"
expect_failure "fetch porcelain 输出后返回前 ref 被替换时拒绝认领" \
	"与当前临时引用 $REPLACEMENT_OID 不一致；未建立所有权" \
	env PATH="$FAKE_BIN:$PATH" REAL_GIT="$REAL_GIT" REPLACEMENT_OID="$REPLACEMENT_OID" "$SCRIPT"
assert_eq "$WINDOW_HEAD" "$(git -C "$REPO" rev-parse HEAD)" \
	"fetch 返回窗口替换不得推进 HEAD"
assert_eq "$BASE_OID" "$(git -C "$REPO" rev-parse refs/remotes/upstream/dev)" \
	"fetch 返回窗口替换不得更新 tracking ref"
if git -C "$REPO" merge-base --is-ancestor "$REPLACEMENT_OID" HEAD; then
	fail "fetch 返回窗口中的 replacement 不得进入 merge"
fi
RETAINED_REF="$(git -C "$REPO" for-each-ref --format='%(refname)' refs/frp-upstream-sync/)"
[ -n "$RETAINED_REF" ] || fail "fetch 返回窗口中的 replacement ref 必须被保留"
assert_eq "$REPLACEMENT_OID" "$(git -C "$REPO" rev-parse "$RETAINED_REF")" \
	"cleanup 不得删除 fetch 返回窗口中的 replacement ref"
case "$LAST_OUTPUT" in
	*"为避免误删，已保留，请人工核对后以明确 OID 做 CAS 清理"*) ;;
	*) fail "fetch 返回窗口替换后缺少保守保留告警" ;;
esac
assert_clean "$REPO"
git -C "$REPO" update-ref -d "$RETAINED_REF" "$REPLACEMENT_OID"
assert_no_temp_refs "$REPO"

new_fixture duplicate-fetch-porcelain
make_remote_commit upstream.txt candidate duplicate-fetch-porcelain-upstream
FAKE_BIN="$FIXTURE_ROOT/bin"
mkdir -p "$FAKE_BIN"
REAL_GIT="$(command -v git)"
printf '%s\n' \
	'#!/bin/sh' \
	'if [ "$1" = fetch ]; then' \
	'  fetch_output=$("$REAL_GIT" "$@")' \
	'  rc=$?' \
	'  [ "$rc" -eq 0 ] || { printf "%s\\n" "$fetch_output"; exit "$rc"; }' \
	'  printf "%s\\n%s\\n" "$fetch_output" "$fetch_output"' \
	'  exit 0' \
	'fi' \
	'exec "$REAL_GIT" "$@"' >"$FAKE_BIN/git"
chmod +x "$FAKE_BIN/git"
DUPLICATE_HEAD="$(git -C "$REPO" rev-parse HEAD)"
expect_failure "重复 porcelain 目标记录被拒绝且保持 unowned" \
	"fetch porcelain 包含重复的目标引用记录" \
	env PATH="$FAKE_BIN:$PATH" REAL_GIT="$REAL_GIT" "$SCRIPT"
assert_eq "$DUPLICATE_HEAD" "$(git -C "$REPO" rev-parse HEAD)" \
	"重复 porcelain 不得推进 HEAD"
assert_eq "$BASE_OID" "$(git -C "$REPO" rev-parse refs/remotes/upstream/dev)" \
	"重复 porcelain 不得更新 tracking ref"
RETAINED_REF="$(git -C "$REPO" for-each-ref --format='%(refname)' refs/frp-upstream-sync/)"
[ -n "$RETAINED_REF" ] || fail "重复 porcelain 解析失败后临时 ref 必须被保留"
assert_eq "$CANDIDATE_OID" "$(git -C "$REPO" rev-parse "$RETAINED_REF")" \
	"重复 porcelain 解析失败不得改写临时 ref"
assert_clean "$REPO"
git -C "$REPO" update-ref -d "$RETAINED_REF" "$CANDIDATE_OID"
assert_no_temp_refs "$REPO"

new_fixture concurrent-fetch-ref
make_remote_commit upstream.txt candidate concurrent-fetch-ref-upstream
REPLACEMENT_OID="$(printf 'concurrent replacement\n' | git -C "$REPO" commit-tree \
	"$BASE_OID^{tree}" -p "$BASE_OID")"
FAKE_BIN="$FIXTURE_ROOT/bin"
mkdir -p "$FAKE_BIN"
REAL_GIT="$(command -v git)"
MERGE_TREE_STATE="$FIXTURE_ROOT/merge-tree-first-call-done"
printf '%s\n' \
	'#!/bin/sh' \
	'if [ "$1" = merge-tree ]; then' \
	'  if [ ! -e "$MERGE_TREE_STATE" ]; then' \
	'    : >"$MERGE_TREE_STATE"' \
	'  else' \
	'    temp_ref=$("$REAL_GIT" for-each-ref --format="%(refname)" refs/frp-upstream-sync/)' \
	'    [ -n "$temp_ref" ] && "$REAL_GIT" update-ref "$temp_ref" "$REPLACEMENT_OID"' \
	'  fi' \
	'fi' \
	'exec "$REAL_GIT" "$@"' >"$FAKE_BIN/git"
chmod +x "$FAKE_BIN/git"
expect_failure "临时 fetch ref 并发替换后 cleanup 不误删" "为避免误删并发结果" \
	env PATH="$FAKE_BIN:$PATH" REAL_GIT="$REAL_GIT" \
	MERGE_TREE_STATE="$MERGE_TREE_STATE" REPLACEMENT_OID="$REPLACEMENT_OID" "$SCRIPT"
RETAINED_REF="$(git -C "$REPO" for-each-ref --format='%(refname)' refs/frp-upstream-sync/)"
[ -n "$RETAINED_REF" ] || fail "并发替换的临时 ref 应被保留"
assert_eq "$REPLACEMENT_OID" "$(git -C "$REPO" rev-parse "$RETAINED_REF")" \
	"cleanup 不得删除或覆盖并发替换值"
git -C "$REPO" update-ref -d "$RETAINED_REF" "$REPLACEMENT_OID"
assert_eq "$BASE_OID" "$(git -C "$REPO" rev-parse refs/remotes/upstream/dev)" \
	"临时 ref 并发替换失败不应更新 tracking ref"
assert_clean "$REPO"

new_fixture hook-failure
make_remote_commit upstream.txt candidate hook-failure-upstream
HOOK="$REPO/.git/hooks/pre-merge-commit"
printf '#!/bin/sh\nexit 77\n' >"$HOOK"
chmod +x "$HOOK"
HOOK_START="$(git -C "$REPO" rev-parse HEAD)"
expect_failure "merge hook 失败后自动 abort 并恢复仓库" "已自动 abort" invoke "$REPO"
assert_eq "$HOOK_START" "$(git -C "$REPO" rev-parse HEAD)" "hook 失败后 HEAD 必须恢复"
assert_eq "$BASE_OID" "$(git -C "$REPO" rev-parse refs/remotes/upstream/dev)" \
	"hook 失败时 tracking ref 必须保持旧基线"
assert_clean "$REPO"
assert_no_temp_refs "$REPO"

new_fixture merge-failure-no-state
make_remote_commit upstream.txt candidate merge-failure-no-state-upstream
FAKE_BIN="$FIXTURE_ROOT/bin"
mkdir -p "$FAKE_BIN"
REAL_GIT="$(command -v git)"
printf '%s\n' \
	'#!/bin/sh' \
	'if [ "$1" = merge ]; then' \
	'  echo "simulated stateless merge failure" >&2' \
	'  exit 73' \
	'fi' \
	'exec "$REAL_GIT" "$@"' >"$FAKE_BIN/git"
chmod +x "$FAKE_BIN/git"
STATELESS_HEAD="$(git -C "$REPO" rev-parse HEAD)"
expect_failure "无 MERGE_HEAD 且无状态变化的 merge 失败报告安全失败" \
	"安全失败：HEAD/index/worktree 与 merge 前一致" \
	env PATH="$FAKE_BIN:$PATH" REAL_GIT="$REAL_GIT" "$SCRIPT"
assert_eq "$STATELESS_HEAD" "$(git -C "$REPO" rev-parse HEAD)" \
	"无状态 merge 失败不应改 HEAD"
assert_eq "$BASE_OID" "$(git -C "$REPO" rev-parse refs/remotes/upstream/dev)" \
	"无状态 merge 失败不应更新 tracking ref"
assert_clean "$REPO"
assert_no_temp_refs "$REPO"

new_fixture merge-failure-pollution
make_remote_commit upstream.txt candidate merge-failure-pollution-upstream
FAKE_BIN="$FIXTURE_ROOT/bin"
mkdir -p "$FAKE_BIN"
REAL_GIT="$(command -v git)"
RESET_MARKER="$FIXTURE_ROOT/reset-was-called"
printf '%s\n' \
	'#!/bin/sh' \
	'if [ "$1" = reset ]; then' \
	'  : >"$RESET_MARKER"' \
	'  exit 99' \
	'fi' \
	'if [ "$1" = merge ]; then' \
	'  printf "polluted by merge wrapper\\n" >conflict.txt' \
	'  "$REAL_GIT" add conflict.txt' \
	'  echo "simulated stateful merge failure" >&2' \
	'  exit 74' \
	'fi' \
	'exec "$REAL_GIT" "$@"' >"$FAKE_BIN/git"
chmod +x "$FAKE_BIN/git"
POLLUTED_HEAD="$(git -C "$REPO" rev-parse HEAD)"
expect_failure "无 MERGE_HEAD 但污染 index/worktree 的 merge 失败要求人工恢复" \
	"需人工恢复：HEAD/index/worktree 与 merge 前记录不一致或无法完整验证" \
	env PATH="$FAKE_BIN:$PATH" REAL_GIT="$REAL_GIT" RESET_MARKER="$RESET_MARKER" "$SCRIPT"
assert_eq "$POLLUTED_HEAD" "$(git -C "$REPO" rev-parse HEAD)" \
	"污染失败场景的 wrapper 不应改 HEAD"
git -C "$REPO" diff --cached --quiet && fail "污染失败留下的 index 改动不应被脚本清除"
[ ! -e "$RESET_MARKER" ] || fail "merge 污染失败时脚本绝不能调用 git reset"
assert_eq "$BASE_OID" "$(git -C "$REPO" rev-parse refs/remotes/upstream/dev)" \
	"污染 merge 失败不应更新 tracking ref"
if git -C "$REPO" rev-parse --quiet --verify MERGE_HEAD >/dev/null 2>&1; then
	fail "污染 wrapper 场景不应存在 MERGE_HEAD"
fi
assert_no_temp_refs "$REPO"

new_fixture concurrent-tracking
make_remote_commit upstream.txt candidate concurrent-upstream
CONCURRENT_OID="$(printf 'concurrent tracking\n' | git -C "$REPO" commit-tree \
	"$BASE_OID^{tree}" -p "$BASE_OID")"
HOOK="$REPO/.git/hooks/pre-merge-commit"
printf '#!/bin/sh\ngit update-ref refs/remotes/upstream/dev %s\n' "$CONCURRENT_OID" >"$HOOK"
chmod +x "$HOOK"
expect_failure "merge 期间 tracking ref 并发变化时 CAS 不覆盖" "为避免覆盖并发结果" \
	invoke "$REPO"
assert_eq "$CONCURRENT_OID" "$(git -C "$REPO" rev-parse refs/remotes/upstream/dev)" \
	"CAS 失败不得覆盖并发 tracking ref"
git -C "$REPO" merge-base --is-ancestor "$CANDIDATE_OID" HEAD ||
	fail "并发 tracking ref 场景中成功 merge 的 HEAD 应包含候选"
assert_clean "$REPO"
assert_no_temp_refs "$REPO"

new_fixture tag
git -C "$REPO" tag upstream-v0.70.1
expect_failure "发布 tag 不能作为同步目标" "不接受 tag" \
	invoke "$REPO" upstream-v0.70.1 --dry-run

new_fixture safe-target
MARKER="$TEST_ROOT/unsafe-target-ran"
expect_failure "不安全目标参数被拒绝且不执行注入内容" "非法的远端分支名" \
	invoke "$REPO" --target "upstream/dev;touch $MARKER" --dry-run
[ ! -e "$MARKER" ]
expect_failure "不安全远端名被拒绝" "非法的远端名" \
	invoke "$REPO" --target 'bad;remote/dev' --dry-run
expect_success "显式安全远端分支目标可用" "上游目标: upstream/dev" \
	invoke "$REPO" --target upstream/dev --dry-run

new_fixture build-tag-gate
printf '//go:build experiment\n\npackage experiment\n' >"$REPO/experiment.go"
expect_failure "未跟踪 build-tag 文件触发真实升级门禁" "未跟踪或被 ignored" \
	invoke "$REPO"

new_fixture ignored-build-tag-gate
printf 'ignored.go\n' >>"$REPO/.git/info/exclude"
printf '//go:build ignored_experiment\n\npackage ignored\n' >"$REPO/ignored.go"
expect_failure "ignored build-tag 文件也触发真实升级门禁" "ignored.go" invoke "$REPO"
assert_eq "1" "$(printf '%s\n' "$LAST_OUTPUT" | grep -c '^ignored.go$')" \
	"ignored build-tag 扫描结果应去重"

new_fixture merge-tree-capability
FAKE_BIN="$FIXTURE_ROOT/bin"
mkdir -p "$FAKE_BIN"
REAL_GIT="$(command -v git)"
printf '%s\n' \
	'#!/bin/sh' \
	'if [ "$1" = merge-tree ]; then' \
	'  echo "simulated unsupported merge-tree" >&2' \
	'  exit 129' \
	'fi' \
	'exec "$REAL_GIT" "$@"' >"$FAKE_BIN/git"
chmod +x "$FAKE_BIN/git"
CAPABILITY_HEAD="$(git -C "$REPO" rev-parse HEAD)"
expect_failure "merge-tree 能力错误与冲突错误分开报告" "merge-tree 能力预检失败" \
	env PATH="$FAKE_BIN:$PATH" REAL_GIT="$REAL_GIT" "$SCRIPT" --dry-run
assert_eq "$CAPABILITY_HEAD" "$(git -C "$REPO" rev-parse HEAD)" "能力错误不应改 HEAD"
assert_clean "$REPO"

new_fixture merge-tree-runtime-error
FAKE_BIN="$FIXTURE_ROOT/bin"
mkdir -p "$FAKE_BIN"
REAL_GIT="$(command -v git)"
MERGE_TREE_STATE="$FIXTURE_ROOT/merge-tree-capability-passed"
printf '%s\n' \
	'#!/bin/sh' \
	'if [ "$1" = merge-tree ]; then' \
	'  if [ ! -e "$MERGE_TREE_STATE" ]; then' \
	'    : >"$MERGE_TREE_STATE"' \
	'    exec "$REAL_GIT" "$@"' \
	'  fi' \
	'  echo "simulated merge-tree runtime error" >&2' \
	'  exit 70' \
	'fi' \
	'exec "$REAL_GIT" "$@"' >"$FAKE_BIN/git"
chmod +x "$FAKE_BIN/git"
expect_failure "能力预检后 merge-tree 工具错误不伪报为冲突" "merge-tree 工具执行错误" \
	env PATH="$FAKE_BIN:$PATH" REAL_GIT="$REAL_GIT" \
	MERGE_TREE_STATE="$MERGE_TREE_STATE" "$SCRIPT" --dry-run
assert_clean "$REPO"

new_fixture build-failure
make_remote_commit upstream.txt candidate build-failure-upstream
FAKE_BIN="$FIXTURE_ROOT/bin"
mkdir -p "$FAKE_BIN"
DOCKER_CALLED="$FIXTURE_ROOT/docker-called"
printf '%s\n' \
	'#!/bin/sh' \
	': >"$DOCKER_CALLED"' \
	'echo "simulated docker build failure" >&2' \
	'exit 43' >"$FAKE_BIN/docker"
chmod +x "$FAKE_BIN/docker"
BUILD_START_HEAD="$(git -C "$REPO" rev-parse HEAD)"
expect_failure_code "--build 失败使用独立退出码且不回滚已完成同步" 20 \
	"上游同步/merge/tracking已完成，仅构建验收失败" \
	env PATH="$FAKE_BIN:$PATH" DOCKER_CALLED="$DOCKER_CALLED" "$SCRIPT" --build
[ -e "$DOCKER_CALLED" ] || fail "fake docker 未实际执行，不能证明 build 退出码 20 路径"
case "$LAST_OUTPUT" in
	*"容器构建验收失败（docker 退出码 43）"*) ;;
	*) fail "build 失败诊断未保留 fake docker 原始退出码 43" ;;
esac
[ "$(git -C "$REPO" rev-parse HEAD)" != "$BUILD_START_HEAD" ] ||
	fail "构建失败前 merge 应已推进 HEAD"
git -C "$REPO" merge-base --is-ancestor "$CANDIDATE_OID" HEAD ||
	fail "构建失败后 HEAD 应包含候选"
assert_eq "$CANDIDATE_OID" "$(git -C "$REPO" rev-parse refs/remotes/upstream/dev)" \
	"构建失败后 tracking ref 应已前移"
assert_clean "$REPO"
assert_no_temp_refs "$REPO"

assert_eq "$EXPECTED_TESTS" "$PASS" "测试计数必须同步更新"
echo "1..$EXPECTED_TESTS"
