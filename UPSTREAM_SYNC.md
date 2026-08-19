# beta 跟随 upstream/dev 的上游同步说明

本文档说明如何在不重写现有历史、保留 XUDP 扩展的前提下，将
`fatedier/frp` 的 `upstream/dev` 持续同步到本仓库 `beta`。

## 1. 唯一同步策略

- 长期维护分支是 `beta`，常规同步目标固定为 `upstream/dev`。
- 使用普通 merge 保留双方历史；不对已共享的 `beta` 做 rebase、强制更新或
  `reset --hard`。
- 上游发布 tag（例如 `upstream-v0.70.1`）只用于兼容性对照、测试记录和发布
  里程碑。release tag 可能来自与 `dev` 不同的发布线，不能直接 merge 到
  `beta`。
- `origin/dev` 是本仓库自己的开发引用，不替代 `upstream/dev`，也不是脚本的
  默认同步源。
- 只有经过人工确认的远端开发分支才能通过 `--target REMOTE/BRANCH` 临时指定；
  tag、`refs/tags/...` 和任意 ref 表达式都不是合法目标。

## 2. 当前上游基线

2026-08-20 完成正式同步后的引用关系如下：

| 引用 | 提交 | 与同步合并点的关系 |
| --- | --- | --- |
| `beta` 的上游同步合并点 | `483e4668` | 已合入下列远端 `upstream/dev`；后续文档提交位于其上 |
| `origin/dev` | `fd5fba91` | 是同步合并点的祖先；合并点单侧多 13 个提交 |
| 本地及远端 `upstream/dev` | `758f07d5` | 是同步合并点的祖先；合并点单侧多 33 个提交 |
| `upstream-v0.70.1^{}` | `fa3bcca2` | 与同步合并点已分叉：合并点侧 58、tag 侧 12 个提交 |

远端 `758f07d5` 先以合成树完成 Docker 全量相关包测试、目标包 Race Detector
和 frps/frpc 构建，再由受保护同步脚本正式合入 `beta`；合并没有直接路径冲突，
远端跟踪引用也已通过 CAS 前移。不需要合并 `upstream-v0.70.1`。

源码目录是 `frp-src/`，开发容器 `frp-dev` 将其挂载为 `/workspace/src`。

## 3. 脚本安全边界

`scripts/upgrade-from-upstream.sh` 的真实模式强制只允许在 `beta` 执行，并采用
以下保护：

1. 目标默认为 `upstream/dev`；远端名使用保守字符集，分支名必须通过
   `git check-ref-format`。输入最终转换为 `refs/heads/<branch>` 与
   `refs/remotes/<remote>/<branch>`，不会作为任意 ref 或 shell 代码解释。
2. dry-run 不联网、不更新引用、不 merge，但会对本地远端跟踪目标真正执行
   `git merge-base` 和 `git merge-tree --write-tree`。脚本先探测所需的
   merge-tree 能力，并把退出码 1 报为冲突、其他非零退出码报为工具错误。
   `--write-tree` 不改工作树、HEAD 或分支，但可能向 Git 对象库写入临时 tree
   等对象；因此 dry-run 的准确含义是“不改工作树和引用”，不是对象库字节级只读。
   merge-tree 只读取给定的提交树，当前 dirty、未跟踪或 ignored 内容不参与
   dry-run 合并结果。
3. 真实模式在 fetch 前拒绝 dirty 工作树，并同时扫描普通未跟踪文件和 ignored
   文件；任何未纳入版本控制且包含 `//go:build` 的 Go 文件都会触发发布门禁。
4. fetch 使用精确的 `refs/heads/<branch>`、`--porcelain`、`--no-tags`、空
   `--refmap=` 和 `--no-write-fetch-head`，把候选写入进程唯一的
   `refs/frp-upstream-sync/...` 临时引用。porcelain stdout 单独写入 `mktemp` 文件，
   stderr 保持可见，两份临时输出文件均由退出 trap 清理；脚本不读取 `FETCH_HEAD`。
   fetch 成功后，脚本严格解析恰好一条 local-ref 完全等于临时 ref 的四字段记录。
   因该 ref 在调用 fetch 前已确认不存在，old OID 必须严格等于当前对象格式长度的
   全零 OID；非零 old 表明“检查不存在”到 fetch 事务之间发生了竞态，即使 fetch
   最终快进成功也保持 unowned 并拒绝后续 merge/tracking。解析同时拒绝缺失、重复、
   额外字段、零 new OID、非法 OID 或非 commit。expected OID 和
   candidate OID 都只来自这份事务输出，不使用 `eval`，也绝不从当前 ref 现读认领。
   随后读取当前临时 ref 仅作相等核验；只有它仍等于 porcelain new OID 时才建立
   owned 状态。若 fetch 返回前被并发替换、当前值不可读或不等，脚本保持 unowned、
   拒绝 merge 并保留该 ref。已建立 owned 后，退出 trap 只用 expected OID 做 CAS
   删除，若值后来又被替换则保留并告警。fetch 返回失败时脚本统一退出 `1`，诊断中
   保留原始 git 退出码，但绝不认领或删除失败 fetch 留下的 ref；若检测到遗留 ref，
   只明确告警、保守保留并要求人工核对后以明确 OID 做 CAS 清理。
5. 脚本先确认旧远端跟踪基线是候选的祖先，再完成两轮 merge-tree 与分支、HEAD、
   工作树、基线、临时候选复核。预检冲突及所有复核完成前，绝不更新
   `refs/remotes/...`；上游分支回退、改写或分叉会被拒绝，tag 不会被创建或覆盖。
6. 真实 merge 成功（或确认目标已包含、无需 merge）后，才以旧基线为 expected
   old value，对远端跟踪引用做 CAS。若并发操作已前移到同一候选则安全接受；若改成
   其他值则不覆盖，保留已成功的 merge 并要求人工核对。
7. `git merge` 前会记录 HEAD 和 clean porcelain 状态。失败时若存在 `MERGE_HEAD`，
   脚本自动执行 `git merge --abort`；abort 成功会明确报告 HEAD/工作树已恢复，失败
   则要求停止并人工恢复。若没有 `MERGE_HEAD`，脚本会重新核对 HEAD、index 和
   worktree：全部不变才报告“安全失败”，有变化或无法验证则报告“需人工恢复”。
   脚本绝不执行 `reset`，这些失败路径也不会更新远端跟踪引用。
8. `--build` 在 merge（或无需 merge）和 tracking CAS 完成后才运行。docker 构建
   失败会保留其原始退出码到诊断消息，并以脚本专用退出码 `20` 返回，明确说明只有
   构建验收失败；已完成的 HEAD 与 tracking 更新不会回滚。

脚本不再 `source .env`，避免把配置文件当 shell 代码执行。需要代理时显式传入
`PROXY` 环境变量；该值作为单个 Git 配置参数传递，不经过 `eval`。

## 4. 标准流程

先在当前本地引用上做不联网、不改工作树和引用的冲突预检（注意上文所述，
`merge-tree --write-tree` 仍可能写 Git 对象库）：

```bash
cd frp-src
bash scripts/upgrade-from-upstream.sh --dry-run
```

确认处于 `beta`、工作树完全干净后，才执行真实同步：

```bash
bash scripts/upgrade-from-upstream.sh

# 需要同步后立即编译时
bash scripts/upgrade-from-upstream.sh --build

# 需要代理时（不会从 .env 自动加载）
PROXY=http://host:port bash scripts/upgrade-from-upstream.sh
```

受控测试仓库可在 dry-run 中显式覆盖允许分支；真实模式会拒绝这两个覆盖入口并
始终强制 `beta`：

```bash
UPSTREAM_SYNC_ALLOWED_BRANCH=test-beta \
  bash scripts/upgrade-from-upstream.sh --dry-run

# 等价的参数形式
bash scripts/upgrade-from-upstream.sh --allow-branch test-beta --dry-run
```

经过人工核对的其他远端开发分支可显式指定：

```bash
bash scripts/upgrade-from-upstream.sh --target trusted/dev --dry-run
```

显式目标必须已有本地远端跟踪基线。脚本不会在缺少基线时猜测历史，也不会把
release tag 强制映射成分支。

`--build` 是同步后的验收步骤，不是事务的一部分。如果它以退出码 `20` 失败，说明
fetch、merge（或无需 merge）和 tracking 更新已经完成，只应修复构建问题并重新验收；
脚本不会、操作者也不应为一次构建失败回滚已经完成的上游同步。

## 5. XUDP 冲突与语义检查清单

上游同步时重点审查以下区域。即使 merge-tree 和编译都通过，也需要确认语义：

| 文件或目录 | 风险与检查要点 |
| --- | --- |
| `pkg/config/v1/proxy.go`、`visitor.go` | 保留 XUDP 配置类型和字段，同时吸收上游新增类型 |
| `pkg/config/v1/validation/proxy.go`、`visitor.go` | 校验 switch 必须同时覆盖上游类型与 XUDP |
| `client/proxy/xudp.go` | 核对 nathole、UDP 生命周期、transport 接口和角色选择 |
| `client/visitor/visitor.go`、`sudp.go`、`xudp.go` | 保留 XUDP 工厂分支，核对 P2P/relay 恢复及关闭语义 |
| `server/proxy/proxy.go`、`udp.go`、`xudp.go` | 核对用户连接桥接、socket 所有权与 relay 生命周期 |
| `pkg/msg/msg.go`、`pkg/proto/udp/udp.go` | 保留 fingerprint/UDP 扩展，检查 wire v2 编解码兼容性 |
| `pkg/nathole/` | 上游 Prepare/ExchangeInfo/MakeHole API 或响应字段变化会影响 XUDP |
| `pkg/xudp/session/`、`state/`、`transport/` | 独立文件通常不产生文本冲突，但必须检查状态机、QUIC DATAGRAM、MTU 和 peer identity |
| `go.mod`、`go.sum` | 核对 Go 版本、quic-go 等依赖升级及最小版本兼容性 |
| `README.md`、`dev/`、`scripts/`、发布 workflow | 保留本 fork 的定位、测试边界和发布门禁 |

当前工作树中的 build-tag 文件尤其需要在发布前纳入提交，例如：

- `client/proxy/xudp_role_test.go`（`!frps`）
- `pkg/xudp/transport/pmtud_default.go`（`!xudp_pmtud_experiment`）
- `pkg/xudp/transport/pmtud_experiment.go`（`xudp_pmtud_experiment`）

这是一项发布门禁，而不只是“文件是否能在当前工作树编译”的检查。若默认和实验
实现中任一文件未跟踪或被 ignore，干净 checkout 的构建结果会与开发机不同。真实
升级脚本会直接拒绝这种状态；发布前还应确认：

```bash
git status --porcelain --untracked-files=all
git ls-files --error-unmatch \
  client/proxy/xudp_role_test.go \
  pkg/xudp/transport/pmtud_default.go \
  pkg/xudp/transport/pmtud_experiment.go
```

## 6. 编译与三容器回归

两个 `mktemp` 之间由 bootstrap EXIT trap 保护；第二个临时文件创建失败时保留原始
mktemp 退出码并清理第一个文件，不依赖 `set -e` 的隐式行为。

容器内执行与发布 build tag 一致的编译和相关 Go 测试。升级脚本回归当前共 30 项，
覆盖成功 fetch 的 porcelain OID/CAS 清理、fetch 前预建 ref 导致的非零 old OID、
fetch 返回前的 ref 替换窗口、重复 porcelain、后续临时 ref 并发替换、失败 fetch
遗留 ref 保守保留、第二个 mktemp 失败清理、无状态与污染型 merge 失败，以及 fake docker
构建失败后的 HEAD/tracking/退出码语义：

```bash
docker exec -w /workspace/src frp-dev bash -lc '
  bash -n scripts/upgrade-from-upstream.sh scripts/test-upgrade-from-upstream.sh
  bash scripts/test-upgrade-from-upstream.sh
  CGO_ENABLED=0 go build -buildvcs=false -trimpath -ldflags "-s -w" \
    -tags "frps,noweb" -o /workspace/bin/frps ./cmd/frps
  CGO_ENABLED=0 go build -buildvcs=false -trimpath -ldflags "-s -w" \
    -tags "frpc,noweb" -o /workspace/bin/frpc ./cmd/frpc
  go test ./pkg/... ./client/... ./server/...'
```

升级后使用 `dev/test/` 下配置和 Docker 脚本验证 relay 路径及可观测的
UDP 连续多包行为。脚本默认只读检查现有的 `frpsA`、`frpcB`、`frpC`，
不会重建容器：

```bash
# 现有容器只读探测：连续 UDP 多包 + 容器/挂载检查
bash dev/test/run-xudp-recovery-docker.sh --existing

# 使用当前工作树构建，并仅替换明确的 frpsA、frpcB、frpC。
# --recreate 会删除并重建这三个目标容器，执行前需确认环境允许。
bash dev/test/run-xudp-recovery-docker.sh --p2p --recreate
bash dev/test/run-xudp-recovery-docker.sh --relay --recreate
```

判定标准：relay 场景应能收到多个 `echo: <msg>`，并在日志中出现
`falling back to relay` 与 `relay visitor conn established`。P2P 场景只有
在 Docker 环境实际提供可用 STUN/打洞条件并出现对应日志时才能判定通过；
STUN 超时后落到 relay 不得伪造为 P2P 成功。脚本明确不声称覆盖实时
P2P→Relay 或 Relay→P2P 在线切换。

这些检查只覆盖 Docker bridge 内的受控路径，不代表真实公网 NAT、CGNAT、
VPN、5G/Wi-Fi 或其他网络接口迁移能力。

## 7. tag 兼容性对照与发布

发布 tag 不进入 `beta` 的同步链。可用只读命令检查兼容范围：

```bash
git merge-base beta 'upstream-v0.70.1^{}'
git rev-list --left-right --count 'beta...upstream-v0.70.1^{}'
git diff --stat 'upstream-v0.70.1^{}..beta'
```

完成编译、单测、Docker 回归和 build-tag 跟踪门禁后，再在已审核的 `beta`
提交上创建本仓库自己的里程碑 tag，例如 `xudp-v0.2.0`。上游版本只写入兼容性
记录，不把同名 tag 当作本仓库内容基线。

## 8. 失败处理与检查清单

预检冲突时脚本不会改工作树或分支，应先人工审查冲突区域，不要绕过检查。若真实
merge 因钩子等预检外原因失败且留下 `MERGE_HEAD`，脚本会自动执行
`git merge --abort`；只有明确报告 abort 失败时才需要停止操作并人工恢复。tracking
ref 的并发改动不会被覆盖；若 merge 已成功而最终 CAS 失败，应保留当前 HEAD，先核对
tracking ref 指向和候选 OID，再决定后续操作。
若 merge 失败且没有 `MERGE_HEAD`，只有脚本明确报告 HEAD/index/worktree 均未变化的
“安全失败”才可按未开始 merge 处理；“需人工恢复”表示状态已变化或无法完整验证，
应立即停止并人工检查，绝不使用脚本自动 reset。`--build` 的退出码 `20` 只表示构建
验收失败，之前的 merge/tracking 结果已经生效且不会回滚。
已经共享的 merge 提交需要回退时使用新的 revert 提交（`git revert -m 1 <merge>`），
不要重写 `beta` 历史。

- [ ] 仅在 `beta` 上，以 `upstream/dev` 为常规目标
- [ ] dry-run 已真实通过 merge-base/merge-tree 预检，并理解 dirty 内容不参与结果
- [ ] 真实同步前工作树干净，未跟踪及 ignored 的 build-tag Go 文件均不存在
- [ ] fetch 后旧远端跟踪基线可前向到候选提交
- [ ] tracking ref 只在 merge 成功/无需 merge 后由 baseline CAS 到 candidate
- [ ] 按第 5 节检查 XUDP 文本冲突和无文本冲突的语义变化
- [ ] 容器内编译与相关 Go 测试通过
- [ ] Docker relay 连续多包回归通过；P2P 只在具备打洞条件时记录为通过
- [ ] 发布 tag 仅作本仓库里程碑，上游 tag 仅作兼容性对照
