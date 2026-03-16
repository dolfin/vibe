#!/usr/bin/env bash
# build.sh — Build the Vibe Runtime VM image
#
# Works on macOS and Linux — NO Docker required.
# Downloads Alpine kernel + initrd directly from Alpine CDN,
# injects our init script + SSH key into the initrd,
# and creates a blank persistent data disk.
#
# Usage:
#   ./build.sh [arch]          # arch: arm64 (default on Apple Silicon) or x86_64
#   ./build.sh arm64 --clean   # clean and rebuild
#
# Output:
#   dist/vibe-runtime-<arch>.tar.gz — ready to upload to GitHub Releases
#   dist/vibe-vm.key             — SSH private key (add to Xcode as resource)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
WORK_DIR="$SCRIPT_DIR/.build"

# ── Args ────────────────────────────────────────────────────────────────────
ARCH="${1:-}"
CLEAN="${2:-}"

if [[ -z "$ARCH" ]]; then
    # Auto-detect
    if [[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]]; then
        ARCH=arm64
    else
        ARCH=x86_64
    fi
fi

if [[ "$CLEAN" == "--clean" ]]; then
    rm -rf "$WORK_DIR" "$DIST_DIR"
fi

# ── Alpine version ───────────────────────────────────────────────────────────
ALPINE_VERSION="3.19.1"
ALPINE_MAJOR="v3.19"

case "$ARCH" in
  arm64)
    CDN_ARCH="aarch64"
    KERNEL_NAME="vmlinuz-virt"
    INITRD_NAME="initramfs-virt"
    ALPINE_PKG="linux-virt"
    ;;
  x86_64)
    CDN_ARCH="x86_64"
    KERNEL_NAME="vmlinuz-virt"
    INITRD_NAME="initramfs-virt"
    ALPINE_PKG="linux-virt"
    ;;
  *)
    echo "Unsupported arch: $ARCH (use arm64 or x86_64)" && exit 1
    ;;
esac

ALPINE_BASE="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_MAJOR}/releases/${CDN_ARCH}/netboot-${ALPINE_VERSION}"

echo "╔══════════════════════════════════════════╗"
echo "║   Vibe Runtime VM Image Builder          ║"
echo "║   Arch: $ARCH                              "
echo "╚══════════════════════════════════════════╝"
echo ""

mkdir -p "$DIST_DIR" "$WORK_DIR"

# ── Step 1: SSH key pair ─────────────────────────────────────────────────────
KEY_PRIVATE="$SCRIPT_DIR/vibe-vm.key"
KEY_PUBLIC="$SCRIPT_DIR/vibe-vm.key.pub"

if [[ ! -f "$KEY_PRIVATE" ]]; then
    echo "==> Generating SSH key pair"
    ssh-keygen -t ed25519 -f "$KEY_PRIVATE" -N "" -C "vibe-vm-${ARCH}"
    echo "    ✓ $KEY_PRIVATE"
    echo "    ✓ $KEY_PUBLIC"
fi

SSH_PUBKEY=$(cat "$KEY_PUBLIC")

# ── Step 2: Download kernel + modules from the same linux-lts APK ────────────
# Fetching both from one APK guarantees kernel and modules have the same build.
# VZLinuxBootLoader requires an uncompressed ARM64 Image (magic 0x644d5241).
KERNEL_OUT="$DIST_DIR/kernel"
MODULES_CACHE_DIR="$WORK_DIR/modules"
# linux-virt has virtio_pci, virtio_ring, virtio, virtio_console built-in.
# virtio_net (network) and virtio_blk (data disk) are still modules in linux-virt.
MODULES_NEEDED=(failover net_failover virtio_net virtio_blk fuse virtiofs af_packet vsock overlay llc stp bridge)

_all_cached=true
[[ ! -f "$KERNEL_OUT" ]] && _all_cached=false
for _m in "${MODULES_NEEDED[@]}"; do
    [[ ! -f "$MODULES_CACHE_DIR/$_m.ko" ]] && _all_cached=false && break
done

if [[ "$_all_cached" == "false" ]]; then
    mkdir -p "$MODULES_CACHE_DIR"

    echo "==> Resolving ${ALPINE_PKG} version from Alpine APKINDEX..."
    APKINDEX_URL="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_MAJOR}/main/${CDN_ARCH}/APKINDEX.tar.gz"
    LINUX_VER=$(curl -fsSL "$APKINDEX_URL" 2>/dev/null | \
        tar -xzOf - APKINDEX 2>/dev/null | \
        awk -v pkg="$ALPINE_PKG" '/^P:/{found=($0=="P:"pkg);next} found && /^V:/{sub(/^V:/,""); print; exit} /^$/{found=0}' || true)
    [[ -z "$LINUX_VER" ]] && { echo "ERROR: could not resolve ${ALPINE_PKG} version" >&2; exit 1; }
    echo "    ${ALPINE_PKG} version: $LINUX_VER"

    APK_URL="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_MAJOR}/main/${CDN_ARCH}/${ALPINE_PKG}-${LINUX_VER}.apk"
    APK_FILE="$WORK_DIR/${ALPINE_PKG}.apk"
    echo "==> Downloading ${ALPINE_PKG}-${LINUX_VER}.apk..."
    curl -fL --progress-bar "$APK_URL" -o "$APK_FILE"
    echo "    ✓ APK ($(du -sh "$APK_FILE" | cut -f1))"

    echo "==> Extracting kernel + modules from APK..."
    VMLINUZ_RAW="$WORK_DIR/vmlinuz-lts-raw"
    python3 - "$APK_FILE" "$VMLINUZ_RAW" "$MODULES_CACHE_DIR" << 'PYEOF'
import sys, io, gzip, tarfile, os, lzma

apk_path, kernel_out, modules_dir = sys.argv[1], sys.argv[2], sys.argv[3]
module_targets = {'failover', 'net_failover', 'virtio_net', 'virtio_blk', 'fuse', 'virtiofs', 'af_packet', 'vsock', 'overlay', 'bridge'}
found_modules = {}
kernel_data = None

data = open(apk_path, 'rb').read()

def decompress_ko(raw, name):
    if name.endswith('.ko.gz'):  return gzip.decompress(raw)
    if name.endswith('.ko.xz'):  return lzma.decompress(raw)
    return raw

# Alpine APK = concatenated gzip+tar archives; scan all gzip stream starts
positions = [i for i in range(len(data) - 2)
             if data[i] == 0x1f and data[i+1] == 0x8b and data[i+2] == 0x08]

for pos in positions:
    if kernel_data and found_modules.keys() >= module_targets:
        break
    try:
        with gzip.GzipFile(fileobj=io.BytesIO(data[pos:])) as gz:
            stream = gz.read()
        tf = tarfile.open(fileobj=io.BytesIO(stream), mode='r:')
        for m in tf.getmembers():
            basename = os.path.basename(m.name)
            # Kernel: boot/vmlinuz-virt (linux-virt) or vmlinuz-lts (linux-lts) fallback
            if not kernel_data and basename in ('vmlinuz-virt', 'vmlinuz-lts', 'vmlinuz'):
                content = tf.extractfile(m)
                if content:
                    kernel_data = content.read()
                    print(f'    Kernel: {m.name} ({len(kernel_data):,} bytes)')
            # Modules: fuse.ko, virtiofs.ko, virtio_console.ko
            for ext in ('.ko.gz', '.ko.xz', '.ko'):
                if basename.endswith(ext):
                    modname = basename[:-len(ext)]
                    if modname in module_targets and modname not in found_modules:
                        content = tf.extractfile(m)
                        if content:
                            raw = decompress_ko(content.read(), basename)
                            open(os.path.join(modules_dir, modname + '.ko'), 'wb').write(raw)
                            print(f'    Module:  {modname}.ko ({len(raw):,} bytes) ← {m.name}')
                            found_modules[modname] = True
                    break
    except Exception:
        pass

if not kernel_data:
    sys.exit('ERROR: vmlinuz-lts not found in APK')
open(kernel_out, 'wb').write(kernel_data)

missing = module_targets - found_modules.keys()
if missing:
    print(f'WARNING: missing modules: {", ".join(missing)}', file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PYEOF
    rm -f "$APK_FILE"

    echo "==> Extracting uncompressed ARM64 Image from vmlinuz..."
    python3 - "$VMLINUZ_RAW" "$KERNEL_OUT" << 'PYEOF'
import sys, zlib, struct

vmlinuz_path, out_path = sys.argv[1], sys.argv[2]
data = open(vmlinuz_path, 'rb').read()

# Find the first gzip stream (magic 1f 8b 08 = deflate)
offset = None
for i in range(len(data) - 2):
    if data[i] == 0x1f and data[i+1] == 0x8b and data[i+2] == 0x08:
        offset = i
        break
if offset is None:
    sys.exit('ERROR: No gzip stream found in vmlinuz')
print(f'    Found gzip payload at offset {offset}')

flg = data[offset + 3]
hdr_end = offset + 10
if flg & 0x04:
    xlen = struct.unpack_from('<H', data, hdr_end)[0]; hdr_end += 2 + xlen
if flg & 0x08:
    while data[hdr_end] != 0: hdr_end += 1
    hdr_end += 1
if flg & 0x10:
    while data[hdr_end] != 0: hdr_end += 1
    hdr_end += 1
if flg & 0x02:
    hdr_end += 2

d = zlib.decompressobj(wbits=-15)
try:
    decompressed = d.decompress(data[hdr_end:])
    decompressed += d.flush()
except zlib.error as e:
    decompressed = d.flush()
    if not decompressed:
        sys.exit(f'ERROR: zlib decompress failed: {e}')

magic = struct.unpack_from('<I', decompressed, 56)[0]
if magic != 0x644d5241:
    sys.exit(f'ERROR: Wrong ARM64 magic: {hex(magic)}, expected 0x644d5241')

open(out_path, 'wb').write(decompressed)
print(f'    ARM64 Image: {len(decompressed):,} bytes, magic OK')
PYEOF
    echo "    ✓ kernel ($(du -sh "$KERNEL_OUT" | cut -f1))"
else
    echo "==> Kernel + modules already cached (use --clean to rebuild)"
fi

# ── Step 3: Build initrd from Alpine minirootfs ───────────────────────────────
# Use Alpine minirootfs (complete Alpine base system) instead of the netboot
# initramfs-virt. The minirootfs gives us apk, busybox, adduser, etc.
INITRD_OUT="$DIST_DIR/initrd"
# Invalidate initrd cache when vibe-init.sh is newer than the built initrd.
if [[ -f "$INITRD_OUT" && "$SCRIPT_DIR/vibe-init.sh" -nt "$INITRD_OUT" ]]; then
    echo "==> vibe-init.sh changed — invalidating initrd cache"
    rm -f "$INITRD_OUT"
fi
if [[ ! -f "$INITRD_OUT" ]]; then
    MINIROOTFS_BASE="$WORK_DIR/minirootfs.tar.gz"
    INITRD_EXTRACT="$WORK_DIR/initrd-extract"

    MINIROOTFS_URL="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_MAJOR}/releases/${CDN_ARCH}/alpine-minirootfs-${ALPINE_VERSION}-${CDN_ARCH}.tar.gz"
    echo "==> Downloading Alpine minirootfs..."
    curl -fL --progress-bar "$MINIROOTFS_URL" -o "$MINIROOTFS_BASE"
    echo "    ✓ minirootfs ($(du -sh "$MINIROOTFS_BASE" | cut -f1))"

    echo "==> Extracting Alpine minirootfs..."
    rm -rf "$INITRD_EXTRACT"
    mkdir -p "$INITRD_EXTRACT"
    # --no-same-owner avoids permission errors on macOS when not root
    tar -xzf "$MINIROOTFS_BASE" -C "$INITRD_EXTRACT" --no-same-owner 2>/dev/null || \
        tar -xzf "$MINIROOTFS_BASE" -C "$INITRD_EXTRACT" 2>/dev/null

    echo "==> Injecting Vibe Runtime files..."

    # Inject vibe-init.sh
    mkdir -p "$INITRD_EXTRACT/etc/vibe"
    cp "$SCRIPT_DIR/vibe-init.sh" "$INITRD_EXTRACT/etc/vibe/vibe-init.sh"
    chmod +x "$INITRD_EXTRACT/etc/vibe/vibe-init.sh"

    # Inject Alpine version so vibe-init.sh can version its package cache
    echo "$ALPINE_VERSION" > "$INITRD_EXTRACT/etc/vibe/alpine-version"

    # Inject SSH public key
    echo "$SSH_PUBKEY" > "$INITRD_EXTRACT/etc/vibe/vibe-vm.pub"

    # Inject kernel modules
    mkdir -p "$INITRD_EXTRACT/lib/modules"
    for _mod in "${MODULES_NEEDED[@]}"; do
        if [[ -f "$MODULES_CACHE_DIR/$_mod.ko" ]]; then
            cp "$MODULES_CACHE_DIR/$_mod.ko" "$INITRD_EXTRACT/lib/modules/$_mod.ko"
            echo "    ✓ $_mod.ko injected"
        else
            echo "    WARNING: $_mod.ko not cached — skipping"
        fi
    done

    # Write /init as PID 1
    # The Alpine minirootfs doesn't ship /init — the kernel looks for it first.
    cat > "$INITRD_EXTRACT/init" << 'INITEOF'
#!/bin/sh
# Vibe PID 1 init — runs inside Virtualization.framework VM
# Base: Alpine minirootfs (complete apk/busybox environment)

# Essential kernel interfaces
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mkdir -p /dev/pts /run /tmp /var/run
mount -t devpts devpts /dev/pts 2>/dev/null || true
mount -t tmpfs tmpfs /run 2>/dev/null || true

# Mount cgroup v2 (unified hierarchy) — required by runc
mkdir -p /sys/fs/cgroup
mount -t cgroup2 cgroup2 /sys/fs/cgroup 2>/dev/null || true

# Load virtio_net and virtio_blk — modules even in linux-virt.
# failover must load first (provides failover_register/unregister symbols for net_failover).
# net_failover must load next (provides net_failover_create/destroy symbols for virtio_net).
insmod /lib/modules/af_packet.ko 2>/dev/null || true
insmod /lib/modules/vsock.ko 2>/dev/null || true
insmod /lib/modules/failover.ko 2>/dev/null || true
insmod /lib/modules/net_failover.ko 2>/dev/null || true
insmod /lib/modules/virtio_net.ko 2>/dev/null || true
insmod /lib/modules/virtio_blk.ko 2>/dev/null || true

# Load fuse + virtiofs for host↔VM shared directory
insmod /lib/modules/fuse.ko 2>/dev/null || true
insmod /lib/modules/virtiofs.ko 2>/dev/null || true

# Load overlay for containerd overlayfs snapshotter
insmod /lib/modules/overlay.ko 2>/dev/null || true

# Load bridge for CNI bridge networking
insmod /lib/modules/bridge.ko 2>/dev/null || true

echo "[vibe-init] PID 1 ready, launching vibe-init.sh..." > /dev/kmsg 2>/dev/null || true

/etc/vibe/vibe-init.sh &

while true; do
    wait
    sleep 5
done
INITEOF
    chmod +x "$INITRD_EXTRACT/init"

    echo "==> Repacking as initrd (cpio+gzip)..."
    cd "$INITRD_EXTRACT"
    find . | cpio -H newc -o 2>/dev/null | gzip -9 > "$INITRD_OUT"
    cd "$SCRIPT_DIR"

    echo "    ✓ initrd ($(du -sh "$INITRD_OUT" | cut -f1))"
else
    echo "==> Initrd already present (use --clean to rebuild)"
fi

# ── Step 4: Data disk ────────────────────────────────────────────────────────
# data.img is NOT included in the tarball — the host app creates it on first boot
# using FileHandle.truncate(), which produces a raw sparse file that
# Virtualization.framework accepts without DiskImages format detection issues.

# ── Step 5: Package ─────────────────────────────────────────────────────────
ARCHIVE="$DIST_DIR/vibe-runtime-${ARCH}.tar.gz"
echo ""
echo "==> Packaging $ARCHIVE..."
tar -czf "$ARCHIVE" -C "$DIST_DIR" kernel initrd
echo "    ✓ $(du -sh "$ARCHIVE" | cut -f1)"

# Copy private key to dist for reference
cp "$KEY_PRIVATE" "$DIST_DIR/vibe-vm.key"
cp "$KEY_PUBLIC"  "$DIST_DIR/vibe-vm.pub"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   Build complete!                        ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "Artifact: $ARCHIVE"
echo ""
echo "Next steps:"
echo ""
echo "  1. Copy SSH key to Xcode resources:"
echo "       cp $DIST_DIR/vibe-vm.key \\"
echo "          $(dirname "$SCRIPT_DIR")/apps/mac-host/VibeHost/Resources/vibe-vm.key"
echo ""
echo "  2. Test locally in the app:"
echo "       In VibeHost → open any project → Runtime → Load Local Image..."
echo "       Select: $ARCHIVE"
echo ""
echo "  3. Upload to GitHub Releases as:"
echo "       vibe-runtime-${ARCH}.tar.gz"
echo "       Then update VMManager.imageBase URL."
echo ""
