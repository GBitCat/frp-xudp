# frp-xudp 开发环境（dev/）

本目录包含本仓库（frp + XUDP 扩展）的开发环境工具链与测试配置，
与上游 frp 文件隔离，便于在 `beta` 上持续跟随 `upstream/dev`。

> XUDP 为 frp 的独立扩展，未合入上游 fatedier/frp，仅在本仓库维护。

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
UPSTREAM_SYNC.md      # beta 跟随 upstream/dev 的同步维护说明
FRP_XUDP_Extension_Design_Document.md  # XUDP 设计文档
```

## 开发环境镜像

基于 Ubuntu 26.04 LTS，工具版本与 frp 官方 CI 对齐：Go 1.25.12、
Node.js 22.23.2、golangci-lint v2.11.4、make/git/build-essential 等。

## 使用方法

```bash
cd dev

make pull-base     # 拉取 ubuntu:26.04 并导入 Docker
make build         # 构建 frp-dev:ubuntu-26.04 镜像
make run           # 启动开发容器（挂载仓库根目录到 /workspace）
```

进入容器后即可使用 frp 常规开发命令：`make frps` / `make frpc` /
`make test` / `golangci-lint run` 等。

## 代理配置（可选）

默认不代理。如果所在网络需要代理才能访问外网，请在仓库根目录创建
`.env`（参考 `.env.example`）或通过环境变量设置 `PROXY`：

```bash
# .env 内容示例（请替换为你的代理地址）
PROXY=http://host:port
```

配置代理后，`scripts/` 下的脚本会自动读取；构建镜像时使用
`--network=host` 以便容器内访问宿主机代理。

## 三容器测试

`dev/test/` 下的配置用于运行 frpsB（服务端）、frpcA（xudp proxy +
UDP echo）、frpcC（xudp visitor）三个容器，验证 P2P 与 relay 两条路径，
详见 `UPSTREAM_SYNC.md` 第 6 节。
