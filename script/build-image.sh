#!/bin/bash
# 构建 lua-router 发布镜像并推到 ACR（命名空间 pub/，docker-acr 口径）。
#
# 用法：
#   script/build-image.sh                 # 标签 = <当天YYYYMMDD>-<HEAD短sha>（对齐线上 20261009-d88c1ae 的命名）
#   IMAGE_TAG=... script/build-image.sh   # 显式覆盖标签
#
# 前置：门禁全绿的锚点 commit 在 HEAD，且已跟踪文件无改动（发版镜像只从干净绿锚点构建）。
# 构建上下文是仓库根：Dockerfile 的 COPY 按根目录相对路径写，认证基座 authz:latest 本机已有。
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

RG=wasu-wtvdev-registry-test-registry.cn-hangzhou.cr.aliyuncs.com
SHORT=$(git rev-parse --short=7 HEAD)
TAG=${IMAGE_TAG:-$(date -u +%Y%m%d)-$SHORT}
IMAGE="$RG/pub/lua-router:$TAG"

DIRTY=$(git status --porcelain --untracked-files=no | head -1)
[ -z "$DIRTY" ] || { echo "已跟踪文件有未提交改动（首条：$DIRTY）；发版镜像只从干净绿锚点构建" >&2; exit 1; }

echo "== build $IMAGE"
docker build -t "$IMAGE" .
echo "== push $IMAGE"
docker push "$IMAGE" >/dev/null 2>&1   # ACR 进度条用 \\r 刷新，成功即静默收工
docker manifest inspect "$IMAGE" >/dev/null && echo "== manifest ok: $IMAGE"
echo "$IMAGE"
