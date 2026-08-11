PROXY ?= http://127.0.0.1:8118
IMAGE ?= frp-dev:ubuntu-26.04

.PHONY: pull-base build run

# 通过代理拉取基础镜像并导入 Docker（当前守护进程无代理配置，需 root 才能改）
pull-base:
	../scripts/pull-with-proxy.sh ubuntu:26.04

# 构建开发环境镜像（自动使用 --network=host 与代理）
build:
	../scripts/build-dev-image.sh $(IMAGE)

# 启动开发容器：挂载当前目录到 /workspace，并共享宿主机网络以访问代理
run:
	docker run --rm -it --network=host -v "$$(pwd):/workspace" $(IMAGE)
