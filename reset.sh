#!/bin/bash

echo "MAINLY USED FOR TESTING PURPOSES AND IS NOT MEANT TO BE USED FOR USERS"
read -p "continue? [y/N]" continue
case "$continue" in 
	[yY][eE][sS]|[yY])
		umount --lazy /mnt/boot
		umount --lazy /mnt/boot
		echo "done"
		;;
	*)
		echo "Exiting..."
		exit 1
		;;
esac

