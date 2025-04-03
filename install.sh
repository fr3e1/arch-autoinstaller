#/bin/bash
source "$(pwd)/config"
TMP_LOG="/tmp/script.log"
FINAL_LOG="/mnt/script/log/script.log"
MOUNT_POINT="/mnt/logs"

exec > >(tee -a "${TMP_LOG}") 2>&1


# root check
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi
clear
# arch check
 
if [ $AAARCH == "UEFI" ]; then
     echo "${GREEN}UEFI MODE"
else
    echo "${RED}BIOS MODE"
fi
echo
## user requirements
echo "please pick a drive to install archlinux to:"
echo
lsblk -d -o NAME,MODEL,SIZE,TRAN | grep -E '^(sd|nvme)'
echo
read -p "drive (example: sda, sdb, etc.): " DRIVE


# drive validation 

if [[ ! -b "/dev/$DRIVE" ]]; then
    echo "${RED}Invalid drive specified. Exiting..."
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
echo "${GREEN}WIPING DRIVE"
umount /dev/"$DRIVE"* 
wipefs -a /dev/"$DRIVE"
echo -e "label: gpt\nstart=2048,size=+100M\nsize=+" | sfdisk --wipe always /dev/"$DRIVE" 


# Determine partition suffix
if [[ "$DRIVE" == nvme* ]]; then
    PARTITION1="/dev/${DRIVE}p1"
    PARTITION2="/dev/${DRIVE}p2"
else
    PARTITION1="/dev/${DRIVE}1"
    PARTITION2="/dev/${DRIVE}2"
fi

# formatting drive partitions
echo "${GREEN}FORMATTING AND WIPING DRIVE"
yes y | mkfs.ext4 $PARTITION2 
yes y | mkfs.fat -F 32 $PARTITION1 
clear

# mount and pacstrap
echo "${GREEN}MOUNTING DRIVE PARTITIONS"
mount $PARTITION2 /mnt 
mkdir -p /mnt/boot/efi 
mount $PARTITION1 /mnt/boot/efi 
mkdir -p /mnt/logs
cat "$TMP_LOG" >> "$FINAL_LOG"
exec > >(tee -a "$FINAL_LOG") 2>&1
echo "${GREEN}Logging moved to $FINAL_LOG"


# pacstrap
echo "${GREEN}INITIATING PACSTRAP"
sudo sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 9999/' /etc/pacman.conf

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
echo "${GREEN}GENERATING FSTAB:"
echo "${GREEN}$(genfstab -U /mnt)" 
genfstab -U /mnt > /mnt/etc/fstab
echo "${GREEN}INITIATING FSTAB SETUPS"
arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/$ZONEINFO /etc/localtime 
pacman -Syu --noconfirm $DISPLAYMANAGER $DESKTOPMANAGER
hwclock --systohc
echo "$LOCALE" >> /etc/locale.gen  
locale-gen
echo "$HOSTNAME" > /etc/hostname 
echo "127.0.0.1 localhost" >> /etc/hosts 
systemctl enable NetworkManager $DISPLAYMANAGER

# Install GRUB bootloader
if [[ "$DRIVE" == nvme* ]]; then
    grub-install --target=x86_64-efi --efi-directory=/mnt/boot/efi --bootloader-id=GRUB --recheck /dev/"$DRIVE"
else
    grub-install --target=i386-pc /dev/"$DRIVE"
fi

# Generate GRUB configuration
grub-mkconfig -o /boot/grub/grub.cfg
useradd -m -G wheel,users,video,audio -s /bin/bash $USERNAME
echo ""$USERNAME":"$password"" | chpasswd

sed -i 's/^# \(%wheel ALL=(ALL:ALL) ALL\)$/\1/' /etc/sudoers
visudo -c 
EOF
echo "${GREEN}INTSALLATION FINISHED, LOG COPIES CAN BE FOUND AT:"
echo "${TMP_LOG}"
echo "${FINAL_LOG}"

echo "System will reboot in 10 seconds. Press any key to cancel..."

read -n 1 -t 10 input && echo "Reboot canceled." || reboot
