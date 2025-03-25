#/bin/bash
source "$(pwd)/config"
exec > >(tee -a script.log) 2>&1

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
read -p "drive (example: sda, sdb, etc.): " DRIVE


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
read -p "Enter Username: " USERNAME
echo "Username: $USERNAME"
while true; do
	read -s -p "Enter Password: " password
	echo 
	read -s -p "Confirm Password: " passwordver
	echo 

	if [ "$password" == "$passwordver" ]; then
		break
	else
		echo "Passwords do not match, please try again"
	fi
done



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
	pacstrap /mnt $PACSTRAP efibootmgr
else
	pacstrap /mnt $PACSTRAP  
fi


missing_pkgs=$(pacman -Q $(<pacstrap) 2>&1 | awk -F"'" '/error: package/ {print $2}')
[[ -n "$missing_pkgs" ]]

arch-chroot /mnt /bin/bash -c "pacman -Sy --noconfirm $missing_pkgs"

#post-install setup
####DONT MESS WITH THE SED COMMAND####

genfstab /mnt > /mnt/etc/fstab
arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/$ZONEINFO /etc/localtime 
pacman -Syu --noconfirm $DISPLAYMANAGER $DESKTOPMANAGER
hwclock --systohc
echo "$LOCALE" >> /etc/locale.gen  
locale-gen
echo "$HOSTNAME" > /etc/hostname 
echo "127.0.0.1 localhost" >> /etc/hosts 
systemctl enable NetworkManager $DISPLAYMANAGER 
grub-install /dev/$DRIVE 
grub-mkconfig -o /boot/grub/grub.cfg

useradd -m -G wheel,users,video,audio -s /bin/bash $USERNAME
echo ""$USERNAME":"$password"" | chpasswd

sed -i 's/^# \(%wheel ALL=(ALL:ALL) ALL\)$/\1/' /etc/sudoers
visudo -c 
EOF

echo "Installation finished. System will automatically reboot"
echo "in 10 seconds if left undisturbed."
