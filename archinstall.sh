#/bin/bash
source $(pwd)/config.sh

## user requirements
echo "please pick a drive to install archlinux to:"
lsblk
echo
read -p "drive (example: sda, sdb, nvme0n1, etc.): " DRIVE

# drive validation 

if [[ ! -b "/dev/$DRIVE" ]]; then
    echo "Invalid drive specified. Exiting..."
    exit 1
fi

## partitioning
umount /dev/"$DRIVE"*
wipefs -a "$DRIVE"
echo -e "label: gpt\nstart=2048,size=+100M\nsize=+" | sfdisk --wipe always /dev/"$DRIVE" || echo "partitioning failed, exiting.."; exit 1
yes | mkfs.ext4 /dev/"$DRIVE"2 || echo "formatting failed, exiting.."; exit 1
mkfs.fat -F 32 /dev/"$DRIVE"1

## mount and pacstrap

mount /dev/"$DRIVE"2 /mnt
mkdir -p /mnt/boot/efi 
mount /dev/"$DRIVE"1 /mnt/boot/efi

pacstrap /mnt $PACSTRAP $DISPLAYMANAGER $DESKTOPMANAGER

## arch-chroot setup
arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/$ZONEINFO /etc/localtime
hwclock --systohc
echo "$LOCALE" >> /etc/locale.en
locale-gen
echo "$HOSTNAME" > /etc/hostname
echo "127.0.0.1 localhost" >> /etc/hosts
systemctl enable NetworkManager $DISPLAYMANAGER 
#grub-install /dev/$DRIVE
#grub-mkconfig -o /boot/grub/grub.cfg
#reboot
EOF
