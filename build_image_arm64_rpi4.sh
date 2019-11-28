#!/bin/bash

# build your own Raspberry Pi SD card
#
# original by Klaus M Pfeiffer, http://www.kmp.or.at/~klaus/raspberry/build_rpi_sd_card.sh, 2012-06-24
# updated by Dovydas Stepanavicius for Jessie, https://github.com/dovydas/rpi-jessie, 2015-10-12
# updated by Sanjay Seshan for Stretch and Buster and rpi3b,3b+,4b - 2017-19

# you need at least
# apt-get install binfmt-support qemu qemu-user-static debootstrap kpartx lvm2 dosfstools

deb_mirror="http://ftp.debian.org/debian"

# Image size in Mb
imagesize="2000"
# Boot partition size
bootsize="128M"
deb_release="buster"
deb_arch="arm64"
scriptroot=$(pwd)
# Build root
buildenv=$(pwd)/build

# Additional scripts
scripts=$(pwd)/scripts

rootfs="${buildenv}/rootfs"
bootfs="${rootfs}/boot"

mydate=`date +%Y%m%d`

if [ $EUID -ne 0 ]; then
  echo "this tool must be run as root"
  exit 1
fi

# If $1 is block device
if [ -b $1 ]; then
  device=$1
else
  if [ "$1" == "" ]; then
    image="$(pwd)/rpi_basic_${deb_release}_${mydate}.img"
  else
    image=$1
    if [ -f $image ]; then
      read -p "The file ${image} already exists. Do you want to overwrite it? [y/N] " -n 1 -r
      if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
      fi
      rm -y $image
    fi
  fi
fi
    image="$(pwd)/rpi_debian_${deb_arch}_${deb_release}_${mydate}.img"

if [ "$device" == "" ]; then
  echo "Creating an image"
  mkdir -p $buildenv
  dd if=/dev/zero of=$image bs=1MB count=$imagesize
  device=`losetup -f --show $image`
  echo "image $image created and mounted as $device"
else
  dd if=/dev/zero of=$device bs=512 count=1
fi

fdisk $device << EOF
n
p
1

+$bootsize
t
c
n
p
2


w
EOF


if [ "$image" != "" ]; then
  losetup -d $device
  device=`kpartx -va $image | sed -E 's/.*(loop[0-9])p.*/\1/g' | head -1`
  device="/dev/mapper/${device}"
  bootp=${device}p1
  rootp=${device}p2
else
  if ! [ -b ${device}1 ]; then
    bootp=${device}p1
    rootp=${device}p2
    if ! [ -b ${bootp} ]; then
      echo "uh, oh, something went wrong, can't find bootpartition neither as ${device}1 nor as ${device}p1, exiting."
      exit 1
    fi
  else
    bootp=${device}1
    rootp=${device}2
  fi  
fi

# Let the kernel update partition mappings
sleep 2

if ! [ -b ${bootp} ];  then
  echo "${bootp} does not exist. Aborting"
  exit 1
fi

mkfs.vfat $bootp
mkfs.ext4 $rootp
mkdir -p $rootfs
mount $rootp $rootfs

cd $rootfs

echo "Bootstrapping the image"

debootstrap --foreign --arch $deb_arch $deb_release $rootfs $deb_mirror
cp /usr/bin/qemu-aarch64-static usr/bin/
LANG=C chroot $rootfs /debootstrap/debootstrap --second-stage

mount $bootp $bootfs

echo "deb $deb_mirror $deb_release main contrib non-free
" > etc/apt/sources.list
echo "deb http://sanjay.seshan.org/debian/ $deb_release main
" >> etc/apt/sources.list
echo "deb [trusted=yes] http://ppa.launchpad.net/ubuntu-pi-flavour-makers/ppa/ubuntu bionic main
" >> etc/apt/sources.list

echo "dwc_otg.lpm_enable=0 console=ttyAMA0,115200 kgdboc=ttyAMA0,115200 console=tty1 root=/dev/mmcblk0p2 rootfstype=ext4 rootwait" > boot/cmdline.txt

echo "/dev/mmcblk0p2  /		ext4    noatime        0       0
proc            /proc           proc    defaults        0       0
/dev/mmcblk0p1  /boot           vfat    defaults        0       0
" > etc/fstab

echo "raspberrypi" > etc/hostname

echo "auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
" > etc/network/interfaces

echo "vchiq
snd_bcm2835
" >> etc/modules

echo "console-common	console-data/keymap/policy	select	Select keymap from full list
console-common	console-data/keymap/full	select	de-latin1-nodeadkeys
" > debconf.set

cp -R ${scripts}/* .

mkdir -m 700 root/.ssh
cat $(scriptroot)/id_rsa.pub > root/.ssh/authorized_keys
chmod 600 root/.ssh/authorized_keys

echo "#!/bin/bash
debconf-set-selections /debconf.set
useradd -m -s /bin/bash pi
echo 'root:raspberry' | chpasswd
echo 'pi:raspberry' | chpasswd
rm -f /debconf.set
apt-get install -y wget gnupg2 binutils
wget -O - http://sanjay.seshan.org/debian/pirepo.gpg.key | apt-key add -
wget http://archive.raspberrypi.org/debian/raspberrypi.gpg.key
apt-key add raspberrypi.gpg.key
apt-get update 
apt-get download raspberrypi4-kernel
dpkg -x raspberrypi4-* /tmp/
rm raspberrypi4-*
mv /tmp/boot/* /boot
mv /tmp/lib/modules /lib/
apt-get -y --force-yes install sudo binutils ca-certificates wget curl libraspberrypi-* nano raspberrypi-firmware git gnupg2 pi-bluetooth
apt-get --force-yes -y install locales console-common ntp openssh-server less vim parted raspberrypi4-kernel
wget http://sanjay.seshan.org/debian/pool/main/r/raspi-config/raspi-config_20191116_all.deb
dpkg -i raspi-config_20191116_all.deb
echo 'pi  ALL=(ALL:ALL) ALL' >> /etc/sudoers
sed -i -e 's/KERNEL\!=\"eth\*|/KERNEL\!=\"/' /lib/udev/rules.d/75-persistent-net-generator.rules
rm -f /etc/udev/rules.d/70-persistent-net.rules
rm -f third-stage
" > third-stage
chmod +x third-stage

echo "Installing packages"
LANG=C chroot $rootfs /third-stage

echo "#!/bin/bash
apt-get -f install
apt-get clean
rm -f cleanup
service ntp stop
service ssh stop
systemctl enable rpi-firstrun.service
" > cleanup
chmod +x cleanup
LANG=C chroot $rootfs /cleanup

cd -

umount $bootp
umount $rootp

if [ "$image" != "" ]; then
  kpartx -d $image
  echo "created image $image"
fi


echo "done."

