#!/bin/sh
# Vibe Runtime init script — runs as /etc/vibe/vibe-init.sh inside the VM
# Called from our custom /init as a background process

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

LOG=/dev/kmsg
# ts: seconds elapsed since kernel boot (from /proc/uptime), e.g. "12.34s"
ts() { awk '{printf "%.2fs", $1}' /proc/uptime 2>/dev/null || echo "?s"; }
log() { echo "[vibe-init +$(ts)] $*" > $LOG 2>/dev/null || true; echo "[vibe-init +$(ts)] $*"; }
stage() { log "STAGE: $1"; [ "$VIRTIOFS_OK" = "true" ] && touch "/vibe-shared/.stage-$1" 2>/dev/null || true; }

log "Starting Vibe Runtime setup..."
stage "start"

# ── Networking ──────────────────────────────────────────────────────────────
log "Bringing up network..."

# Loopback
ip link set lo up 2>/dev/null || true
ip addr add 127.0.0.1/8 dev lo 2>/dev/null || true

# Log all available interfaces
log "All interfaces: $(ip link show 2>/dev/null | grep -E '^[0-9]+:' | awk '{print $2}' | tr -d ':' | tr '\n' ' ')"

# Detect first non-loopback interface (handles eth0, enp0s1, ens*, etc.)
IFACE=$(ip link show 2>/dev/null | grep -E '^[0-9]+:' | grep -v ': lo:' | awk -F': ' '{print $2}' | head -1 | sed 's/@.*//' | tr -d ' ')
if [ -n "$IFACE" ]; then
    log "Requesting DHCP on: $IFACE"
    ip link set "$IFACE" up 2>/dev/null || true
    # Wait for carrier — virtio-net may not be ready immediately after insmod
    for i in $(seq 10); do
        CARRIER=$(cat /sys/class/net/"$IFACE"/carrier 2>/dev/null)
        log "Carrier check $i: $CARRIER"
        [ "$CARRIER" = "1" ] && break
        sleep 1
    done
    log "Link state: $(ip link show dev "$IFACE" 2>/dev/null | head -1)"
    # Run udhcpc with output captured for debugging
    udhcpc -i "$IFACE" -q -T 10 -t 3 > /tmp/udhcpc.log 2>&1
    DHCP_RC=$?
    log "udhcpc rc=$DHCP_RC: $(cat /tmp/udhcpc.log 2>/dev/null | tr '\n' '|')"
    VMIP=$(ip addr show dev "$IFACE" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    log "Post-DHCP ip: $VMIP"
else
    log "WARNING: no non-loopback interface found"
    VMIP=""
fi

# DNS fallback — ensure resolv.conf has a nameserver regardless
grep -q nameserver /etc/resolv.conf 2>/dev/null || echo "nameserver 8.8.8.8" > /etc/resolv.conf
log "DNS: $(cat /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
stage "network"

# ── Persistent data disk (/dev/vda) ─────────────────────────────────────────
if [ -b /dev/vda ]; then
    if ! blkid /dev/vda 2>/dev/null | grep -q ext4; then
        log "Formatting persistent data disk..."
        mkfs.ext4 -F -L vibe-data /dev/vda > /dev/kmsg 2>&1 || true
    fi
    log "Mounting /dev/vda → /var/lib/containerd"
    mkdir -p /var/lib/containerd
    mount /dev/vda /var/lib/containerd || true
fi

# ── virtio-fs shared directory ───────────────────────────────────────────────
VIRTIOFS_OK=false
mkdir -p /vibe-shared
log "Mounting virtio-fs (modules loaded by /init)..."
log "Mounting virtio-fs..."
for i in $(seq 10); do
    if mount -t virtiofs vibe-shared /vibe-shared 2>/dev/null; then
        log "Mounted virtio-fs at /vibe-shared (attempt $i)"
        VIRTIOFS_OK=true
        break
    fi
    log "virtiofs mount attempt $i failed, retrying..."
    sleep 1
done
if [ "$VIRTIOFS_OK" != "true" ]; then
    log "ERROR: virtio-fs failed to mount after 10 attempts"
fi
# Write VM IP now that virtiofs is mounted — host reads this for direct TCP SSH
if [ -n "$VMIP" ] && [ "$VIRTIOFS_OK" = "true" ]; then
    echo "$VMIP" > /vibe-shared/.vm-ip 2>/dev/null || true
    log "Wrote VM IP $VMIP to /vibe-shared/.vm-ip"
fi
stage "virtiofs"

# ── Install packages (first boot) or restore from cache ─────────────────────
ALPINE_VER=$(cat /etc/vibe/alpine-version 2>/dev/null || echo "unknown")
PACKAGES_CACHE=/var/lib/containerd/.vibe-packages-${ALPINE_VER}.tar.gz
PACKAGES_FLAG=/var/lib/containerd/.vibe-packages-${ALPINE_VER}.installed

PKG_START=$(awk '{print $1}' /proc/uptime)
if [ -f "$PACKAGES_FLAG" ] && [ -f "$PACKAGES_CACHE" ]; then
    log "BENCH packages: cache hit — restoring from $(du -sh "$PACKAGES_CACHE" 2>/dev/null | cut -f1) tarball..."
    tar -xzf "$PACKAGES_CACHE" -C / 2>/dev/null
    log "BENCH packages: restore done in $(awk -v s="$PKG_START" '{printf "%.2fs", $1-s}' /proc/uptime)"
else
    log "BENCH packages: cache miss — installing from network (first boot)..."
    apk update > /dev/kmsg 2>&1
    apk add --no-cache \
        containerd \
        nerdctl \
        openssh-server \
        iptables \
        ip6tables \
        e2fsprogs \
        ca-certificates \
        socat \
        > /dev/kmsg 2>&1
    log "BENCH packages: install done in $(awk -v s="$PKG_START" '{printf "%.2fs", $1-s}' /proc/uptime)"
    log "Saving to persistent disk for fast restore..."
    tar -czf "$PACKAGES_CACHE" \
        /usr/bin /usr/sbin /usr/lib /usr/local/bin /usr/local/lib /lib/libgcc_s* \
        /etc/ssl/certs /etc/ssl/cert.pem \
        2>/dev/null || log "Package cache creation failed (non-fatal)"
    touch "$PACKAGES_FLAG"
    log "Package cache saved ($(du -sh "$PACKAGES_CACHE" | cut -f1))."
fi
stage "packages"

# ── Install CNI plugins ──────────────────────────────────────────────────────
CNI_DIR=/opt/cni/bin
if [ ! -f "$CNI_DIR/bridge" ]; then
    log "Installing CNI plugins..."
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    mkdir -p "$CNI_DIR"
    wget -q -O /tmp/cni.tgz \
        "https://github.com/containernetworking/plugins/releases/download/v1.4.0/cni-plugins-linux-${ARCH}-v1.4.0.tgz" && \
        tar -xzf /tmp/cni.tgz -C "$CNI_DIR" && \
        rm /tmp/cni.tgz || log "CNI plugin install failed (non-fatal)"
fi

# ── CNI network config ───────────────────────────────────────────────────────
mkdir -p /etc/cni/net.d
if [ ! -f /etc/cni/net.d/10-vibe.conflist ]; then
    cat > /etc/cni/net.d/10-vibe.conflist << 'CNI'
{
  "cniVersion": "1.0.0",
  "name": "vibe-bridge",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "vibe0",
      "isGateway": true,
      "ipMasq": true,
      "ipam": {
        "type": "host-local",
        "subnet": "10.88.0.0/16",
        "routes": [{"dst": "0.0.0.0/0"}]
      }
    },
    {"type": "portmap", "capabilities": {"portMappings": true}},
    {"type": "firewall"}
  ]
}
CNI
fi
stage "cni"

# ── vibe user ────────────────────────────────────────────────────────────────
if ! id vibe > /dev/null 2>&1; then
    adduser -D -s /bin/sh vibe 2>&1 | while IFS= read -r l; do log "adduser: $l"; done || true
fi
# Ensure vibe group exists (adduser may not write /etc/group correctly on ramdisk)
grep -q '^vibe:' /etc/group 2>/dev/null || echo "vibe:x:1000:" >> /etc/group
# If adduser failed entirely, inject user directly
if ! id vibe > /dev/null 2>&1; then
    log "adduser failed — injecting vibe user"
    echo "vibe:x:1000:1000:Vibe:/home/vibe:/bin/sh" >> /etc/passwd
    echo "vibe:*::0:::::" >> /etc/shadow 2>/dev/null || true
fi
# Unlock the vibe account — OpenSSH rejects pubkey auth if the shadow password field
# starts with '!' (locked), even when PasswordAuthentication is disabled.
# Replace '!' with '*' (no password, but not locked).
sed -i 's/^vibe:!:/vibe:*:/' /etc/shadow 2>/dev/null || true
log "vibe shadow: $(grep '^vibe:' /etc/shadow 2>/dev/null | cut -d: -f1-2 || echo 'no shadow entry')"
log "vibe user: $(id vibe 2>&1)"
mkdir -p /home/vibe /home/vibe/.ssh
chmod 755 /home/vibe
chmod 700 /home/vibe/.ssh
# Install authorized_keys for root — SSH as root so nerdctl uses system containerd directly.
mkdir -p /root/.ssh
chmod 700 /root/.ssh
# Always install the baked-in build key first (allows host-side SSH debugging).
# Then append the app-generated key so both work.
> /root/.ssh/authorized_keys
if [ -f /etc/vibe/vibe-vm.pub ]; then
    cat /etc/vibe/vibe-vm.pub >> /root/.ssh/authorized_keys
    log "Installed baked-in pubkey for root"
fi
if [ -f /vibe-shared/vibe-vm.pub ]; then
    cat /vibe-shared/vibe-vm.pub >> /root/.ssh/authorized_keys
    log "Installed app pubkey for root from /vibe-shared"
fi
log "authorized_keys: $(wc -l < /root/.ssh/authorized_keys 2>/dev/null) keys"
chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
log "root authorized_keys: $(ls -la /root/.ssh/authorized_keys 2>/dev/null || echo 'MISSING')"

# ── SSH server ───────────────────────────────────────────────────────────────
log "Starting sshd..."
# sshd requires /var/empty owned by root with no group/world write
mkdir -p /var/empty
chmod 711 /var/empty
chown root:root /var/empty
ssh-keygen -A 2>&1 | while IFS= read -r l; do log "keygen: $l"; done || true
# Use absolute path for AuthorizedKeysFile (no %u substitution) to avoid any expansion bugs
# Log to /vibe-shared/sshd-debug.log so the host app can read it for auth diagnostics
cat > /etc/ssh/sshd_config << 'SSHD'
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile /root/.ssh/authorized_keys
StrictModes no
LogLevel DEBUG3
SetEnv PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SSHD
/usr/sbin/sshd -E /vibe-shared/sshd-debug.log 2>/tmp/sshd.log && log "sshd started OK" || log "sshd start failed: $(cat /tmp/sshd.log 2>/dev/null)"
# Wait for sshd to bind on port 22 (use /proc/net/tcp since ss may not be available)
# Port 22 = 0x0016 in hex
for i in $(seq 20); do
    grep -qE '00000000:0016 ' /proc/net/tcp /proc/net/tcp6 2>/dev/null && break
    sleep 0.5
done
if grep -qE '00000000:0016 ' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
    log "sshd listening on :22 OK"
else
    log "WARNING: sshd NOT listening on :22 — $(cat /tmp/sshd.log 2>/dev/null | tail -3 | tr '\n' '|')"
fi
stage "sshd"

# ── Kernel modules for containers ────────────────────────────────────────────
log "Loading kernel modules..."
for mod in overlay bridge br_netfilter xt_MASQUERADE xt_nat ip_tables iptable_nat iptable_filter; do
    modprobe "$mod" 2>/dev/null && log "  loaded: $mod" || log "  skip (not available): $mod"
done
echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
echo 1 > /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || true
echo 1 > /proc/sys/net/bridge/bridge-nf-call-ip6tables 2>/dev/null || true
log "Kernel modules loaded."

# ── runc --no-pivot wrapper ───────────────────────────────────────────────────
# Alpine linux-virt boots from initramfs: the kernel returns EINVAL from
# pivot_root when the process root IS the initial ramfs. runc's --no-pivot flag
# uses MS_MOVE instead of pivot_root, which has no such restriction.
# Replace /usr/bin/runc in-place so containerd-shim finds the wrapper regardless
# of how it resolves the binary (PATH lookup or absolute path).
log "Installing runc --no-pivot wrapper..."
RUNC_REAL=/usr/bin/runc.real
# Find and rename the real runc binary
for candidate in /usr/bin/runc /usr/sbin/runc /usr/local/bin/runc; do
    if [ -f "$candidate" ] && [ ! -f "$RUNC_REAL" ]; then
        mv "$candidate" "$RUNC_REAL"
        log "  Moved $candidate → $RUNC_REAL"
        break
    fi
done
if [ ! -f "$RUNC_REAL" ]; then
    log "ERROR: runc binary not found in any expected location!"
    log "  /usr/bin contents: $(ls /usr/bin | grep -i runc || echo 'none')"
fi
cat > /usr/bin/runc << 'RUNC_WRAPPER'
#!/bin/sh
# runc 1.1.x moved --no-pivot from global to subcommand level (after create/run).
# Scan args and inject --no-pivot right after the create/run subcommand.
# Containerd paths never contain spaces/metacharacters so eval is safe here.
_new=""
for _a in "$@"; do
    case "$_a" in
        create|run) _new="$_new $_a --no-pivot" ;;
        *) _new="$_new $_a" ;;
    esac
done
eval exec /usr/bin/runc.real $_new
RUNC_WRAPPER
chmod +x /usr/bin/runc
log "runc wrapper installed → /usr/bin/runc (real: $RUNC_REAL)"

# ── containerd ───────────────────────────────────────────────────────────────
log "Starting containerd..."
mkdir -p /etc/containerd /run/containerd

cat > /etc/containerd/config.toml << 'CONTAINERD'
version = 2
[plugins."io.containerd.grpc.v1.cri".containerd]
  snapshotter = "overlayfs"
CONTAINERD

CONTAINERD_START=$(awk '{print $1}' /proc/uptime)
containerd > /dev/kmsg 2>&1 &

for i in $(seq 30); do
    [ -S /run/containerd/containerd.sock ] && break
    sleep 1
done

if [ -S /run/containerd/containerd.sock ]; then
    log "BENCH containerd: ready in $(awk -v s="$CONTAINERD_START" '{printf "%.2fs", $1-s}' /proc/uptime)"
else
    log "WARNING: containerd socket not ready after 30s"
fi
stage "containerd"

# ── vsock bridges ────────────────────────────────────────────────────────────
socat VSOCK-LISTEN:2222,reuseaddr,fork TCP:localhost:22 > /dev/kmsg 2>&1 &
SOCAT_PID=$!
# Wait briefly to confirm socat started (it exits immediately on error)
sleep 1
if kill -0 "$SOCAT_PID" 2>/dev/null; then
    log "socat vsock bridge running (PID $SOCAT_PID)"
else
    log "WARNING: socat failed — $(socat VSOCK-LISTEN:2222,reuseaddr TCP:localhost:22 2>&1 | head -1 || true)"
fi

# ── Signal ready to host ─────────────────────────────────────────────────────
touch /vibe-shared/.vibe-ready
log "BENCH total: VM ready in $(ts) since kernel boot"
log "Vibe Runtime ready."
