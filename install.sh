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

#COMING SOON
#if [ $(cat $(pwd)/config | md5sum) =  "0a87d0e640588122fb45273f4555610a  -" ]; then  
#    read -p "Config file untouched, would you like to edit and verify? [Y/n]" DEFAULT_CONFIRM
#    if [ $DEFAULT_CONFIRM -e [Yy][Ee][]Ss[] ]; then
#        nano $(pwd)/config
#    fi
#fi

# wiping drive
umount /dev/"$DRIVE"* 
wipefs -a /dev/"$DRIVE"
echo -e "label: gpt\nstart=2048,size=+100M\nsize=+" | sfdisk --wipe always /dev/"$DRIVE" 

# formatting drive partitions
yes y | mkfs.ext4 /dev/"$DRIVE"2 
yes y | mkfs.fat -F 32 /dev/"$DRIVE"1 
clear
## mount and pacstrap
mount /dev/"$DRIVE"2 /mnt 
mkdir -p /mnt/boot/efi 
mount /dev/"$DRIVE"1 /mnt/boot/efi 
# pacstrap
clear
if [ $AAARCH == "UEFI" ]; then
pacstrap /mnt $PACSTRAP $DISPLAYMANAGER $DESKTOPMANAGER efibootmgr
else
pacstrap /mnt $PACSTRAP $DISPLAYMANAGER $DESKTOPMANAGER 
fi
clear
## arch-chroot setup
arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/$ZONEINFO /etc/localtime 
hwclock --systohc
echo "$LOCALE" >> /etc/locale.gen  
locale-gen
echo "$HOSTNAME" > /etc/hostname 
echo "127.0.0.1 localhost" >> /etc/hosts 
systemctl enable NetworkManager $DISPLAYMANAGER 
grub-install /dev/$DRIVE 
grub-mkconfig -o /boot/grub/grub.cfg 
reboot 
EOF
reboot
