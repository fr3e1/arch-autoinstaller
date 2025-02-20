# Arch Linux Autoinstaller

A simple and automated script to install Arch Linux with minimal user input. This autoinstaller streamlines the installation process while maintaining flexibility for customization.

NOT FINISHED, STILL TESTING, EXPECT BUGS 


## Features

- Automated partitioning and disk setup
- Base system installation with essential packages
- Configurable user creation and system settings
- Support for UEFI and BIOS systems
- Post-install customization options

## Prerequisites

- A bootable Arch Linux installation medium
- Internet connection
- A target drive for installation (all data on the target drive will be erased)

## Usage

1. Install git
   ``` bash
   pacman -Sy git
   ```
   2. Clone this repository and execute:
   ```bash
   git clone https://github.com/fr3e1/arch-autoinstaller.git
   cd arch-autoinstaller
   ./setup.sh
   ```
   3. Follow instructions provided

## Configuration

This script is designed to be as simple and straight-forward!

All you have to type:

   - the name of the drive
   - username and password
   - timezone
   
     That's it!

## Timezone

How to find your timezone:
``` bash
timedatectl list-timezones | grep "Country/Region"
```
Be sure to replace "Country/Region" accordingly!

## Disclaimer

This script is designed to automatically install arch linux AND automatically configure it with MY configs.
If you would like to make changes, please go ahead as my configs may be weird for new users, such as esc switched to caps lock 

I am not responsible for any data loss you encounter, so please backup your files!

