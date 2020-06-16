#!/bin/bash

#
# update accutennis disk image v3 to v4. 
# inspired by https://github.com/mrpjevans/raspbian_restore/blob/master/create_raspbian_restore
# before running this script, upload tenniscam_boot_v4.tar.gz and tenniscam_main_v4.gz to /home/pi/tenniscam/recovery_images


# You need to be root to do this
if [ "$EUID" -ne 0 ]
  then echo "Please run as root or sudo"
  exit
fi

currentMount=$(mount|grep ' / '|cut -d' ' -f 1)
echo "Currently booted to $currentMount"
if [[ $currentMount == *"mmcblk0p3"* ]]
    then
    echo "Can't upgrade partition 3 while running from partition 3. Exiting."
    exit
fi

# Check existing partitions

fdiskOut=$(fdisk -l /dev/mmcblk0)

partitionCount=0
if [[ $fdiskOut == *"mmcblk0p1"* && $fdiskOut == *"mmcblk0p2"* && $fdiskOut != *"mmcblk0p3"* ]]
then 
	echo "Two partitions found."
	partitionCount=2
elif [[ $fdiskOut == *"mmcblk0p1"* && $fdiskOut == *"mmcblk0p2"* && $fdiskOut == *"mmcblk0p3"* ]]
then
	echo "Three partitions found."
	partitionCount=3
else
	echo "Unknown disk partition configuration.  Exiting."
	exit
fi

# get the disk identifier (UUID)
diskIDRegex='Disk identifier:[[:blank:]]+0x(\w+)'
if [[ $fdiskOut =~ $diskIDRegex ]]
then
	diskUUID=${BASH_REMATCH[1]}
	echo "Found disk identifier: $diskUUID"
else
	echo "Unable to find disk identifier. Exiting."
	exit
fi

p2LastBlockExpected=30318591
lastBlockRegex='mmcblk0p2[ \t]+[0-9]+[ \t]+([0-9]+)'
if (( partitionCount==2 ))
then
	#verify the last block of partition 2
	[[ $fdiskOut =~ $lastBlockRegex ]]
	p2LastBlock=${BASH_REMATCH[1]}
	echo "Partition 2 End: $p2LastBlock"
	if [[ $p2LastBlock != $p2LastBlockExpected ]]
	then
		echo "Expected $p2LastBlockExpected.  Exiting."
		exit
	fi
	echo "Creating new partition."
fdisk /dev/mmcblk0 <<EOF
n
p
3
$((p2LastBlock+1))

w
EOF
partprobe
fi

#image files
tenniscam_main_v4=/home/pi/recovery_images/tenniscam_main_v4.gz
tenniscam_boot_v4=/home/pi/recovery_images/tenniscam_boot_v4.tar.gz
if [[ ! -f "$tenniscam_main_v4" ]]
then
    echo "Missing file $tenniscam_main_v4.  Exiting."
    exit
fi

if [[ ! -f "$tenniscam_boot_v4" ]]
then
    echo "Missing file $tenniscam_boot_v4. Exiting."
    exit
fi

#create mount point
mkdir -p /mnt/p3

#enter any command line parameter to bypass the big image copy for testing purposes.
if [[ "$1" == "" ]]
then
    umount /dev/mmcblk0p3
    #unzip the partition image to the new partition.  this takes a while.
    echo "Updating the new image.  This takes several minutes."
    gzip -dc $tenniscam_main_v4 > /dev/mmcblk0p3 
    #expand the filesystem
    echo "Checking and resizing the filesystem."
    e2fsck -f -y /dev/mmcblk0p3
    resize2fs /dev/mmcblk0p3
    e2fsck -f -y /dev/mmcblk0p3
fi

echo "Mounting partition 3."
mount /dev/mmcblk0p3 /mnt/p3
mkdir -p /mnt/p3/mnt/p2

#update fstab files
echo "Updating /etc/fstab on both partitions to mount the partitions on boot."
cat << EOF > /etc/fstab
proc                     /proc           proc    defaults          0       0
PARTUUID=${diskUUID}-01  /boot           vfat    defaults          0       2
PARTUUID=${diskUUID}-02  /               ext4    defaults,noatime  0       1
PARTUUID=${diskUUID}-03  /mnt/p3         ext4    defaults,noatime  0       2
EOF

cat << EOF > /mnt/p3/etc/fstab
proc                     /proc           proc    defaults          0       0
PARTUUID=${diskUUID}-01  /boot           vfat    defaults          0       2
PARTUUID=${diskUUID}-02  /mnt/p2         ext4    defaults,noatime  0       2
PARTUUID=${diskUUID}-03  /               ext4    defaults,noatime  0       1
EOF

#update bootloader
if [[ "$1" == "" ]]
    then
    echo "Updating bootloader files in /boot"
    sudo tar -xvzf $tenniscam_boot_v4 -C /
fi

#point bootloader to the new partition
echo "updating /boot/cmdline.txt to boot to partition 3."
sed -i "s/root=PARTUUID=[^[:space:]]*/root=PARTUUID=${diskUUID}-03/" /boot/cmdline.txt

#update ip address
echo "Synching ip address between partitions."
ipAddr=$(grep "^static ip_address=" /etc/dhcpcd.conf)
sed -i "s|^static ip_address=.*|${ipAddr}|" /mnt/p3/etc/dhcpcd.conf

echo "Done.  Reboot to run on partition 3."

exit 0

