#!/data/data/com.termux/files/usr/bin/bash
set -e

ALPINE_VERSION="3.24.4"
ALPINE_BRANCH="v${ALPINE_VERSION%.*}"   # e.g. 3.24.4 -> v3.24
ISO_NAME="alpine-virt-${ALPINE_VERSION}-aarch64.iso"
ISO_URL="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/releases/aarch64/${ISO_NAME}"
REPO_BASE="http://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}"
VMDIR="$HOME/alpine-vm"
CODE_FW="$PREFIX/share/qemu/edk2-aarch64-code.fd"
DISK_SIZE="2G"
RAM="1024"
CPUS="2"

install_qemu() {
    pkg update -y
    pkg upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
    pkg install -y qemu-system-aarch64-headless qemu-utils curl expect
}

do_init() {
    if ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
        install_qemu
    else
        echo "QEMU already installed, skipping."
    fi

    mkdir -p "$VMDIR"

    if [ ! -f "$VMDIR/alpine.iso" ]; then
        echo ">>> Downloading ${ISO_NAME}..."
        if ! curl -fL -o "$VMDIR/alpine.iso.part" "$ISO_URL"; then
            rm -f "$VMDIR/alpine.iso.part"
            echo "Download failed: $ISO_URL" >&2
            echo "Check available ISOs at ${REPO_BASE}/releases/aarch64/ and adjust ALPINE_VERSION." >&2
            exit 1
        fi
        mv "$VMDIR/alpine.iso.part" "$VMDIR/alpine.iso"
    fi

    if [ ! -f "$VMDIR/alpine.qcow2" ]; then
        qemu-img create -f qcow2 "$VMDIR/alpine.qcow2" "$DISK_SIZE"
    fi

    if [ ! -f "$CODE_FW" ]; then
        echo "Expected UEFI firmware not found at $CODE_FW" >&2
        echo "Check 'pkg list-files qemu-system-aarch64-headless' for the actual path." >&2
        exit 1
    fi

    if [ ! -f "$VMDIR/edk2-aarch64-vars.fd" ]; then
        dd if=/dev/zero of="$VMDIR/edk2-aarch64-vars.fd" bs=1 count=0 seek="$(stat -c%s "$CODE_FW")" 2>/dev/null
    fi

    echo "Init complete. Run with --start to boot the VM."
}

do_start() {
    if ! command -v qemu-system-aarch64 >/dev/null 2>&1 \
        || [ ! -f "$VMDIR/alpine.qcow2" ] \
        || [ ! -f "$VMDIR/alpine.iso" ] \
        || [ ! -f "$VMDIR/edk2-aarch64-vars.fd" ]; then
        echo "VM not initialized. Run with --init first."
        exit 1
    fi

    echo ">>> Booting VM (stateless: -snapshot enabled, disk changes are discarded on exit)..."

    expect -c "
    set timeout -1
    spawn qemu-system-aarch64 -machine virt -cpu max -m $RAM -smp cpus=$CPUS \
        -drive if=pflash,format=raw,readonly=on,file=$CODE_FW \
        -drive if=pflash,format=raw,file=$VMDIR/edk2-aarch64-vars.fd \
        -drive file=$VMDIR/alpine.qcow2,if=virtio,format=qcow2 -snapshot \
        -cdrom $VMDIR/alpine.iso \
        -netdev user,id=n1,dns=8.8.8.8 \
        -device virtio-net-pci,netdev=n1 -nographic

    expect \"localhost login:\"
    send \"root\r\"

    expect \"localhost:~#\"
    send \"stty cols 80 rows 24\r\"

    expect \"localhost:~#\"
    send \"setup-interfaces -a\r\"

    expect \"localhost:~#\"
    send \"rc-service networking start\r\"

    expect \"localhost:~#\"
    send \"echo ${REPO_BASE}/main >> /etc/apk/repositories\r\"

    expect \"localhost:~#\"
    send \"echo ${REPO_BASE}/community >> /etc/apk/repositories\r\"

    expect \"localhost:~#\"
    send \"apk update\r\"

    expect \"localhost:~#\"
    send \"apk upgrade --available\r\"

    expect \"localhost:~#\"
    interact
    "
}

do_clean() {
    rm -rf "$VMDIR"
    echo "VM files removed. Run with --init to set up again."
}

case "$1" in
    --init)  do_init ;;
    --start) do_start ;;
    --clean) do_clean ;;
    *)
        echo "Usage: $0 --init|--start|--clean"
        exit 1
        ;;
esac
