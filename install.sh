#/bin/bash
source "$(pwd)/config"

# root check
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi
clear
# arch check
 
if [ $AAARCH == "UEFI" ]; then
     echo "UEFI MODE"
else
    echo "BIOS MODE"
fi
echo
## user requirements
echo "please pick a drive to install archlinux to:"
echo
lsblk
echo
read -p "drive (example: sda, sdb, nvme0n1, etc.): " DRIVE


# drive validation 

if [[ ! -b "/dev/$DRIVE" ]]; then
    echo "Invalid drive specified. Exiting..."
    exit 1
fi

if [ $(cat $(pwd)/config | md5sum) =  "0a87d0e640588122fb45273f4555610a  -" ]; then  
    read -p "Config file untouched, would you like to edit and verify? [Y/n]" DEFAULT_CONFIRM
    if [ $DEFAULT_CONFIRM -e [Yy][Ee][]Ss[] ]; then
        nano $(pwd)/config
    fi
fi

# wiping drive
umount /dev/"$DRIVE"* 
wipefs -a "$DRIVE" || echo "Failed to wipe drive, exiting.."; exit 1
echo -e "label: gpt\nstart=2048,size=+100M\nsize=+" | sfdisk --wipe always /dev/"$DRIVE" || echo "partitioning failed, exiting.."

# formatting drive partitions
yes | mkfs.ext4 /dev/"$DRIVE"2 || echo "formatting failed, exiting.."; exit 1
mkfs.fat -F 32 /dev/"$DRIVE"1 || echo "Formatting failed, exiting..";  exit 1

echo "Failed to mount drive, exiting.."; exit 1
## mount and pacstrap
mount /dev/"$DRIVE"2 /mnt || echo "Failed to mount drive, exiting.."; exit 1
mkdir -p /mnt/boot/efi 
mount /dev/"$DRIVE"1 /mnt/boot/efi || echo "Failed to mount drive, exiting.."; exit 1

# pacstrap
if [ $AAARCH == "UEFI" ]; then
pacstrap /mnt $PACSTRAP $DISPLAYMANAGER $DESKTOPMANAGER efibootmgr
else
pacstrap /mnt $PACSTRAP $DISPLAYMANAGER $DESKTOPMANAGER 
fi

## arch-chroot setup
arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/$ZONEINFO /etc/localtime || echo "Failed to make symlink for localtime"
hwclock --systohc || echo "Failed to run hwclock"
echo "$LOCALE" >> /etc/locale.gen || echo "Failed to edit locale" 
locale-gen || echo "Failed to generate locale"
echo "$HOSTNAME" > /etc/hostname || echo "Failed to set hostname"
echo "127.0.0.1 localhost" >> /etc/hosts || echo "Failed to set hosts"
systemctl enable NetworkManager $DISPLAYMANAGER || echo "Failed to enable services"
grub-install /dev/$DRIVE || echo "Failed to install Grub"
grub-mkconfig -o /boot/grub/grub.cfg || echo "Failed to generate grub config"
reboot || echo "Failed to reboot"
EOF
