#!/bin/bash

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

# replacing pacman conf

rm /etc/pacman.conf
cp pacman.conf /etc/pacman.conf

# User input for drive, username, password, and timezone
read -p "Drive to install Arch on (e.g., sda, nvme0n1): " drive
read -p "Hostname: " hostname
read -p "Username: " username
read -sp "Password: " password
echo
read -sp "Retype Password: " validating
echo
read -p "Timezone (Region/City): " timezone
read -p "Install nvidia drivers (y/N): " nvidia

# Verify passwords match
if [[ "$password" != "$validating" ]]; then
    echo "Passwords do not match. Exiting..."
    exit 1
fi
# Editing preset for nvidia driver

case "$nvidia" in 
	[yY][eE][sS]|[yY]) 

		sed -i '16s/.*/nvidia="Y"/' preset.sh
# Validate the drive
if [[ ! -b "/dev/$drive" ]]; then
    echo "Invalid drive specified. Exiting..."
    exit 1
fi

# Validate the timezone
if [[ ! -f "/usr/share/zoneinfo/$timezone" ]]; then
    echo "Invalid timezone specified. Exiting..."
    exit 1
fi

# Check system architecture
arch=$(uname -m)
if [[ "$arch" != "x86_64" && "$arch" != "i686" ]]; then
    echo "Unsupported architecture: $arch. Exiting..."
    exit 1
fi

# Unmount any partitions on the drive
for PART in $(lsblk -lnp | grep "^/dev/$drive" | awk '{print $1}'); do
    umount "$PART" 2>/dev/null && echo "Unmounted $PART" || echo "$PART not mounted"
    wipefs -a "$PART"
done

# Partition the drive
parted -s "/dev/$drive" mklabel gpt
parted -s "/dev/$drive" mkpart primary fat32 1MiB 512MiB
parted -s "/dev/$drive" set 1 esp on
parted -s "/dev/$drive" mkpart primary ext4 512MiB 100%

# Format the partitions
mkfs.fat -F32 "/dev/${drive}1" || { echo "Failed to format /dev/${drive}1"; exit 1; }
mkfs.ext4 "/dev/${drive}2" || { echo "Failed to format /dev/${drive}2"; exit 1; }

# Mount the partitions
mount "/dev/${drive}2" /mnt || { echo "Failed to mount /dev/${drive}2"; exit 1; }
mkdir /mnt/boot
mount "/dev/${drive}1" /mnt/boot || { echo "Failed to mount /dev/${drive}1"; exit 1; }

# Install the base system
pacstrap /mnt base linux linux-firmware base-devel efibootmgr grub networkmanager zsh git sudo gdm hyprland kitty firefox || {
    echo "Failed to install base system. Exiting..."
    exit 1
}

# Generating fstab

genfstab /mnt > /mnt/etc/fstab

# Configure the system in chroot
arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/$timezone /etc/localtime
hwclock --systohc

echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "$hostname" > /etc/hostname
echo "127.0.0.1 localhost" >> /etc/hosts
echo "::1 localhost" >> /etc/hosts
echo "127.0.1.1 $username-pc.localdomain $username-pc" >> /etc/hosts

locale-gen

useradd -m -G wheel -s /bin/bash "$username"
echo "$username:$password" | chpasswd

sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers

# Install and configure GRUB
grub-install --efi-directory=/boot
if [[ $? -ne 0 ]]; then
    echo "Failed to install GRUB. Exiting..."
    exit 1
fi

grub-mkconfig -o /boot/grub/grub.cfg

# Installing dots

su - $username -c "./Arch-Hyprland/install.sh

# Enable essential services
systemctl enable NetworkManager
systemctl enable gdm
EOF


# Post-install setup

git clone --depth=1 https://github.com/JaKooLit/Arch-Hyprland.git /mnt/home/$username/Arch-Hyprland

git clone https://github.com/sejjy/mechabar.git /mnt/home/$username/mechabar

rm /mnt/home/$username/Arch-hyprland/preset.sh
cp preset.sh /mnt/home/$username/Arch-Hyprland/preset.sh

arch-chroot /mnt /bin/bash <<EOF
pacman -Sy bluez-utils brightnessctl hyprlock pipewire pipewire-pulse python ttf-jetbrains-mono-nerd wireplumber --noconfirm

su - $username -c "yes | sh ~/Arch-Hyprland/install.sh"
su - $username -c "yay -S bluetui rofi-lbonn-wayland-git"
su - $username -c "sh ~/mechabar/install.sh'


sed -i 's/^# %wheel ALL=(ALL:ALL) NOPASSWD: ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

EOF

# Final unmount for main partitions
umount -R /mnt || echo "Failed to unmount /mnt"

# Cleanup
echo "Arch Linux is installed. Rebooting in 5 seconds..."



