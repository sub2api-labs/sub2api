#!/bin/bash
# Sub2API 本地构建 + 远程部署脚本
# 用法: ./deploy.sh -t <IP> -u <user>
set -euo pipefail

# ============================================================================
# 配置区
# ============================================================================
DEPLOY_TARGET="${DEPLOY_TARGET:-}"
DEPLOY_USER="${DEPLOY_USER:-root}"
DEPLOY_PORT="${DEPLOY_PORT:-22}"
REMOTE_DIR="${REMOTE_DIR:-/opt/sub2api}"
GOARCH="${GOARCH:-amd64}"

# ============================================================================
# 颜色
# ============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC} $*"; exit 1; }

# ============================================================================
# 解析命令行参数
# ============================================================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target|-t) DEPLOY_TARGET="$2"; shift 2;;
    --user|-u)   DEPLOY_USER="$2";   shift 2;;
    --port|-p)   DEPLOY_PORT="$2";   shift 2;;
    --arch)      GOARCH="$2";        shift 2;;
    --remote)    REMOTE_DIR="$2";    shift 2;;
    --help|-h)
      echo "用法: $0 [选项]"
      echo "  -t, --target IP    服务器地址"
      echo "  -u, --user USER    SSH 用户名，默认 root"
      echo "  -p, --port PORT    SSH 端口，默认 22"
      echo "      --arch ARCH    目标架构 amd64/arm64，默认 amd64"
      echo "      --remote PATH  远程安装目录，默认 /opt/sub2api"
      echo "  -h, --help         显示帮助"
      exit 0
      ;;
    *) error "未知参数: $1";;
  esac
done

# ============================================================================
# 前置检查
# ============================================================================
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

command -v go   &>/dev/null || error "需要安装 Go"
command -v pnpm &>/dev/null || error "需要安装 pnpm"
command -v scp  &>/dev/null || error "需要安装 scp"
command -v ssh  &>/dev/null || error "需要安装 ssh"

[ -z "$DEPLOY_TARGET" ] && error "请指定服务器地址: -t <IP>"

info "目标: ${DEPLOY_USER}@${DEPLOY_TARGET}:${DEPLOY_PORT}"
info "架构: ${GOARCH}"
info "远程目录: ${REMOTE_DIR}"

# ============================================================================
# 1. 构建前端
# ============================================================================
info "构建前端..."
cd frontend
pnpm install --frozen-lockfile 2>/dev/null || pnpm install
pnpm build
cd ..
success "前端构建完成"

# ============================================================================
# 2. 编译后端（嵌入前端）
# ============================================================================
info "编译 Linux/${GOARCH} 二进制..."
cd backend

VERSION=$(cat cmd/server/VERSION 2>/dev/null | tr -d '\r\n' || echo "dev")
LDFLAGS="-s -w -X main.Version=${VERSION} -X main.BuildType=release"

GOOS=linux GOARCH=${GOARCH} CGO_ENABLED=0 \
  go build -tags=embed -ldflags="${LDFLAGS}" -trimpath -o sub2api ./cmd/server

BINARY_SIZE=$(du -h sub2api | cut -f1)
success "编译完成: sub2api (${BINARY_SIZE}, v${VERSION})"
cd ..

# ============================================================================
# 3. 上传到服务器（先传到 home 目录，避免权限问题）
# ============================================================================
SSH_OPTS="-P ${DEPLOY_PORT} -o StrictHostKeyChecking=no -o ConnectTimeout=10"

info "上传到 ${DEPLOY_USER}@${DEPLOY_TARGET}:/tmp/sub2api.new ..."
scp ${SSH_OPTS} backend/sub2api "${DEPLOY_USER}@${DEPLOY_TARGET}:/tmp/sub2api.new"
success "上传完成"

# ============================================================================
# 4. 远程替换 + 重启
# ============================================================================
info "远程替换二进制并重启服务..."
ssh ${SSH_OPTS} "${DEPLOY_USER}@${DEPLOY_TARGET}" "sudo bash -s" << 'REMOTEEOF'
set -e

# 备份旧版本（带时间戳，不覆盖）
if [ -f "/opt/sub2api/sub2api" ]; then
  TS=$(date +%Y%m%d-%H%M%S)
  cp /opt/sub2api/sub2api /opt/sub2api/sub2api.$TS.bak
  echo "  已备份旧版本到 /opt/sub2api/sub2api.$TS.bak"
fi

# 替换
mv /tmp/sub2api.new /opt/sub2api/sub2api
chmod +x /opt/sub2api/sub2api
chown sub2api:sub2api /opt/sub2api/sub2api 2>/dev/null || true

# 重启服务
restarted=false
if command -v systemctl &>/dev/null && systemctl is-active sub2api &>/dev/null; then
  systemctl restart sub2api
  echo "  systemctl: 服务已重启"
  restarted=true
else
  # 尝试通过 pid 文件重启
  if [ -f "/var/run/sub2api.pid" ]; then
    if kill -HUP $(cat /var/run/sub2api.pid) 2>/dev/null; then
      echo "  SIGHUP: 服务已发送重载信号"
      restarted=true
    elif kill $(cat /var/run/sub2api.pid) 2>/dev/null; then
      echo "  已杀死旧进程，请手动重启"
    fi
  else
    # 尝试通过 pkill 重启
    if pkill sub2api 2>/dev/null; then
      echo "  pkill: 已杀死旧进程，请手动启动新进程"
    fi
  fi
fi

if [ "$restarted" = "false" ]; then
  echo "  ⚠️  警告：服务未通过 systemctl 管理，请手动重启 sub2api 以加载新二进制"
fi
REMOTEEOF
success "部署完成"

# ============================================================================
# 5. 验证
# ============================================================================
info "验证远程版本..."
sleep 2
ssh ${SSH_OPTS} "${DEPLOY_USER}@${DEPLOY_TARGET}" "sudo /opt/sub2api/sub2api --version 2>/dev/null || echo '(无法获取版本)'"

success "全部完成 🎉"
