# Arch Linux Autoinstaller

A simple and automated script to install Arch Linux with minimal user input. This autoinstaller streamlines the installation process while maintaining flexibility for customization.

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

1. Boot to your archlinux ISO
   
3. Clone this repository:
   ```bash
   git clone https://github.com/fr3e1/arch-autoinstaller.git
   cd arch-autoinstaller
   ./setup.sh
