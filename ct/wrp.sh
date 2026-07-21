#!/usr/bin/env bash
# Proxmox VE helper script: create or update an LXC container running WRP
# (Web Rendering Proxy - https://github.com/tenox7/wrp).
#
# Run on the Proxmox VE host:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/N0t4R0b0t/wrp/master/ct/wrp.sh)"
#
# When creating a new container, the script prompts interactively for
# hostname, resources, network bridge, and storage (offering a menu of
# whatever's actually available on this host, rather than assuming
# defaults like `local-lvm` that may not exist). Re-running against a
# hostname that already exists always skips straight to updating it in
# place (git pull + rebuild + restart service) instead of creating a new
# container, with no prompts.
#
# If stdin isn't a terminal (e.g. driven from another script), prompts are
# skipped and the env vars below (or their defaults) are used directly.
#
# Env overrides (also used as the pre-filled defaults in interactive
# prompts):
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
CT_STORAGE="${CT_STORAGE:-}"
CT_PASSWORD="${CT_PASSWORD:-}"
WRP_LISTEN="${WRP_LISTEN:-:8080}"
INSTALL_REF="${INSTALL_REF:-master}"
INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/N0t4R0b0t/wrp/${INSTALL_REF}/install/wrp-install.sh"

CHOICE=""
STORAGE_RESULT=""

require_pve() {
  if ! command -v pct >/dev/null 2>&1; then
    msg_error "pct not found - this script must run on a Proxmox VE host."
    exit 1
  fi
}

# ── Interactive helpers ──────────────────────────────────────────────────────
confirm() {
  # confirm "Question?" -> 0 (yes) or 1 (no/blank)
  local ans
  while true; do
    read -rp " ${YW}$1${CL} [y/N] " ans
    case "$ans" in
      [Yy]*) return 0 ;;
      [Nn]*|"") return 1 ;;
      *) echo "   Please answer y or n." ;;
    esac
  done
}

choose() {
  # choose "prompt" opt1 opt2 ... -> sets CHOICE to the selected 1-based index
  local prompt="$1"; shift
  local opts=("$@")
  echo -e " ${YW}${prompt}${CL}"
  local i
  for i in "${!opts[@]}"; do
    printf "   %d) %s\n" "$((i + 1))" "${opts[$i]}"
  done
  local sel
  while true; do
    read -rp "   Selection: " sel
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#opts[@]} )); then
      CHOICE=$sel
      return
    fi
    echo "   Invalid selection."
  done
}

prompt_default() {
  # prompt_default "Question" "default" -> echoes the answer, or default if blank
  local ans
  read -rp " ${YW}$1${CL} [$2]: " ans
  echo "${ans:-$2}"
}

prompt_number() {
  # prompt_number "Question" "default" -> echoes a validated positive integer
  local ans
  while true; do
    read -rp " ${YW}$1${CL} [$2]: " ans
    ans="${ans:-$2}"
    if [[ "$ans" =~ ^[0-9]+$ ]]; then
      echo "$ans"
      return
    fi
    echo "   Please enter a number." >&2
  done
}

prompt_ctid() {
  # prompt_ctid "default" -> echoes a validated, currently-unused CTID
  local default="$1" ans
  while true; do
    read -rp " ${YW}Container ID${CL} [${default}]: " ans
    ans="${ans:-$default}"
    if ! [[ "$ans" =~ ^[0-9]+$ ]]; then
      echo "   Please enter a number." >&2
      continue
    fi
    if pct status "$ans" >/dev/null 2>&1; then
      echo "   CTID ${ans} already exists, choose another." >&2
      continue
    fi
    echo "$ans"
    return
  done
}

# select_storage <content-type> <label> -> sets STORAGE_RESULT
# Lists storages Proxmox reports as active for the given content type
# (e.g. "rootdir" for container disks, "vztmpl" for templates). Prompts
# interactively when there's more than one and stdin is a terminal;
# otherwise picks the first one and says so.
select_storage() {
  local content="$1" label="$2"
  local -a names=() display=()
  local name type total used free
  while read -r name type _ total used free _; do
    [[ -n "$name" && -n "$type" ]] || continue
    local free_fmt used_fmt
    free_fmt=$(numfmt --to=iec --from-unit=1024 --format "%.1f" <<<"$free" 2>/dev/null || echo "${free}K")
    used_fmt=$(numfmt --to=iec --from-unit=1024 --format "%.1f" <<<"$used" 2>/dev/null || echo "${used}K")
    names+=("$name")
    display+=("${name}  (${type}, free ${free_fmt}B, used ${used_fmt}B)")
  done < <(pvesm status -content "$content" 2>/dev/null | awk 'NR>1 && $3=="active"')

  if [[ ${#names[@]} -eq 0 ]]; then
    msg_error "No active storage found for content type '${content}'. Check 'pvesm status -content ${content}'."
    exit 1
  fi

  if [[ ${#names[@]} -eq 1 ]]; then
    STORAGE_RESULT="${names[0]}"
    return
  fi

  if [[ -t 0 ]]; then
    choose "${label} - select storage:" "${display[@]}"
    STORAGE_RESULT="${names[$((CHOICE - 1))]}"
  else
    STORAGE_RESULT="${names[0]}"
    msg_info "Non-interactive: defaulting ${label} storage to '${STORAGE_RESULT}' (other options: ${names[*]:1})"
  fi
}

resolve_ct_storage() {
  # Honors an explicit CT_STORAGE env override if it's actually valid,
  # otherwise selects interactively (or picks automatically, non-interactively).
  if [[ -n "$CT_STORAGE" ]]; then
    if pvesm status -content rootdir 2>/dev/null | awk 'NR>1 && $3=="active"{print $1}' | grep -qx "$CT_STORAGE"; then
      return
    fi
    msg_error "CT_STORAGE='${CT_STORAGE}' is not an active storage for container disks - ignoring it."
  fi
  select_storage rootdir "Container rootfs"
  CT_STORAGE="$STORAGE_RESULT"
}

list_bridges() {
  local b
  for b in /sys/class/net/*/; do
    [[ -d "${b}bridge" ]] || continue
    basename "$b"
  done
}

configure_interactive() {
  echo -e "\n${GN}Configure the new wrp container${CL} (Enter accepts the default shown)\n"
  CT_HOSTNAME=$(prompt_default "Hostname" "$CT_HOSTNAME")
  CT_ID=$(prompt_ctid "${CT_ID:-$(next_ctid)}")
  CT_CORES=$(prompt_number "CPU cores" "$CT_CORES")
  CT_RAM_MB=$(prompt_number "Memory (MB)" "$CT_RAM_MB")
  CT_DISK_GB=$(prompt_number "Disk size (GB)" "$CT_DISK_GB")

  local -a bridges=()
  mapfile -t bridges < <(list_bridges)
  if [[ ${#bridges[@]} -eq 0 ]]; then
    CT_BRIDGE=$(prompt_default "Network bridge" "$CT_BRIDGE")
  elif [[ ${#bridges[@]} -eq 1 ]]; then
    CT_BRIDGE="${bridges[0]}"
    msg_ok "Network bridge: ${CT_BRIDGE}"
  else
    choose "Network bridge:" "${bridges[@]}"
    CT_BRIDGE="${bridges[$((CHOICE - 1))]}"
  fi

  resolve_ct_storage
  WRP_LISTEN=$(prompt_default "wrp listen address:port" "$WRP_LISTEN")

  read -rsp " ${YW}Root password (blank = random, generated)${CL}: " CT_PASSWORD
  echo

  echo -e "\n${YW}Summary:${CL}"
  echo "   CTID       : ${CT_ID}"
  echo "   Hostname   : ${CT_HOSTNAME}"
  echo "   Cores      : ${CT_CORES}"
  echo "   RAM        : ${CT_RAM_MB} MB"
  echo "   Disk       : ${CT_DISK_GB} GB"
  echo "   Bridge     : ${CT_BRIDGE}"
  echo "   Storage    : ${CT_STORAGE}"
  echo "   wrp listen : ${WRP_LISTEN}"
  echo ""
  confirm "Create the container with these settings?" || { msg_info "Aborted, nothing was created."; exit 0; }
}

find_existing_ctid() {
  pct list | awk -v h="$CT_HOSTNAME" 'NR>1 && $0 ~ h {print $1; exit}'
}

next_ctid() {
  pvesh get /cluster/nextid
}

ensure_template() {
  select_storage vztmpl "Template"
  local tmpl_storage="$STORAGE_RESULT"
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

  if [[ -t 0 ]]; then
    configure_interactive
  else
    CT_ID="${CT_ID:-$(next_ctid)}"
    resolve_ct_storage
  fi

  create_container "$CT_ID"
  run_install_script "$CT_ID"
  report "$CT_ID"
}

main "$@"
