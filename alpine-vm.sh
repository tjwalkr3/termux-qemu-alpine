#!/data/data/com.termux/files/usr/bin/bash
set -e

ALPINE_VERSION="3.24.4"
ALPINE_BRANCH="v${ALPINE_VERSION%.*}"
ISO_NAME="alpine-virt-${ALPINE_VERSION}-aarch64.iso"
ISO_URL="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/releases/aarch64/${ISO_NAME}"
VMDIR="$HOME/alpine-vm"
CODE_FW="$PREFIX/share/qemu/edk2-aarch64-code.fd"
DISK_SIZE="2G"
RAM="1024"
CPUS="2"
VM_HOSTNAME="alpine"
VM_TIMEZONE="MST7MDT"
VM_ROOT_PASSWORD="Password123!"
VM_USER="user"
VM_USER_FULLNAME="John Doe"
VM_USER_PASSWORD="Password123!"

install_qemu() {
    pkg update -y
    pkg upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
    pkg install -y qemu-system-aarch64-headless qemu-utils curl expect
}

run_vm() {
    expect -c "
    set timeout -1
    spawn qemu-system-aarch64 -machine virt -cpu max -m $RAM -smp cpus=$CPUS \
        -drive if=pflash,format=raw,readonly=on,file=$CODE_FW \
        -drive if=pflash,format=raw,file=$VMDIR/edk2-aarch64-vars.fd \
        -netdev user,id=n1,dns=8.8.8.8 \
        -device virtio-net-pci,netdev=n1 -nographic $1
    foreach {prompt reply} {$2} {
        expect -ex \$prompt {} eof {exit 1}
        send -- \"\$reply\r\"
    }
    $3
    "
}

do_init() {
    if ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
        install_qemu
    else
        echo "QEMU already installed, skipping."
    fi

    mkdir -p "$VMDIR"

    if [ ! -f "$CODE_FW" ]; then
        echo "Expected UEFI firmware not found at $CODE_FW" >&2
        echo "Check 'pkg list-files qemu-system-aarch64-headless' for the actual path." >&2
        exit 1
    fi

    if [ ! -f "$VMDIR/edk2-aarch64-vars.fd" ]; then
        dd if=/dev/zero of="$VMDIR/edk2-aarch64-vars.fd" bs=1 count=0 seek="$(stat -c%s "$CODE_FW")" 2>/dev/null
    fi

    if [ ! -f "$VMDIR/alpine.iso" ]; then
        echo ">>> Downloading ${ISO_NAME}..."
        if ! curl -fL -o "$VMDIR/alpine.iso.part" "$ISO_URL"; then
            rm -f "$VMDIR/alpine.iso.part"
            echo "Download failed: $ISO_URL" >&2
            echo "Check available ISOs at ${ISO_URL%/*}/ and adjust ALPINE_VERSION." >&2
            exit 1
        fi
        mv "$VMDIR/alpine.iso.part" "$VMDIR/alpine.iso"
    fi

    if [ ! -f "$VMDIR/alpine.qcow2" ]; then
        echo ">>> Installing Alpine..."
        qemu-img create -f qcow2 "$VMDIR/alpine.qcow2.part" "$DISK_SIZE"
        run_vm "-drive file=$VMDIR/alpine.qcow2.part,if=virtio,format=qcow2 -cdrom $VMDIR/alpine.iso" "
            {login:} {root}
            {:~#} {setup-alpine}
            {Enter system hostname} {$VM_HOSTNAME}
            {Which one do you want to initialize?} {eth0}
            {IPv4 address for eth0?} {dhcp}
            {IPv6 address for eth0?} {dhcp}
            {manual network configuration?} {n}
            {New password:} {$VM_ROOT_PASSWORD}
            {Retype password:} {$VM_ROOT_PASSWORD}
            {Which timezone are you in?} {$VM_TIMEZONE}
            {HTTP/FTP proxy URL?} {none}
            {Which NTP client to run?} {busybox}
            {Enter mirror number or URL:} {c}
            {Enter mirror number or URL:} {1}
            {Setup a user?} {$VM_USER}
            {Full name for user} {$VM_USER_FULLNAME}
            {New password:} {$VM_USER_PASSWORD}
            {Retype password:} {$VM_USER_PASSWORD}
            {Enter ssh key or URL} {none}
            {Which ssh server?} {openssh}
            {Which disk(s) would you like to use?} {vda}
            {How would you like to use it?} {sys}
            {Erase the above disk(s) and continue?} {y}
            {Installation is complete} {poweroff}
        " "expect eof"
        mv "$VMDIR/alpine.qcow2.part" "$VMDIR/alpine.qcow2"
    fi

    echo "Init complete. Run with --start to boot the VM."
}

do_start() {
    if ! command -v qemu-system-aarch64 >/dev/null 2>&1 || [ ! -f "$VMDIR/alpine.qcow2" ]; then
        echo "VM not initialized. Run with --init first."
        exit 1
    fi

    echo ">>> Booting VM (stateless: -snapshot enabled, disk changes are discarded on exit)..."

    run_vm "-drive file=$VMDIR/alpine.qcow2,if=virtio,format=qcow2 -snapshot -no-reboot" "" interact
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
