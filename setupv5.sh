#!/bin/bash

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

# User input for drive, username, password, and timezone
read -p "Drive to install Arch on (sdX): " drive
read -p "Username: " username
read -sp "Password: " password
echo
read -sp "Retype Password: " validating
echo
read -p "Timezone (Region/City): " timezone

# Verify passwords match
if [[ "$password" != "$validating" ]]; then
    echo "Passwords do not match. Exiting..."
    exit 1
fi

# Check if the specified drive exists
if ls /dev | grep -q "$drive"; then
    echo "The drive exists. Continuing..."
else
    echo "The specified drive does not exist. Exiting..."
    exit 1
fi

# Unmount any partitions on the drive
echo "Unmounting partitions on $drive..."
for PART in $(lsblk -lnp | grep "^/dev/$drive" | awk '{print $1}'); do
    umount "$PART" 2>/dev/null && echo "Unmounted $PART" || echo "$PART not mounted"
done

# Launch cfdisk for partitioning and create default layout without user input
parted -s "/dev/$drive" mklabel gpt
parted -s "/dev/$drive" mkpart primary fat32 1MiB 512MiB
parted -s "/dev/$drive" set 1 esp on
parted -s "/dev/$drive" mkpart primary ext4 512MiB 100%

# Format the partitions
echo "Formatting partitions..."
mkfs.fat -F32 "/dev/${drive}1" || { echo "Failed to format /dev/${drive}1"; exit 1; }
mkfs.ext4 "/dev/${drive}2" || { echo "Failed to format /dev/${drive}2"; exit 1; }

echo "Partitioning and formatting complete."

# Mount the partitions
mount "/dev/${drive}2" /mnt || { echo "Failed to mount /dev/${drive}2"; exit 1; }
mkdir /mnt/boot
mount "/dev/${drive}1" /mnt/boot || { echo "Failed to mount /dev/${drive}1"; exit 1; }

# Install base system
pacman-key --init
pacman-key --populate archlinux
pacstrap /mnt base linux linux-firmware base-devel grub networkmanager zsh git sudo || {
    echo "Failed to install base system. Exiting..."
    exit 1
}

# Temporarily disable sudo password for wheel group
sed -i 's/^# \(%wheel ALL=(ALL:ALL) NOPASSWD: ALL\)/\1/' /mnt/etc/sudoers

# Prepare for chroot setup
mkdir -p /mnt/tmp/mrdot
cp -r dotfiles/* /mnt/tmp/mrdot || { echo "Failed to copy dotfiles"; exit 1; }

echo "${username}:${password}" > /mnt/tmp/temporary

# Write chroot setup script
cat << EOF > /mnt/setup-chroot.sh
#!/bin/bash

# Set timezone and locale
ln -sf "/usr/share/zoneinfo/$timezone" /etc/localtime
hwclock --systohc

echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "myhostname" > /etc/hostname
locale-gen

# Create user, set password, and add to wheel group
useradd -m -G wheel -s /bin/bash "$username"
echo "$username:$password" | chpasswd

# Ensure the wheel group has sudo access
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Install and configure GRUB
grub-install "/dev/$drive"
grub-mkconfig -o /boot/grub/grub.cfg

# Install additional packages
pacman -Sy --noconfirm waybar pulseaudio gdm btop nautilus kitty fastfetch

git clone https://aur.archlinux.org/yay.git /tmp/yay
chown -R "$username:$username" /tmp/yay
sudo -u "$username" bash -c 'cd /tmp/yay && makepkg -si --noconfirm'

sudo -u "$username" yay -Sy --noconfirm hyprland-bin

# Enable services
systemctl enable gdm NetworkManager

# Copy configuration files
cp -r /tmp/mrdot/* /home/"$username"/.config/
chown -R "$username:$username" /home/"$username"/.config/

# Restore sudo password requirement for wheel group
sed -i 's/^\(%wheel ALL=(ALL:ALL) NOPASSWD: ALL\)/# \1/' /etc/sudoers
EOF

chmod +x /mnt/setup-chroot.sh

cat << EOF > /mnt/etc/systemd/system/setup.service
[Unit]
Description=Used by the auto install script to do post install setups without having to chroot
After=network.target

[Service]
ExecStart= /setup-chroot.sh
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

arch-chroot /mnt /setup-chroot.sh

# Final unmount for main partitions
umount -R /mnt || echo "Failed to unmount /mnt"

# Cleanup
echo "Arch Linux Is installed. Rebooting in 5 seconds for post setups..."
sleep 5
reboot

