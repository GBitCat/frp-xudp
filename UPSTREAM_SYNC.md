# 跟随上游发布 tag 的升级维护说明

本文档说明如何在保留 XUDP 扩展的前提下，跟随 fatedier/frp 上游的**发布 tag**
（而非 dev 分支）进行更新。

## 1. 策略概述

- 跟随对象：上游稳定发布 tag，如 `v0.70.1`（发布 tag 列表见
  `git ls-remote --tags origin`）。
- 不跟随 `dev`：`dev` 变化频繁，且可能包含未稳定 API，升级成本高。
- 升级节奏：每个上游发布后评估一次；优先看 release notes 中是否涉及
  配置类型、nathole、wire protocol、visitor/代理工厂等我们依赖的区域。

## 2. 当前基线

- 源码目录：`frp-src/`（开发容器 `frp-dev` 挂载为 `/workspace/src`）
- 当前基线提交：`71a2bf3`（2026-08-09，上游 dev 分支）
- 仓库状态：浅克隆（shallow），带 `origin` remote
- 我们的改动：6 个修改文件 + 4 个新增路径（详见第 5 节）

## 3. 升级前置准备（只需做一次）

```bash
cd frp-src

# 1) 补全历史，浅克隆无法正常 merge/diff 上游旧提交
git fetch --unshallow origin

# 2) 建立自己的发布维护分支（建议长期使用）
git checkout -b release/xudp
```

## 4. 每次升级的标准流程

```bash
cd frp-src

# 1) 拉取上游最新 tag（如 v0.70.1，按需替换版本号）
# 注意: 从 upstream remote 拉取，并映射为 upstream- 前缀，
#       避免与本仓库同名发布 tag（v0.70.1）冲突
git fetch upstream refs/tags/v0.70.1:refs/tags/upstream-v0.70.1

# 2) 切到维护分支并合并
git checkout release/xudp
git merge upstream-v0.70.1

# 3) 解决冲突（冲突文件见第 5 节清单），确认后提交
git add -A
git commit

# 4) 容器内编译验证
docker exec -w /workspace/src frp-dev bash -lc '
  CGO_ENABLED=0 go build -buildvcs=false -trimpath -ldflags "-s -w" \
    -tags "frps,noweb" -o /workspace/bin/frps ./cmd/frps
  CGO_ENABLED=0 go build -buildvcs=false -trimpath -ldflags "-s -w" \
    -tags "frpc,noweb" -o /workspace/bin/frpc ./cmd/frpc
  go test ./pkg/... ./client/... ./server/... 2>&1 | tail -20'

# 5) 三容器回归（见第 6 节）

# 6) 通过后打上自己的发布 tag（便于回滚）
git tag xudp-v0.70.1
```

合并方式二选一：

- `git merge upstream-v0.70.1`：保留上游提交历史，冲突解决一次即可；
- `git rebase upstream-v0.70.1`：历史线性，但每次升级都要重放全部本地提交，
  冲突可能反复出现。**建议用 merge。**

> 版本号说明：本仓库的发布 tag 使用与上游一致的版本号（如 `v0.70.1`），
> 上游 tag 统一映射为 `upstream-v0.70.1` 避免冲突。

## 5. 冲突与风险点清单

合并冲突最可能出现在以下 6 个修改文件（均在 `frp-src/` 下）：

| 文件 | 冲突原因 | 解决要点 |
| --- | --- | --- |
| `pkg/config/v1/proxy.go` | 上游新增代理类型/字段 | 保留 `XUDPProxyConfig`，跟随上游新类型 |
| `pkg/config/v1/visitor.go` | 上游新增 visitor 类型 | 保留 `XUDPVisitorConfig` |
| `pkg/config/v1/validation/proxy.go` | switch 新增 case | 补上 xudp case |
| `pkg/config/v1/validation/visitor.go` | switch 新增 case | 补上 xudp case |
| `client/visitor/visitor.go` | 工厂 switch 新增 case | 保留 `XUDPVisitor` 构造分支 |
| `server/proxy/proxy.go` | `joinUserConnection` 的 SUDP 桥接演进 | 确认 xudp 仍走 UDP 帧桥接分支 |

以下新增文件不会产生 git 冲突，但**必须检查编译与语义**：

- `pkg/xudp/session/table.go`：独立包，通常无需改动
- `client/proxy/xudp.go`、`client/visitor/xudp.go`、`server/proxy/xudp.go`：
  依赖上游 `nathole`（Prepare/ExchangeInfo/MakeHole）与 `msg.NatHole*` 消息，
  上游改签名/字段时编译会报错，需要按新 API 适配

其他需要留意的上游变更点：

- `go.mod` 的 Go 版本要求（如升到 go 1.26）
- wire protocol v2 相关消息格式（`pkg/msg`、`pkg/proto/wire`）
- `XUDPProxyConfig` 字段与 TOML 配置格式的兼容性

## 6. 三容器回归测试

升级后必须验证 P2P 与 relay 两条路径，使用 `test/` 下配置与
`/tmp/frp-bin` 产物：

```bash
# 重建三个测试容器（挂载新编译的二进制）
docker rm -f frpsB frpcA frpcC
docker run -d --name frpsB --network frp-test-net \
  -v /tmp/frp-bin/frps:/usr/local/bin/frps:ro \
  -v "$PWD/test/frpsB/frps.toml:/etc/frp/frps.toml:ro" \
  ubuntu:26.04 sh -c '/usr/local/bin/frps -c /etc/frp/frps.toml'
docker run -d --name frpcA --network frp-test-net \
  -v /tmp/frp-bin/frpc:/usr/local/bin/frpc:ro \
  -v /tmp/frp-bin/udp_echo:/usr/local/bin/udp_echo:ro \
  -v /tmp/frp-bin/frpcA-start.sh:/usr/local/bin/start.sh:ro \
  -v "$PWD/test/frpcA/frpc.toml:/etc/frp/frpc.toml:ro" \
  ubuntu:26.04 sh -c '/usr/local/bin/start.sh'
docker run -d --name frpcC --network frp-test-net \
  -v /tmp/frp-bin/frpc:/usr/local/bin/frpc:ro \
  -v "$PWD/test/frpcC/frpc.toml:/etc/frp/frpc.toml:ro" \
  ubuntu:26.04 sh -c '/usr/local/bin/frpc -c /etc/frp/frpc.toml'

# 1) P2P 路径：配置 STUN 为 stun.easyvoip.com:3478 后
FRPCC_IP=$(docker inspect frpcC --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
docker exec frp-dev /workspace/bin/udp_send "$FRPCC_IP:9000" "p2p-check"
# 期望：frpcC 日志出现 "tunnel established via p2p"，返回 "echo: p2p-check"

# 2) Relay 路径：把 test/frpcA/frpc.toml 与 test/frpcC/frpc.toml 中的
#    natHoleStunServer 改为不可达地址（如 192.0.2.1:3478）后重启 frpcA/frpcC
docker restart frpcA frpcC
docker exec frp-dev /workspace/bin/udp_send "$FRPCC_IP:9000" "relay-check"
# 期望：frpcC 日志出现 "falling back to relay"，返回 "echo: relay-check"
```

判定标准：两条路径都能收到 `echo: <msg>` 且日志显示对应路径；
relay 模式下连接不再一包后断开（历史 bug，见开发记录）。

## 7. 回滚

```bash
# 合并后发现问题，回退到合并前
git merge --abort

# 已提交后发现问题，回退维护分支到上次发布点
git log --oneline -5
git reset --hard <上次的 xudp tag 或提交>

# 重新拉取旧二进制并重启容器
docker exec -w /workspace/src frp-dev bash -lc 'cd /workspace/src && git checkout <旧tag> && make frps frpc'
docker restart frpsB frpcA frpcC
```

## 8. 升级前检查清单

- [ ] 查看上游 release notes，确认是否涉及 config/proxy/visitor/nathole/wire
- [ ] `git fetch --unshallow origin`（首次）
- [ ] 在维护分支上 `git merge <tag>`
- [ ] 按第 5 节清单解决冲突并检查三个 xudp 新文件
- [ ] 容器内编译 frps/frpc + 单测
- [ ] 三容器 P2P 与 relay 回归
- [ ] 通过后打自己的 tag（`xudp-v<版本>`）
