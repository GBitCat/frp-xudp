# frp-xudp 开发环境（dev/）

本目录包含本仓库（frp + XUDP 扩展）的开发环境工具链与测试配置，
与上游 frp 文件隔离，便于跟随上游发布 tag 升级。

## 目录说明

```
dev/
├── Makefile          # pull-base / build / run 快捷命令
├── README.md         # 本说明
└── test/             # 三容器测试配置（frpsB / frpcA / frpcC）
```

仓库根目录还有：

```
Dockerfile            # 开发环境镜像（Ubuntu 26.04 + Go 1.25.12 + Node 22）
scripts/              # 代理拉镜像 / 构建镜像 / 上游升级脚本
UPSTREAM_SYNC.md      # 跟随上游发布 tag 的升级维护说明
FRP_XUDP_Extension_Design_Document.md  # XUDP 设计文档
```

## 开发环境镜像

基于 Ubuntu 26.04 LTS，工具版本与 frp 官方 CI 对齐：Go 1.25.12、
Node.js 22.23.2、golangci-lint v2.11.4、make/git/build-essential 等。

## 使用方法

```bash
cd dev

make pull-base     # 通过 127.0.0.1:8118 代理拉取 ubuntu:26.04 并导入 Docker
make build         # 构建 frp-dev:ubuntu-26.04 镜像（自动 --network=host + 代理）
make run           # 启动开发容器（挂载仓库根目录到 /workspace）
```

进入容器后即可使用 frp 常规开发命令：`make frps` / `make frpc` /
`make test` / `golangci-lint run` 等。

## 三容器测试

`dev/test/` 下的配置用于运行 frpsB（服务端）、frpcA（xudp proxy +
UDP echo）、frpcC（xudp visitor）三个容器，验证 P2P 与 relay 两条路径，
详见 `UPSTREAM_SYNC.md` 第 6 节。
