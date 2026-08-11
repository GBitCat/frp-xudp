# frp 开发环境镜像（基于 Ubuntu 26.04 LTS）
#
# 工具版本与 fatedier/frp 官方 CI（.github/workflows）保持一致：
#   - Go 1.25.12             go.mod: go 1.25.0 / CI: go-version '1.25'
#   - Node.js 22.23.2 LTS    CI: node-version '22'
#   - golangci-lint v2.11.4  CI: version v2.11
#   - make / git / build-essential 等基础工具
#
# 构建时建议配合 scripts/build-dev-image.sh 使用：
#   docker build --network=host --build-arg PROXY=http://127.0.0.1:8118 -t frp-dev:ubuntu-26.04 .
# 容器内所有下载（apt / go / npm）都会走宿主机 127.0.0.1:8118 代理。

ARG BASE_IMAGE=ubuntu:26.04
FROM ${BASE_IMAGE}

ARG PROXY=http://127.0.0.1:8118
ARG GO_VERSION=1.25.12
ARG NODE_VERSION=22.23.2
ARG GOLANGCI_LINT_VERSION=2.11.4

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    http_proxy=${PROXY} \
    https_proxy=${PROXY} \
    HTTP_PROXY=${PROXY} \
    HTTPS_PROXY=${PROXY} \
    no_proxy=localhost,127.0.0.1,::1 \
    NO_PROXY=localhost,127.0.0.1,::1 \
    GOPATH=/go \
    PATH=/usr/local/go/bin:/go/bin:${PATH}

# 基础系统工具
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      make \
      build-essential \
      pkg-config \
      xz-utils \
      jq \
      vim \
      tzdata; \
    rm -rf /var/lib/apt/lists/*

# Go 工具链（官方二进制，与 frp 要求的 go 1.25 一致）
RUN set -eux; \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz; \
    rm -rf /usr/local/go; \
    tar -C /usr/local -xzf /tmp/go.tar.gz; \
    rm -f /tmp/go.tar.gz

# Node.js + npm（frp dashboard 前端构建依赖 Node 22）
RUN set -eux; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" -o /tmp/node.tar.xz; \
    tar -C /usr/local --strip-components=1 -xJf /tmp/node.tar.xz; \
    rm -f /tmp/node.tar.xz

# golangci-lint v2（与 CI 的 v2.11 对应，自带 gci/gofumpt/goimports 格式化器）
RUN set -eux; \
    curl -fsSL "https://github.com/golangci/golangci-lint/releases/download/v${GOLANGCI_LINT_VERSION}/golangci-lint-${GOLANGCI_LINT_VERSION}-linux-amd64.tar.gz" -o /tmp/golangci-lint.tar.gz; \
    mkdir -p /tmp/golangci-lint; \
    tar -xzf /tmp/golangci-lint.tar.gz -C /tmp/golangci-lint; \
    install -Dm 0755 "/tmp/golangci-lint/golangci-lint-${GOLANGCI_LINT_VERSION}-linux-amd64/golangci-lint" /go/bin/golangci-lint; \
    rm -rf /tmp/golangci-lint /tmp/golangci-lint.tar.gz

# frp Makefile 中 make fmt-more / make gci 需要的独立命令
RUN set -eux; \
    go install mvdan.cc/gofumpt@latest; \
    go install github.com/daixiang0/gci@latest; \
    go install golang.org/x/tools/cmd/goimports@latest

# npm 使用官方 registry（走镜像内置的 https_proxy）
RUN npm config set registry https://registry.npmjs.org/

WORKDIR /workspace
CMD ["/bin/bash"]
