# WRP on Proxmox VE

This guide covers deploying WRP as an LXC container on a Proxmox VE host, and
using it day-to-day once it's running. There are two scripts involved:

| Script | Runs on | Purpose |
|---|---|---|
| [`ct/wrp.sh`](../ct/wrp.sh) | Proxmox VE host | Creates (or finds) the LXC container, then invokes the install script inside it |
| [`install/wrp-install.sh`](../install/wrp-install.sh) | Inside the container | Installs dependencies, Go, builds `wrp`, sets up the systemd service |

You normally only ever run `ct/wrp.sh`, from the Proxmox host shell. It takes
care of calling the in-container script for you.

## Requirements

- A Proxmox VE host with the `pct`/`pveam`/`pvesh` CLI tools available (i.e. run
  this on the host itself, not inside a container/VM).
- Network access from the host to GitHub (to fetch the scripts) and from the
  new container to the Debian package mirrors (to install dependencies).
- A Debian 12 LXC template. The script will download `debian-12-standard`
  automatically if it isn't already present in local storage.

## Installing

Run this on the Proxmox host shell (via the web UI's `>_ Shell` or SSH):

```shell
bash -c "$(curl -fsSL https://raw.githubusercontent.com/N0t4R0b0t/wrp/master/ct/wrp.sh)"
```

This will:

1. Verify you're on a PVE host.
2. Look for an existing container named `wrp` (or your `CT_HOSTNAME`). If
   found, skip straight to re-running the installer inside it, with no
   prompts (see [Updating](#updating)).
3. Otherwise, walk you through an interactive setup (see below), then create
   an unprivileged LXC with DHCP networking using those answers.
4. Start the container and wait for its network to come up.
5. Fetch and run `install/wrp-install.sh` inside the container, which
   installs Chromium/Go/build deps, clones and builds `wrp`, and registers it
   as a systemd service (`wrp.service`) set to start on boot.
6. Print the container ID and the URL to browse to.

The whole process typically takes a few minutes, most of it spent building Go
and compiling `wrp` inside the container.

### Interactive setup

For a new container, the script prompts for each setting, showing the
current default in brackets — press Enter to accept it, or type a value to
override it:

```
Configure the new wrp container (Enter accepts the default shown)

 Hostname [wrp]:
 Container ID [117]:
 CPU cores [2]:
 Memory (MB) [2048]:
 Disk size (GB) [6]:
 Network bridge:
   1) vmbr0
   2) vmbr1
   Selection: 1
 Container rootfs - select storage:
   1) local-lvm  (lvmthin, free 120.3GB, used 8.1GB)
   2) local-zfs  (zfspool, free 400.0GB, used 12.5GB)
   Selection: 2
 wrp listen address:port [:8080]:
 Root password (blank = random, generated):

Summary:
   CTID       : 117
   Hostname   : wrp
   Cores      : 2
   RAM        : 2048 MB
   Disk       : 6 GB
   Bridge     : vmbr0
   Storage    : local-zfs
   wrp listen : :8080

 Create the container with these settings? [y/N]
```

A few things worth knowing:

- **Storage and bridge menus only list what's actually available** on this
  host (via `pvesm status` / `/sys/class/net/*/bridge`), which is what fixes
  the old hardcoded `local-lvm` default erroring out on hosts that use ZFS,
  directory storage, or a differently-named pool. If only one option exists
  for a given prompt, it's picked automatically without asking.
- The **container ID prompt rejects an ID that's already in use** and asks
  again, so a stale/incorrect `CT_ID` can't clash with an existing container.
- Nothing is created until you confirm the final summary; answering `n` (or
  just Enter) at that prompt aborts cleanly.
- If stdin isn't a terminal (e.g. this script is invoked from your own
  automation), all prompts are skipped and it falls back to the env vars /
  defaults below — auto-picking the first available storage/bridge if there's
  more than one and none was specified.

### Configuration (environment variables)

Set these before the `bash -c "..."` command to pre-fill the interactive
prompts (or, run non-interactively, to use directly with no prompts):

| Variable | Default | Meaning |
|---|---|---|
| `CT_ID` | next free ID | Proxmox container ID to use |
| `CT_HOSTNAME` | `wrp` | Container hostname; also used to find an existing container to update |
| `CT_DISK_GB` | `6` | Root disk size, in GB |
| `CT_CORES` | `2` | CPU cores |
| `CT_RAM_MB` | `2048` | Memory, in MB |
| `CT_BRIDGE` | `vmbr0` | Network bridge |
| `CT_STORAGE` | auto-selected | Storage backend for the container rootfs — if set to a storage that isn't actually active for container disks, it's ignored with a warning and you get the selection prompt/auto-pick instead |
| `CT_PASSWORD` | random | Root password inside the container (a random one is generated and used if unset — you won't see it printed, so set your own if you need console access) |
| `WRP_LISTEN` | `:8080` | Address:port `wrp` listens on inside the container |
| `INSTALL_REF` | `master` | Git ref of `install/wrp-install.sh` to fetch from GitHub — pin this if you want a specific version instead of tracking `master` |

Example — pre-fill a different bridge with more RAM and cores (still prompts,
just with these as the shown defaults):

```shell
CT_BRIDGE=vmbr1 CT_RAM_MB=4096 CT_CORES=4 bash -c "$(curl -fsSL https://raw.githubusercontent.com/N0t4R0b0t/wrp/master/ct/wrp.sh)"
```

Example — pin a specific CTID and hostname:

```shell
CT_ID=150 CT_HOSTNAME=wrp-vintage bash -c "$(curl -fsSL https://raw.githubusercontent.com/N0t4R0b0t/wrp/master/ct/wrp.sh)"
```

## Updating

Re-running the exact same command later updates the existing container in
place instead of creating a new one:

```shell
bash -c "$(curl -fsSL https://raw.githubusercontent.com/N0t4R0b0t/wrp/master/ct/wrp.sh)"
```

`ct/wrp.sh` finds the container by matching `CT_HOSTNAME` against `pct list`,
then re-runs the installer inside it. `install/wrp-install.sh` auto-detects
that `/opt/wrp` already exists and switches to update mode: `git fetch` +
`reset --hard` to the latest `WRP_REF`, rebuild, rewrite the systemd unit, and
restart the service. Nothing about the container itself (disk/CPU/RAM) is
changed on update — those settings only apply at creation time.

You can also update from inside the container directly, without going back to
the Proxmox host shell:

```shell
wrp-update
```

This is a symlink to `install/wrp-install.sh` installed at `/usr/local/bin/`
during install, and does the same fetch/rebuild/restart.

### Updating in-container settings only

If you just want to change something like the listen port without touching
the container, run the install script directly inside the container (as
root) with an env override:

```shell
WRP_LISTEN=:9090 wrp-update
```

See [`install/wrp-install.sh`](../install/wrp-install.sh) for the full list of
env overrides it accepts (`WRP_REPO`, `WRP_REF`, `WRP_DIR`, `WRP_BIN`,
`WRP_LISTEN`, `WRP_ARGS`).

## User guide

### Logging in and finding the container

The console (`pct enter <ctid>` or the Proxmox web UI's `>_ Console`)
auto-logs in as root on tty1 — no password prompt, and Debian's default
dynamic MOTD scripts are disabled so nothing else clutters the greeter.
Instead you land straight on the wrp banner with the IP, browse URL, log
command, and update command:

```
wrp - Web Rendering Proxy LXC Container
    Provided by: N0t4R0b0t | GitHub: https://github.com/N0t4R0b0t/wrp

    OS: Debian GNU/Linux 12 (bookworm)
    Hostname: wrp
    IP Address: 192.168.1.50

    Browse to:  http://192.168.1.50:8080
    Proxy PAC:  http://192.168.1.50:8080/proxy.pac

    Source:     /opt/wrp
    Logs:       journalctl -u wrp -f
    Update:     wrp-update
```

### Checking status / logs

```shell
pct enter <ctid>              # get a shell inside the container
systemctl status wrp          # is it running?
journalctl -u wrp -f          # follow logs
systemctl restart wrp         # restart after manual config changes
```

### Browsing with a vintage browser

1. Point your old browser at `http://<container-ip>:8080` (the address shown
   in the login banner).
2. Type a search string or a full `http://`/`https://` URL in the input box
   and click **Go**.
3. Choose graphical (ISMAP) or simple HTML mode with the **M** selector —
   ISMAP renders the page as a clickable image, simple HTML converts the page
   to plain HTML for readability on very old browsers.

For the full set of on-page controls (zoom, colors, image type, keystroke
input, etc.) see the [main README's UI explanation](../README.md#ui-explanation).

### Proxy mode

The container also serves `/proxy.pac` for automatic proxy configuration.
Stick to `http://` addresses in proxy mode — see the
[Proxy mode section](../README.md#proxy-mode) in the main README for the
`https://` limitations.

### Adjusting flags (`WRP_ARGS`)

`wrp`'s runtime behavior (image type/geometry/quality/user-agent, etc.) is
controlled by command-line flags baked into the systemd unit's `ExecStart`.
To change them permanently, set `WRP_ARGS` and re-run the installer inside the
container:

```shell
WRP_ARGS="-t png -g 1280x0x256" wrp-update
```

See the [Flags section](../README.md#flags) in the main README for the full
flag reference.

### Removing the container

WRP itself doesn't manage container lifecycle — to remove it, stop and
destroy it like any other LXC from the Proxmox host:

```shell
pct stop <ctid>
pct destroy <ctid>
```

### Security note: console autologin

tty1 is configured to autologin as root, with no password prompt, on every
boot. This is standard for these single-purpose Proxmox helper containers,
where the only intended access path is `pct enter`/the web console from an
already-trusted Proxmox host. It does mean anyone with console access to the
container (via the Proxmox UI or `pct enter`) gets an unauthenticated root
shell — don't rely on the console as an access control boundary, and treat
Proxmox host access itself as equivalent to root-in-container access. SSH (if
you enable it) still requires the `CT_PASSWORD` set at creation time.

## Troubleshooting

- **`pct not found` error** — you ran the script somewhere other than the
  Proxmox VE host shell. It must run on the host itself.
- **Timed out waiting for container network** — check that `CT_BRIDGE` points
  at a bridge with DHCP/internet access; the script waits up to 60s for the
  container to resolve `deb.debian.org`.
- **Install fails partway through (e.g. after `pct create`)** — just re-run
  the same command. `ct/wrp.sh` will find the existing container by hostname,
  and `wrp-install.sh` detects that `/opt/wrp` doesn't exist yet (or is
  incomplete) and does a full install rather than skipping steps.
- **Need the root password (e.g. for SSH)** — a random one is generated when
  `CT_PASSWORD` isn't set and isn't printed anywhere. Set `CT_PASSWORD`
  explicitly before creating the container if you need to know it. The
  console itself (`pct enter`/web UI) doesn't need it — see the security note
  below.
