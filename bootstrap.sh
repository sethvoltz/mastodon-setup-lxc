#!/usr/bin/env bash
#
# bootstrap.sh — PVE HOST script
#
# Creates and configures the privileged LXC that will host Mastodon.
#   - rootfs   -> Ceph RBD pool   (storage `ceph`)   — managed, migratable volume
#   - Garage data -> CephFS        (storage `cephfs`) — bind mount at /mnt/garage-data
#
# Target host: Proxmox VE 9.x. The container OS (Debian 12) is independent of the
# host version. Run this as root ON A PVE CLUSTER NODE. After it finishes, enter
# the container and run setup.sh via curl (see README.md).
#
# Run without cloning:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/sethvoltz/mastodon-setup-lxc/main/bootstrap.sh)"
#
set -euo pipefail

# Bump when bootstrap behavior changes (printed at startup so you can verify what ran).
BOOTSTRAP_VERSION="5"
MASTODON_SETUP_REPO="${MASTODON_SETUP_REPO:-sethvoltz/mastodon-setup-lxc}"
MASTODON_SETUP_REF="${MASTODON_SETUP_REF:-main}"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
c_hdr() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*" >&2; }
c_ok()  { printf '\033[1;32m[ok]\033[0m %s\n' "$*">&2; }
c_warn(){ printf '\033[1;33m[warn]\033[0m %s\n' "$*">&2; }
c_err() { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; }
die()   { c_err "$*"; exit 1; }

# prompt VAR "Question" "default"
prompt() {
  local __var="$1" __q="$2" __def="${3:-}" __ans
  if [[ -n "$__def" ]]; then
    read -r -p "$__q [$__def]: " __ans || true
    __ans="${__ans:-$__def}"
  else
    while [[ -z "${__ans:-}" ]]; do read -r -p "$__q: " __ans || true; done
  fi
  printf -v "$__var" '%s' "$__ans"
}

# prompt_optional VAR "Question" — Enter accepts empty (e.g. DHCP).
prompt_optional() {
  local __var="$1" __q="$2" __ans
  read -r -p "$__q: " __ans || true
  printf -v "$__var" '%s' "$__ans"
}

[[ $EUID -eq 0 ]] || die "Must run as root on the PVE host."
command -v pct >/dev/null     || die "pct not found — is this a Proxmox VE node?"
command -v pvesm >/dev/null   || die "pvesm not found — is this a Proxmox VE node?"

# ---------------------------------------------------------------------------
# Phase 1: collect inputs
# ---------------------------------------------------------------------------
c_hdr "Inputs"
c_ok "bootstrap.sh v${BOOTSTRAP_VERSION} (package ref ${MASTODON_SETUP_REF})"

DEFAULT_CTID="$(pvesh get /cluster/nextid 2>/dev/null || echo 200)"
prompt CTID            "LXC container ID"                 "$DEFAULT_CTID"
prompt CT_HOSTNAME     "Container hostname"               "mastodon"
prompt ROOT_DISK       "Root disk size"                   "40G"
prompt RAM_MB          "RAM (MB)"                         "4096"
prompt CORES           "CPU cores"                        "2"
prompt ROOTFS_STORAGE  "Rootfs storage pool (RBD)"        "ceph"
prompt CEPHFS_STORAGE  "CephFS storage name"              "cephfs"
prompt GARAGE_SIZE     "Garage data size / CephFS quota"  "100G"
prompt BRIDGE          "Network bridge"                   "vmbr0"
prompt IP_CIDR         "Container IP (CIDR, Enter for dhcp)" "dhcp"
prompt_optional GATEWAY  "Gateway IP (required for static IP, Enter to skip)"

ROOT_DISK_GB="${ROOT_DISK%[Gg]*}"   # 20G -> 20 (pct --rootfs wants GiB integer)
[[ "$ROOT_DISK_GB" =~ ^[0-9]+$ ]] || die "Root disk size must look like '20G'."

CEPHFS_MNT="/mnt/pve/${CEPHFS_STORAGE}"
GARAGE_HOST_DIR="${CEPHFS_MNT}/ct-${CTID}-garage-data"

# ---------------------------------------------------------------------------
# Phase 2: verify Ceph prerequisites
# ---------------------------------------------------------------------------
c_hdr "Verifying Ceph prerequisites"

pvesm status -storage "$ROOTFS_STORAGE" >/dev/null 2>&1 \
  || die "Rootfs storage '$ROOTFS_STORAGE' not found in 'pvesm status'."
c_ok "RBD storage '$ROOTFS_STORAGE' present."

pvesm status -storage "$CEPHFS_STORAGE" >/dev/null 2>&1 \
  || die "CephFS storage '$CEPHFS_STORAGE' not found in 'pvesm status'."
mountpoint -q "$CEPHFS_MNT" \
  || die "CephFS storage is not mounted at $CEPHFS_MNT. Activate it on this node first."
c_ok "CephFS '$CEPHFS_STORAGE' mounted at $CEPHFS_MNT."

# ---------------------------------------------------------------------------
# Phase 3: pull Debian 12 template if missing
# ---------------------------------------------------------------------------
c_hdr "Debian 12 template"

TEMPLATE="$(pveam list local 2>/dev/null | awk '/debian-12-standard/{print $1}' | sed 's#^local:vztmpl/##' | sort -V | tail -1 || true)"
if [[ -z "$TEMPLATE" ]]; then
  pveam update
  AVAIL="$(pveam available --section system | awk '/debian-12-standard/{print $2}' | sort -V | tail -1)"
  [[ -n "$AVAIL" ]] || die "No debian-12-standard template available from pveam."
  pveam download local "$AVAIL"
  TEMPLATE="$AVAIL"
fi
c_ok "Using template: $TEMPLATE"

# ---------------------------------------------------------------------------
# Phase 4: create the LXC (idempotent — skip if it already exists)
# ---------------------------------------------------------------------------
c_hdr "Creating LXC $CTID"

if pct status "$CTID" >/dev/null 2>&1; then
  c_warn "Container $CTID already exists — skipping create."
else
  if [[ -n "$IP_CIDR" && "${IP_CIDR,,}" != "dhcp" ]]; then
    [[ -n "$GATEWAY" ]] || die "Gateway IP is required when using a static container IP."
    NET0="name=eth0,bridge=${BRIDGE},ip=${IP_CIDR},gw=${GATEWAY}"
  else
    NET0="name=eth0,bridge=${BRIDGE},ip=dhcp"
  fi
  pct create "$CTID" "local:vztmpl/${TEMPLATE}" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CORES" \
    --memory "$RAM_MB" \
    --swap 512 \
    --rootfs "${ROOTFS_STORAGE}:${ROOT_DISK_GB}" \
    --unprivileged 0 \
    --features nesting=1 \
    --net0 "$NET0" \
    --nameserver "1.1.1.1 8.8.8.8" \
    --onboot 1 \
    --ostype debian
  c_ok "Container $CTID created (rootfs on ${ROOTFS_STORAGE})."
fi

# ---------------------------------------------------------------------------
# Phase 5: provision the Garage data bind mount on CephFS
# ---------------------------------------------------------------------------
# NOTE: Proxmox does not auto-copy bind mounts on `pct migrate`. That is fine
# here: CephFS is cluster-wide, so the same path exists on every node and the
# container starts cleanly after an offline relocate. The rootfs (RBD) migrates
# as a managed volume normally.
c_hdr "Garage data bind mount on CephFS"

mkdir -p "$GARAGE_HOST_DIR"
if command -v setfattr >/dev/null 2>&1; then
  if QUOTA_BYTES="$(numfmt --from=iec "$GARAGE_SIZE" 2>/dev/null)"; then
    if setfattr -n ceph.quota.max_bytes -v "$QUOTA_BYTES" "$GARAGE_HOST_DIR"; then
      c_ok "CephFS quota set to $GARAGE_SIZE ($QUOTA_BYTES bytes)."
    else
      c_warn "Could not set CephFS quota (non-fatal)."
    fi
  else
    c_warn "Could not parse size '$GARAGE_SIZE' for quota (non-fatal)."
  fi
else
  c_warn "setfattr not available — skipping CephFS quota (install attr to enable)."
fi

pct set "$CTID" -mp0 "${GARAGE_HOST_DIR},mp=/mnt/garage-data"
c_ok "Bind mount attached: ${GARAGE_HOST_DIR} -> /mnt/garage-data"

# ---------------------------------------------------------------------------
# Phase 6: start the container
# ---------------------------------------------------------------------------
c_hdr "Starting container"
if [[ "$(pct status "$CTID" | awk '{print $2}')" != "running" ]]; then
  pct start "$CTID"
fi
# give init a moment to bring the bind mount + network up
for _ in $(seq 1 15); do
  pct exec "$CTID" -- test -w /mnt/garage-data 2>/dev/null && break
  sleep 1
done
pct exec "$CTID" -- test -w /mnt/garage-data \
  || die "/mnt/garage-data is not writable inside the container — check the bind mount."
c_ok "Container running; /mnt/garage-data is writable."

# ---------------------------------------------------------------------------
# Next steps
# ---------------------------------------------------------------------------
c_hdr "Next steps"
cat <<EOF
Container $CTID ($CT_HOSTNAME) is up. Run the installer inside the container:

    pct enter $CTID
    bash -c "\$(curl -fsSL -H 'Cache-Control: no-cache' \\
      \"https://raw.githubusercontent.com/${MASTODON_SETUP_REPO}/${MASTODON_SETUP_REF}/setup.sh?\$(date +%s)\")"

setup.sh fetches its own templates from GitHub, then runs 15 resumable phases
(incl. Cloudflare Tunnel + DNS via API). Pin a ref with: export MASTODON_SETUP_REF=<tag-or-sha>
EOF
