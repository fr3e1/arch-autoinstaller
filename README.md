# Arch Linux Autoinstaller

A simple and automated script to install Arch Linux with minimal user input. This autoinstaller streamlines the installation process while maintaining flexibility for customization.

NOT FINISHED, STILL TESTING, EXPECT BUGS 


# Features

- Automated partitioning and disk setup
- Base system installation with essential packages
- Configurable user creation and system settings
- Support for UEFI and BIOS systems

### Future features:
- Post-install customization options
- proper nvme support
# Prerequisites

- A bootable Arch Linux installation medium
- Stable internet connection
- A clean target drive for installation (all data on the target drive will be wiped)

# Usage

1. Install git
   ``` bash
   pacman -Sy git
   ```
   2. Clone this repository and execute:
   ```bash
   git clone https://github.com/fr3e1/arch-autoinstaller.git
   cd arch-autoinstaller
   ./install.sh
   ```
   3. Follow further instructions

  ## Common issue:
  If you are getting errors when installing git, it may be caused by outdated rings.
  To mitigate, try these:
   ```bash
   pacman-key --init
   pacman-key --populate
   ```
   ```bash
   pacman -Sy archlinux-keyring
   ```
  
      

# Configuration
### CHECK OR EDIT THIS FILE BEFORE INSTALLING
Otherwise, you may not get the system you want!

Default configs:
```bash
TIMEZONE="UTC"
LOCALE="en_US.UTF-8 UTF-8"
USERNAME="user"
DISPLAYMANAGER="gdm"
DESKTOPMANAGER="hyprland"
```

# Timezone and Locale

How to find your timezone:
``` bash
timedatectl list-timezones | grep "Country/Region"
```
Be sure to replace "Country/Region" accordingly!

How to find your preferred locale:
```bash
nano /etc/locale.gen
```
You will most likely not need to do this as the default locale is 
what most people use

# Disclaimer
I am not responsible for any data loss you encounter, so please backup your files!
