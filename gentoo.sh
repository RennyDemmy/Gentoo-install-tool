#!/usr/bin/env bash
# Exit on error is enabled selectively in functions to prevent the menu from crashing
set -e

# ==========================================
# HELPER FUNCTIONS
# ==========================================
function check_uefi() {
    if [ ! -d /sys/firmware/efi ]; then
        echo "❌ ERROR: NOT BOOTED IN UEFI MODE!"
        echo "This script strictly requires a UEFI environment, but your system"
        echo "is currently booted in Legacy BIOS / CSM mode."
        echo "Please reboot your LiveUSB and select the UEFI boot option."
        exit 1
    fi
}

function show_drives() {
    echo "------------------------------------------"
    echo " Available Drives:"
    echo "------------------------------------------"
    # List block devices cleanly (excluding loopbacks/LiveCD mounts)
    lsblk -d -p -o NAME,SIZE,MODEL,VENDOR | grep -v "loop"
    echo "------------------------------------------"
}

# ==========================================
# MENU OPTION 2: RECOVERY CHROOT
# ==========================================
function recovery_chroot() {
    set +e # Don't crash the whole menu if a mount fails
    echo "=========================================="
    echo " Gentoo System Recovery Chroot            "
    echo "=========================================="
    show_drives

    while true; do
        read -p "Type the exact drive path where Gentoo is installed (e.g. /dev/sda, /dev/nvme0n1): " DISK
        if [ -b "$DISK" ]; then
            break
        else
            echo "Error: '$DISK' is not a valid block device. Please try again."
        fi
    done

    # Smarter partition block naming
    if [[ "$DISK" =~ [0-9]$ ]]; then
        P="${DISK}p"
    else
        P="${DISK}"
    fi

    echo "[*] Creating mount points..."
    mkdir -p /mnt/gentoo

    echo "[*] Mounting Root Partition (${P}3)..."
    mount "${P}3" /mnt/gentoo
    if [ $? -ne 0 ]; then
        echo "❌ ERROR: Failed to mount ${P}3. Are you sure Gentoo is installed here?"
        return
    fi

    echo "[*] Mounting EFI Partition (${P}1)..."
    mkdir -p /mnt/gentoo/boot/efi
    mount "${P}1" /mnt/gentoo/boot/efi || echo "⚠️ Warning: Failed to mount EFI. Skipping."

    echo "[*] Mounting virtual filesystems (proc, sys, dev, run)..."
    mount --types proc /proc /mnt/gentoo/proc
    mount --rbind /sys /mnt/gentoo/sys
    mount --make-rslave /mnt/gentoo/sys
    mount --rbind /dev /mnt/gentoo/dev
    mount --make-rslave /mnt/gentoo/dev
    mount --bind /run /mnt/gentoo/run
    mount --make-slave /mnt/gentoo/run

    echo "[*] Injecting Host DNS configuration for internet access..."
    rm -f /mnt/gentoo/etc/resolv.conf
    cp --dereference /etc/resolv.conf /mnt/gentoo/etc/

    echo ""
    echo "=========================================================="
    echo "✅ YOU ARE NOW IN THE CHROOT!"
    echo "You can repair GRUB, update packages, or change passwords."
    echo "When you are finished, type 'exit' to safely unmount."
    echo "=========================================================="
    
    # Enter the chroot
    chroot /mnt/gentoo /bin/bash

    # Cleanup sequence after exiting
    echo "=========================================="
    echo "[*] Exited chroot. Cleaning up system..."
    echo "=========================================="
    
    echo "[*] Restoring systemd-resolved DNS symlink..."
    ln -snf ../run/systemd/resolve/stub-resolv.conf /mnt/gentoo/etc/resolv.conf || true

    echo "[*] Unmounting filesystems..."
    umount -l /mnt/gentoo/dev{/shm,/pts,} || true
    umount -R /mnt/gentoo || true
    echo "✅ Recovery cleanup complete."
    set -e
}

# ==========================================
# MENU OPTION 1: INSTALL GENTOO
# ==========================================
function install_gentoo() {
    set -e
    
    TIMEZONE="Europe/Istanbul"
    MAKEOPTS="-j$(nproc)"

    # Prompt for Hostname
    read -p "Enter desired Hostname [gentoo-gnome]: " HOSTNAME
    HOSTNAME=${HOSTNAME:-gentoo-gnome}

    # Prompt for User Details
    while true; do
        read -p "Enter username for your new desktop user: " NEW_USER
        if [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            break
        else
            echo "Invalid username. Please use only lowercase letters, numbers, and underscores."
        fi
    done

    read -s -p "Enter password for desktop user ($NEW_USER): " USER_PASS
    echo
    read -s -p "Enter ROOT password: " ROOT_PASS
    echo

    show_drives
    while true; do
        read -p "Type the exact drive path to install to (e.g. /dev/sda, /dev/vda, /dev/nvme0n1): " DISK
        if [ -b "$DISK" ]; then
            break
        else
            echo "Error: '$DISK' is not a valid block device. Please try again."
        fi
    done

    # Final Safety Check
    echo ""
    echo "⚠️  WARNING: ALL DATA ON $DISK AND ITS PARTITIONS WILL BE DESTROYED ⚠️"
    read -p "Are you absolutely sure you want to continue? (Type 'yes' to proceed): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Aborting installation."
        exit 1
    fi

    if [[ "$DISK" =~ [0-9]$ ]]; then
        P="${DISK}p"
    else
        P="${DISK}"
    fi

    echo "=========================================="
    echo " Starting Installation...                 "
    echo "=========================================="

    echo "[1/8] Unmounting lingering partitions and deactivating swap..."
    swapoff -a || true
    umount "${DISK}"* 2>/dev/null || true

    echo "[1/8] Wiping old filesystems and partition tables on ${DISK}..."
    wipefs -a -f "${DISK}"
    sgdisk -Z "${DISK}"

    echo "[1/8] Creating new UEFI partition layout..."
    sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"efi" "${DISK}"
    sgdisk -n 2:0:+4G -t 2:8200 -c 2:"swap" "${DISK}"
    sgdisk -n 3:0:0 -t 3:8300 -c 3:"rootfs" "${DISK}"

    echo "[1/8] Reloading partition tables..."
    partprobe "${DISK}"
    sleep 3

    echo "[2/8] Formatting partitions..."
    mkfs.vfat -F 32 "${P}1"
    mkswap "${P}2"
swapon "${P}2"
    mkfs.ext4 -F "${P}3"

    echo "[3/8] Mounting partitions..."
    mount "${P}3" /mnt/gentoo
    mkdir -p /mnt/gentoo/boot/efi
    mount "${P}1" /mnt/gentoo/boot/efi

    echo "[4/8] Fetching and extracting systemd stage3 tarball..."
    cd /mnt/gentoo
    wget "https://distfiles.gentoo.org/releases/amd64/autobuilds/20260913T163055Z/stage3-amd64-desktop-systemd-20260913T163055Z.tar.xz" -O stage3.tar.xz
    tar xpvf stage3.tar.xz --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo
    rm stage3.tar.xz

    echo "[5/8] Preparing chroot environment..."
    rm -f /mnt/gentoo/etc/resolv.conf
    cp --dereference /etc/resolv.conf /mnt/gentoo/etc/

    mount --types proc /proc /mnt/gentoo/proc
    mount --rbind /sys /mnt/gentoo/sys
    mount --make-rslave /mnt/gentoo/sys
    mount --rbind /dev /mnt/gentoo/dev
    mount --make-rslave /mnt/gentoo/dev
    mount --bind /run /mnt/gentoo/run
    mount --make-slave /mnt/gentoo/run

    echo "[6/8] Entering chroot to configure the system..."
    chroot /mnt/gentoo /bin/bash <<EOF
set -e
source /etc/profile
export PS1="(chroot) \${PS1}"

echo "[Chroot] Initializing binary package trust keys (getuto)..."
getuto

echo "[Chroot] Generating systemd machine-id..."
systemd-machine-id-setup

echo "[Chroot] Syncing portage..."
emerge-webrsync

TARGET_PROFILE=\$(eselect profile list | grep -i "default/linux/amd64/.*/desktop/gnome/systemd" | grep -v nomultilib | grep -v llvm | tail -n1 | awk '{print \$1}' | tr -d '[]')
if [ -z "\${TARGET_PROFILE}" ]; then
    echo "[Chroot] ERROR: Could not find the GNOME systemd profile!"
    eselect profile list
    exit 1
fi

eselect profile set \${TARGET_PROFILE}
echo "[Chroot] Profile set to \$(eselect profile show)"

cat <<CONF > /etc/portage/make.conf
COMMON_FLAGS="-O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"

MAKEOPTS="${MAKEOPTS}"
ACCEPT_LICENSE="*"

LC_MESSAGES=C.utf8
GRUB_PLATFORMS="efi-64"

FEATURES="getbinpkg"
EMERGE_DEFAULT_OPTS="--getbinpkg --usepkg --binpkg-respect-use=y --binpkg-changed-deps=y"
CONF

mkdir -p /etc/portage/package.accept_keywords
echo "x11-drivers/nvidia-drivers ~amd64" > /etc/portage/package.accept_keywords/nvidia

echo "[Chroot] Configuring timezone, locale, and hostname..."
ln -snf ../usr/share/zoneinfo/${TIMEZONE} /etc/localtime
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
eselect locale set en_US.utf8 || eselect locale set en_US.UTF-8
echo "LANG=\"en_US.UTF-8\"" > /etc/env.d/02locale
env-update && source /etc/profile

echo "${HOSTNAME}" > /etc/hostname

echo "[Chroot] Generating /etc/fstab..."
cat <<FSTAB > /etc/fstab
/dev/disk/by-partlabel/efi     /boot/efi   vfat  umask=0077  0 2
/dev/disk/by-partlabel/swap    none        swap  sw          0 0
/dev/disk/by-partlabel/rootfs  /           ext4  noatime     0 1
FSTAB

echo "[Chroot] Resolving Portage USE flag conflicts..."
mkdir -p /etc/portage/package.use
echo "sys-kernel/installkernel grub dracut" > /etc/portage/package.use/installkernel

cat <<USE > /etc/portage/package.use/gnome-deps
dev-qt/qt5compat icu
dev-qt/qtbase icu
net-libs/ngtcp2 gnutls
USE

echo "[Chroot] Installing GRUB, Kernel hooks, and Firmware..."
emerge sys-boot/grub sys-kernel/installkernel sys-kernel/dracut sys-kernel/linux-firmware

echo "[Chroot] Configuring /etc/default/grub..."
cat <<GRUB > /etc/default/grub
GRUB_DISTRIBUTOR="Gentoo"
GRUB_DEFAULT=0
GRUB_TIMEOUT=3
GRUB_CMDLINE_LINUX="root=PARTLABEL=rootfs rw quiet nvidia_drm.modeset=1 nvidia_drm.fbdev=1"
GRUB_GFXMODE=auto
GRUB_DISABLE_OS_PROBER=true
GRUB

echo "[Chroot] Installing GRUB to EFI Partition..."
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Gentoo
grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable

echo "[Chroot] Compiling/Installing Kernel (This takes a moment)..."
emerge sys-kernel/gentoo-kernel-bin
grub-mkconfig -o /boot/grub/grub.cfg

echo "[Chroot] Updating @world and Installing GNOME, Flatpak, Firefox, and Nvidia Drivers..."
emerge -uDN @world x11-drivers/nvidia-drivers gnome-base/gnome gnome-base/gdm sys-apps/flatpak www-client/firefox-bin

echo "[Chroot] Installing explicit networking backend tools..."
emerge net-misc/networkmanager net-misc/dhcpcd net-wireless/wpa_supplicant net-wireless/iw

echo "[Chroot] Integrating NetworkManager and systemd-resolved..."
mkdir -p /etc/NetworkManager/conf.d
cat <<NMCONF > /etc/NetworkManager/conf.d/dns.conf
[main]
dns=systemd-resolved
NMCONF

echo "[Chroot] Enabling basic systemd services..."
systemctl enable NetworkManager.service
systemctl enable gdm.service
systemctl enable systemd-resolved.service
systemctl enable systemd-timesyncd.service

echo "[Chroot] Installing extra system tools..."
emerge sys-fs/e2fsprogs sys-fs/dosfstools app-admin/sudo

echo "[Chroot] Setting root password..."
echo "root:${ROOT_PASS}" | chpasswd

echo "[Chroot] Creating desktop user ${NEW_USER}..."
useradd -m -G wheel,audio,video,usb,cdrom,portage,kvm,render,input -s /bin/bash ${NEW_USER}
echo "${NEW_USER}:${USER_PASS}" | chpasswd

echo "[Chroot] Granting sudo access to the wheel group..."
mkdir -p /etc/sudoers.d
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel

echo "[Chroot] Restoring systemd-resolved symlink..."
ln -snf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

echo "[Chroot] Done!"
EOF

    echo "[7/8] Exiting chroot and unmounting..."
    cd /
    umount -l /mnt/gentoo/dev{/shm,/pts,}
    umount -R /mnt/gentoo

    echo "=========================================="
    echo "[8/8] INSTALLATION COMPLETE!"
    echo "GNOME, Firefox, Flatpak, and Nvidia Drivers are installed."
    echo "Networking is fully configured."
    echo "GRUB has been successfully installed and configured."
    echo "You can now type 'reboot'."
    echo "=========================================="
}

# ==========================================
# MAIN MENU LOOP
# ==========================================
check_uefi

while true; do
    clear
    echo "=========================================="
    echo " Gentoo GNOME Automated Interactive Setup "
    echo "=========================================="
    echo " 1) Install Gentoo"
    echo " 2) Recovery Chroot (Repair Existing System)"
    echo " 3) Exit"
    echo "=========================================="
    read -p "Select an option [1-3]: " CHOICE

    case $CHOICE in
        1)
            install_gentoo
            exit 0
            ;;
        2)
            recovery_chroot
            read -p "Press Enter to return to the main menu..."
            ;;
        3)
            echo "Exiting..."
            exit 0
            ;;
        *)
            echo "Invalid option. Please enter 1, 2, or 3."
            sleep 2
            ;;
    esac
done