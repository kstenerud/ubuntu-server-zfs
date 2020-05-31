#!/bin/bash
#
# Copyright 2020 Karl Stenerud, released under MIT license (see README.md)
#
# This script installs Ubuntu Server with a ZFS root. It must be launched from
# a running Linux "bootstrap" system (tested with the Ubuntu live CD).
#
# WARNING: This will overwrite the disk specified by $CFG_DISK without asking!
#
# The default configuration settings are for running in a KVM virtual machine,
# and will be different on actual hardware.
#
# Optional: Install SSHD in the live CD session to run over SSH:
#   sudo apt install --yes openssh-server vim && echo -e "ubuntu\nubuntu" | passwd ubuntu


set -eux


# Configuration
# -------------

# Identifier to use when creating zfs data sets (default: random).
CFG_ZFSID=$(dd if=/dev/urandom of=/dev/stdout bs=1 count=100 2>/dev/null | tr -dc 'a-z0-9' | cut -c-6)

# The disk to partition. On a real machine, this should be /dev/disk/by-id/xyz.
CFG_DISK=/dev/disk/by-path/virtio-pci-0000:03:00.0

# The ethernet device to use
CFG_ETH=enp1s0

# The host's name
CFG_HOSTNAME=ubuntu-server

# The user to create. Password will be the same as the name.
CFG_USERNAME=ubuntu

# The time zone to set
CFG_TIMEZONE=Europe/Berlin

# Where to get the debs from
CFG_ARCHIVE=http://de.archive.ubuntu.com/ubuntu/

# Which Ubuntu version to install (focal=20.04, eoan=19.10, etc)
CFG_UBUNTU_VERSION=focal



# Vars
# ----

has_uefi=$([ -d /sys/firmware/efi ] && echo true || echo false)



# Prepare software
# ----------------

apt-add-repository universe
apt update
apt install --yes debootstrap gdisk zfs-initramfs dosfstools
systemctl stop zed



# Remove leftovers from failed script (if any)
# --------------------------------------------

umount -l /mnt/dev 2>/dev/null || true
umount -l /mnt/proc 2>/dev/null || true
umount -l /mnt/sys 2>/dev/null || true
umount -l /mnt 2>/dev/null || true
swapoff ${CFG_DISK}-part2 2>/dev/null || true
zpool destroy bpool 2>/dev/null | true
zpool destroy rpool 2>/dev/null | true



# Partitions
# ----------

sgdisk --zap-all $CFG_DISK
# Bootloader partition (UEFI)
sgdisk     -n1:1M:+512M   -t1:EF00 $CFG_DISK
# Swap partition (non-zfs due to deadlock bug)
sgdisk     -n2:0:+500M    -t2:8200 $CFG_DISK
# Boot pool partition
sgdisk     -n3:0:+2G      -t3:BE00 $CFG_DISK
if [ ! "$has_uefi" == true ]; then
  sgdisk -a1 -n5:24K:+1000K -t5:EF02 $CFG_DISK
fi
# Root pool partition
sgdisk     -n4:0:0        -t4:BF00 $CFG_DISK

sleep 1

# EFI
mkdosfs -F 32 -s 1 -n EFI ${CFG_DISK}-part1

# Swap
mkswap -f ${CFG_DISK}-part2

# Boot pool
zpool create -f \
    -o ashift=12 -d \
    -o feature@async_destroy=enabled \
    -o feature@bookmarks=enabled \
    -o feature@embedded_data=enabled \
    -o feature@empty_bpobj=enabled \
    -o feature@enabled_txg=enabled \
    -o feature@extensible_dataset=enabled \
    -o feature@filesystem_limits=enabled \
    -o feature@hole_birth=enabled \
    -o feature@large_blocks=enabled \
    -o feature@lz4_compress=enabled \
    -o feature@spacemap_histogram=enabled \
    -o feature@zpool_checkpoint=enabled \
    -O acltype=posixacl -O canmount=off -O compression=lz4 \
    -O devices=off -O normalization=formD -O relatime=on -O xattr=sa \
    -O mountpoint=/boot -R /mnt \
    bpool ${CFG_DISK}-part3
zfs create -o canmount=off -o mountpoint=none bpool/BOOT

# Root pool
zpool create -f \
    -o ashift=12 \
    -O acltype=posixacl -O canmount=off -O compression=lz4 \
    -O dnodesize=auto -O normalization=formD -O relatime=on \
    -O xattr=sa -O mountpoint=/ -R /mnt \
    rpool ${CFG_DISK}-part4
zfs create -o canmount=off -o mountpoint=none rpool/ROOT

# /
zfs create -o canmount=noauto -o mountpoint=/ \
    -o com.ubuntu.zsys:bootfs=yes \
    -o com.ubuntu.zsys:last-used=$(date +%s) rpool/ROOT/ubuntu_$CFG_ZFSID
zfs mount rpool/ROOT/ubuntu_$CFG_ZFSID
zfs create -o canmount=off -o mountpoint=/ rpool/USERDATA
zfs create -o com.ubuntu.zsys:bootfs-datasets=rpool/ROOT/ubuntu_$CFG_ZFSID \
    -o canmount=on -o mountpoint=/root rpool/USERDATA/root_$CFG_ZFSID

# /boot
zfs create -o canmount=noauto -o mountpoint=/boot bpool/BOOT/ubuntu_$CFG_ZFSID
zfs mount bpool/BOOT/ubuntu_$CFG_ZFSID

# /home/user
zfs create -o com.ubuntu.zsys:bootfs-datasets=rpool/ROOT/ubuntu_$CFG_ZFSID \
    -o canmount=on -o mountpoint=/home/$CFG_USERNAME rpool/USERDATA/$CFG_USERNAME

# /srv
zfs create -o com.ubuntu.zsys:bootfs=no rpool/ROOT/ubuntu_$CFG_ZFSID/srv

# /tmp
zfs create -o com.ubuntu.zsys:bootfs=no rpool/ROOT/ubuntu_$CFG_ZFSID/tmp
chmod 1777 /mnt/tmp

# /usr
zfs create -o com.ubuntu.zsys:bootfs=no -o canmount=off rpool/ROOT/ubuntu_$CFG_ZFSID/usr
zfs create rpool/ROOT/ubuntu_$CFG_ZFSID/usr/local

# /var
zfs create -o com.ubuntu.zsys:bootfs=no -o canmount=off rpool/ROOT/ubuntu_$CFG_ZFSID/var
zfs create rpool/ROOT/ubuntu_$CFG_ZFSID/var/games
zfs create rpool/ROOT/ubuntu_$CFG_ZFSID/var/lib
zfs create rpool/ROOT/ubuntu_$CFG_ZFSID/var/lib/AccountsService
zfs create rpool/ROOT/ubuntu_$CFG_ZFSID/var/lib/apt
zfs create rpool/ROOT/ubuntu_$CFG_ZFSID/var/lib/dpkg
zfs create rpool/ROOT/ubuntu_$CFG_ZFSID/var/lib/NetworkManager
zfs create rpool/ROOT/ubuntu_$CFG_ZFSID/var/log
zfs create rpool/ROOT/ubuntu_$CFG_ZFSID/var/mail
zfs create rpool/ROOT/ubuntu_$CFG_ZFSID/var/snap
zfs create rpool/ROOT/ubuntu_$CFG_ZFSID/var/spool
zfs create rpool/ROOT/ubuntu_$CFG_ZFSID/var/www



# Bootstrap
# ---------

debootstrap $CFG_UBUNTU_VERSION /mnt

cat <<BOOTSTRAP2_SH_EOF >/mnt/root/bootstrap2.sh
#!/bin/bash

set -eux

# Locale/TZ
echo "locales locales/default_environment_locale select en_US.UTF-8" | debconf-set-selections
echo "locales locales/locales_to_be_generated multiselect en_US.UTF-8 UTF-8" | debconf-set-selections
rm -f "/etc/locale.gen"
dpkg-reconfigure --frontend noninteractive locales

ln -fs /usr/share/zoneinfo/$CFG_TIMEZONE /etc/localtime
dpkg-reconfigure -f noninteractive tzdata


# Configuration
echo $CFG_HOSTNAME > /etc/hostname
echo "127.0.1.1       $CFG_HOSTNAME" >> /etc/hosts
cat >/etc/netplan/01-netcfg.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $CFG_ETH:
      dhcp4: false
      dhcp6: false
  bridges:
    br0:
      interfaces: [$CFG_ETH]
      dhcp4: true
      dhcp6: true
      parameters:
        stp: false
        forward-delay: 0
EOF

cat >/etc/apt/sources.list <<EOF
deb $CFG_ARCHIVE $CFG_UBUNTU_VERSION main restricted universe multiverse
deb $CFG_ARCHIVE $CFG_UBUNTU_VERSION-updates main restricted universe multiverse
deb $CFG_ARCHIVE $CFG_UBUNTU_VERSION-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu $CFG_UBUNTU_VERSION-security main restricted universe multiverse
EOF
apt update


# EFI
mkdir /boot/efi
echo UUID=$(blkid -s UUID -o value ${CFG_DISK}-part1) /boot/efi vfat umask=0022,fmask=0022,dmask=0022 0 1 >> /etc/fstab
mount /boot/efi

mkdir /boot/efi/grub /boot/grub
echo /boot/efi/grub /boot/grub none defaults,bind 0 0 >> /etc/fstab
mount /boot/grub

if [ "$has_uefi" == true ]; then
  apt install --yes grub-efi-amd64 grub-efi-amd64-signed linux-image-generic shim-signed zfs-initramfs zsys
else
  # Note: grub-pc will ask where to write
  apt install --yes grub-pc linux-image-generic zfs-initramfs zsys
fi
dpkg --purge os-prober


# Swap
echo UUID=$(blkid -s UUID -o value ${CFG_DISK}-part2) none swap discard 0 0 >> /etc/fstab
swapon -a


# System groups
addgroup --system lpadmin
addgroup --system lxd
addgroup --system sambashare


# GRUB
grub-probe /boot
update-initramfs -c -k all
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\([^"]*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 init_on_alloc=0"/g' /etc/default/grub
update-grub
if [ "$has_uefi" == true ]; then
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck --no-floppy
else
  grub-install $CFG_DISK
fi

## FS mount ordering
mkdir /etc/zfs/zfs-list.cache
touch /etc/zfs/zfs-list.cache/bpool
touch /etc/zfs/zfs-list.cache/rpool
ln -s /usr/lib/zfs-linux/zed.d/history_event-zfs-list-cacher.sh /etc/zfs/zed.d
zed -F &
zed_pid=\$!
sleep 5
kill \$zed_pid
sed -Ei "s|/mnt/?|/|" /etc/zfs/zfs-list.cache/*


# Add user
adduser --disabled-password --gecos "" $CFG_USERNAME
cp -a /etc/skel/. /home/$CFG_USERNAME
chown -R $CFG_USERNAME:$CFG_USERNAME /home/$CFG_USERNAME
usermod -a -G adm,cdrom,dip,lpadmin,lxd,plugdev,sambashare,sudo $CFG_USERNAME
echo -e "$CFG_USERNAME\n$CFG_USERNAME" | passwd $CFG_USERNAME


# Install ssh
apt dist-upgrade --yes
apt install --yes openssh-server vim


# Disable logrotote compression since zfs does that already
for file in /etc/logrotate.d/* ; do
    if grep -Eq "(^|[^#y])compress" "\$file" ; then
        sed -i -r "s/(^|[^#y])(compress)/\1#\2/" "\$file"
    fi
done
BOOTSTRAP2_SH_EOF
chmod a+x /mnt/root/bootstrap2.sh

mount --rbind /dev  /mnt/dev
mount --rbind /proc /mnt/proc
mount --rbind /sys  /mnt/sys
chroot /mnt /usr/bin/env \
  has_uefi=$has_uefi \
  CFG_DISK=$CFG_DISK \
  CFG_HOSTNAME=$CFG_HOSTNAME \
  CFG_USERNAME=$CFG_USERNAME \
  CFG_ETH=$CFG_ETH \
  CFG_TIMEZONE=$CFG_TIMEZONE \
  CFG_ARCHIVE=$CFG_ARCHIVE \
  CFG_UBUNTU_VERSION=$CFG_UBUNTU_VERSION \
  bash --login /root/bootstrap2.sh
rm /mnt/root/bootstrap2.sh



# Installation finisher script
# ----------------------------

cat <<EOF >/mnt/home/$CFG_USERNAME/finish-install.sh
#!/bin/bash

set -eux

sudo DEBIAN_FRONTEND=noninteractive apt install -y \
  ubuntu-standard \
  ubuntu-server \
  apt-transport-https \
  ca-certificates \
  curl \
  git \
  gnupg-agent \
  libnss-libvirt \
  libvirt-clients \
  libvirt-daemon-system \
  net-tools \
  nmap \
  qemu-kvm \
  software-properties-common \
  telnet \
  tree \
  virtinst
sudo snap install lxd

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io
sudo curl -L "https://github.com/docker/compose/releases/download/1.25.5/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
sudo usermod -a -G docker $CFG_USERNAME

sudo apt dist-upgrade -y

sudo zfs snapshot rpool/ROOT/ubuntu_$CFG_ZFSID@fresh-install

echo "Installation complete. Delete /home/$CFG_USERNAME/finish-install.sh and reboot."
EOF
chmod a+x /mnt/home/$CFG_USERNAME/finish-install.sh
chown 1000:1000 /mnt/home/$CFG_USERNAME/finish-install.sh



# Clean up
# --------

umount -l /mnt/dev 2>/dev/null || true
umount -l /mnt/proc 2>/dev/null || true
umount -l /mnt/sys 2>/dev/null || true
umount -l /mnt 2>/dev/null || true
swapoff ${CFG_DISK}-part2 2>/dev/null || true
zpool export bpool
zpool export rpool


echo "Bootstrap complete. Please reboot, remove the installer medium, and then run /home/$CFG_USERNAME/finish-install.sh"
