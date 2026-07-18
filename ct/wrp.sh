#!/usr/bin/env bash
# Proxmox VE helper script: create or update an LXC container running WRP
# (Web Rendering Proxy - https://github.com/tenox7/wrp).
#
# Run on the Proxmox VE host:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/N0t4R0b0t/wrp/master/ct/wrp.sh)"
#
# Re-running against a hostname that already exists updates it in place
# (git pull + rebuild + restart service) instead of creating a new container.
#
# Env overrides:
#   CT_ID, CT_HOSTNAME, CT_DISK_GB, CT_CORES, CT_RAM_MB, CT_BRIDGE,
#   CT_STORAGE, CT_PASSWORD, WRP_LISTEN

set -Eeuo pipefail

RD='\033[0;31m'; GN='\033[0;32m'; YW='\033[1;33m'; CL='\033[0m'
msg_info()  { echo -e " ${YW}➜${CL} $1"; }
msg_ok()    { echo -e " ${GN}✔${CL} $1"; }
msg_error() { echo -e " ${RD}✘${CL} $1" >&2; }

CT_HOSTNAME="${CT_HOSTNAME:-wrp}"
CT_DISK_GB="${CT_DISK_GB:-6}"
CT_CORES="${CT_CORES:-2}"
CT_RAM_MB="${CT_RAM_MB:-2048}"
CT_BRIDGE="${CT_BRIDGE:-vmbr0}"
CT_STORAGE="${CT_STORAGE:-local-lvm}"
CT_PASSWORD="${CT_PASSWORD:-}"
WRP_LISTEN="${WRP_LISTEN:-:8080}"
INSTALL_REF="${INSTALL_REF:-master}"
INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/N0t4R0b0t/wrp/${INSTALL_REF}/install/wrp-install.sh"

require_pve() {
  if ! command -v pct >/dev/null 2>&1; then
    msg_error "pct not found - this script must run on a Proxmox VE host."
    exit 1
  fi
}

find_existing_ctid() {
  pct list | awk -v h="$CT_HOSTNAME" 'NR>1 && $0 ~ h {print $1; exit}'
}

next_ctid() {
  pvesh get /cluster/nextid
}

ensure_template() {
  local tmpl_storage="local"
  local tmpl
  tmpl=$(pveam available --section system 2>/dev/null | awk '/debian-12-standard/{print $2}' | sort -V | tail -1)
  if [[ -z "$tmpl" ]]; then
    msg_error "Could not find a debian-12-standard template in 'pveam available'."
    exit 1
  fi
  if ! pveam list "$tmpl_storage" 2>/dev/null | grep -q "$tmpl"; then
    msg_info "Downloading LXC template $tmpl"
    pveam download "$tmpl_storage" "$tmpl" >/dev/null
    msg_ok "Template downloaded"
  fi
  echo "${tmpl_storage}:vztmpl/${tmpl}"
}

wait_for_network() {
  local ctid=$1
  msg_info "Waiting for container network"
  for _ in $(seq 1 30); do
    if pct exec "$ctid" -- getent hosts deb.debian.org >/dev/null 2>&1; then
      msg_ok "Network is up"
      return
    fi
    sleep 2
  done
  msg_error "Timed out waiting for container network"
  exit 1
}

create_container() {
  local ctid=$1
  local template
  template=$(ensure_template)
  msg_info "Creating LXC $ctid ($CT_HOSTNAME)"
  local pw_args=()
  if [[ -n "$CT_PASSWORD" ]]; then
    pw_args=(-password "$CT_PASSWORD")
  else
    pw_args=(-password "$(openssl rand -base64 18)")
  fi
  pct create "$ctid" "$template" \
    -hostname "$CT_HOSTNAME" \
    -cores "$CT_CORES" \
    -memory "$CT_RAM_MB" \
    -swap 512 \
    -rootfs "${CT_STORAGE}:${CT_DISK_GB}" \
    -net0 "name=eth0,bridge=${CT_BRIDGE},ip=dhcp,firewall=1" \
    -features nesting=1 \
    -unprivileged 1 \
    -onboot 1 \
    "${pw_args[@]}" >/dev/null
  msg_ok "Container $ctid created"
  pct start "$ctid"
  wait_for_network "$ctid"
}

run_install_script() {
  local ctid=$1
  msg_info "Running wrp installer inside container $ctid"
  # Deliberately don't force install|update here: a container matching our
  # tag may exist but never have finished provisioning (e.g. a prior run
  # failed after `pct create`). Let wrp-install.sh self-detect from whether
  # /opt/wrp exists, so a half-finished container still gets a full install
  # instead of a skip-dependencies "update".
  pct exec "$ctid" -- env "WRP_LISTEN=${WRP_LISTEN}" \
    bash -c "wget -qO /tmp/wrp-install.sh '${INSTALL_SCRIPT_URL}' && bash /tmp/wrp-install.sh"
  msg_ok "wrp installer finished"
}

report() {
  local ctid=$1
  local ip msg
  ip=$(pct exec "$ctid" -- hostname -I 2>/dev/null | awk '{print $1}')
  # Captured then printed with `printf %b` rather than `cat` directly: a
  # heredoc emits bytes verbatim, so the \033[...] in $GN/$CL would otherwise
  # show up as literal text instead of color.
  msg=$(cat <<EOF

${GN}Done.${CL} Container ${ctid} (${CT_HOSTNAME}) - wrp listening on http://${ip}${WRP_LISTEN}

Update later with:  bash -c "\$(curl -fsSL https://raw.githubusercontent.com/N0t4R0b0t/wrp/master/ct/wrp.sh)"   (from the PVE host)
             or:    wrp-update                                                                                 (from inside the container)
EOF
)
  printf '%b\n' "$msg"
}

main() {
  require_pve
  local existing
  existing=$(find_existing_ctid || true)
  if [[ -n "$existing" ]]; then
    msg_info "Found existing container '${CT_HOSTNAME}' (CTID ${existing})"
    run_install_script "$existing"
    report "$existing"
    return
  fi

  local ctid="${CT_ID:-$(next_ctid)}"
  create_container "$ctid"
  run_install_script "$ctid"
  report "$ctid"
}

main "$@"
