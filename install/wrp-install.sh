#!/usr/bin/env bash
# WRP (Web Rendering Proxy) installer/updater for Debian/Ubuntu LXC containers.
# Run as root inside the target container. Auto-detects install vs update.
#
# Usage: wrp-install.sh [install|update]
#   (no argument = auto-detect based on whether /opt/wrp already exists)
#
# Env overrides:
#   WRP_REPO      git clone URL for wrp source (default: this fork)
#   WRP_REF       git ref/branch to track       (default: master)
#   WRP_DIR       install/build directory       (default: /opt/wrp)
#   WRP_BIN       installed binary path         (default: /usr/local/bin/wrp)
#   WRP_LISTEN    listen address:port           (default: :8080)
#   WRP_ARGS      extra flags appended to ExecStart

set -Eeuo pipefail

export PATH="/usr/local/go/bin:$PATH"

WRP_REPO="${WRP_REPO:-https://github.com/N0t4R0b0t/wrp.git}"
WRP_REF="${WRP_REF:-master}"
WRP_DIR="${WRP_DIR:-/opt/wrp}"
WRP_BIN="${WRP_BIN:-/usr/local/bin/wrp}"
WRP_LISTEN="${WRP_LISTEN:-:8080}"
WRP_ARGS="${WRP_ARGS:-}"
SERVICE_FILE=/etc/systemd/system/wrp.service
GO_MIN_VERSION="1.26"

RD='\033[0;31m'; GN='\033[0;32m'; YW='\033[1;33m'; CL='\033[0m'
msg_info()  { echo -e " ${YW}➜${CL} $1"; }
msg_ok()    { echo -e " ${GN}✔${CL} $1"; }
msg_error() { echo -e " ${RD}✘${CL} $1" >&2; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    msg_error "This script must be run as root."
    exit 1
  fi
}

install_dependencies() {
  msg_info "Installing system dependencies (apt)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq \
    ca-certificates curl git tar \
    chromium fonts-liberation >/dev/null
  msg_ok "System dependencies installed"
}

go_version_ok() {
  command -v go >/dev/null 2>&1 || return 1
  local cur
  cur=$(go version | awk '{print $3}' | sed 's/go//')
  [[ "$(printf '%s\n' "$GO_MIN_VERSION" "$cur" | sort -V | head -n1)" == "$GO_MIN_VERSION" ]]
}

install_go() {
  if go_version_ok; then
    msg_ok "Go toolchain already satisfies >= ${GO_MIN_VERSION}"
    return
  fi
  msg_info "Installing Go toolchain"
  local arch goarch latest
  arch=$(dpkg --print-architecture)
  case "$arch" in
    amd64) goarch=amd64 ;;
    arm64) goarch=arm64 ;;
    armhf) goarch=armv6l ;;
    *) msg_error "Unsupported architecture: $arch"; exit 1 ;;
  esac
  latest=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -n1)
  curl -fsSL "https://go.dev/dl/${latest}.linux-${goarch}.tar.gz" -o /tmp/go.tar.gz
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tar.gz
  rm -f /tmp/go.tar.gz
  ln -sf /usr/local/go/bin/go /usr/local/bin/go
  ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
  echo 'export PATH=$PATH:/usr/local/go/bin' >/etc/profile.d/go.sh
  msg_ok "Go toolchain ${latest} installed"
}

sync_source() {
  if [[ -d "$WRP_DIR/.git" ]]; then
    msg_info "Updating wrp source in $WRP_DIR"
    git -C "$WRP_DIR" fetch --depth 1 origin "$WRP_REF"
    git -C "$WRP_DIR" checkout "$WRP_REF"
    git -C "$WRP_DIR" reset --hard "origin/$WRP_REF"
    msg_ok "Source updated"
  else
    msg_info "Cloning wrp source into $WRP_DIR"
    git clone --depth 1 --branch "$WRP_REF" "$WRP_REPO" "$WRP_DIR"
    msg_ok "Source cloned"
  fi
}

build_wrp() {
  msg_info "Building wrp binary"
  (cd "$WRP_DIR" && GOTOOLCHAIN=auto go build -o "$WRP_BIN" .)
  cp -f "$WRP_DIR/wrp.html" "$(dirname "$WRP_BIN")/wrp.html" 2>/dev/null || true
  msg_ok "Built $WRP_BIN"
}

create_service() {
  msg_info "Writing systemd unit"
  local chromium_bin
  chromium_bin=$(command -v chromium || command -v chromium-browser || true)
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=WRP - Web Rendering Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${WRP_BIN} -l ${WRP_LISTEN} -b ${chromium_bin} ${WRP_ARGS}
WorkingDirectory=${WRP_DIR}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  msg_ok "systemd unit written"
}

do_install() {
  install_dependencies
  install_go
  sync_source
  build_wrp
  create_service
  systemctl enable --now wrp.service
  msg_ok "wrp installed and started"
}

do_update() {
  install_go
  sync_source
  build_wrp
  create_service
  systemctl restart wrp.service
  msg_ok "wrp updated and restarted"
}

require_root

MODE="${1:-}"
if [[ -z "$MODE" ]]; then
  if [[ -d "$WRP_DIR/.git" ]]; then MODE=update; else MODE=install; fi
fi

case "$MODE" in
  install) do_install ;;
  update)  do_update ;;
  *) msg_error "Unknown mode: $MODE (expected install|update)"; exit 1 ;;
esac

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo -e "\n${GN}wrp is running.${CL} Point a legacy browser at: http://${IP}${WRP_LISTEN}\n"
