#!/bin/bash

set -x

if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi


# Shares
SHARE_HOME=/share/home
NFS_DATA=/share/data

# User
HPC_USER=hpcuser
HPC_UID=7007
HPC_GROUP=hpc
HPC_GID=7007

MASTER_NAME=`hostname`



# Installs all required packages.
#
install_pkgs()
{
	yum -y install nfs-utils nfs-utils-lib
}



# Partitions all data disks attached to the VM 
#
setup_data_disks()
{
    mountPoint="$1"
    filesystem="$2"
    devices="$3"
    raidDevice="$4"
    createdPartitions=""

    # Loop through and partition disks until not found
    for disk in $devices; do
        fdisk -l /dev/$disk || break
        fdisk /dev/$disk << EOF
n
p
1


p
w
EOF
        createdPartitions="$createdPartitions /dev/${disk}1"
    done
    
    sleep 10

# Create RAID-0 volume
    if [ -n "$createdPartitions" ]; then
        devices=`echo $createdPartitions | wc -w`
        mdadm --create /dev/md10 --level 0 --raid-devices $devices $createdPartitions
        mkfs -t ext4 /dev/md10
        echo "/dev/md10 $mountPoint ext4 defaults,nofail 0 2" >> /etc/fstab
        mount /dev/md10
    fi

#	mkfs -t $filesystem $createdPartitions
#	echo "$createdPartitions $mountPoint $filesystem defaults,nofail 0 2" >> /etc/fstab
	
#	mount $createdPartitions
}

setup_disks()
{      
    # Dump the current disk config for debugging
    fdisk -l
    
    # Dump the scsi config
    lsscsi
    
    # Get the root/OS disk so we know which device it uses and can ignore it later
    rootDevice=`mount | grep "on / type" | awk '{print $1}' | sed 's/[0-9]//g'`
    
    # Get the TMP disk so we know which device and can ignore it later
    tmpDevice=`mount | grep "on /mnt/resource type" | awk '{print $1}' | sed 's/[0-9]//g'`

    # Get the data disk sizes from fdisk, we ignore the disks above
    dataDiskSize=`fdisk -l | grep '^Disk /dev/' | grep -v $rootDevice | grep -v $tmpDevice | awk '{print $3}' | sort -n -r | tail -1`

	# Compute number of disks
	nbDisks=`fdisk -l | grep '^Disk /dev/' | grep -v $rootDevice | grep -v $tmpDevice | wc -l`
	echo "nbDisks=$nbDisks"
	
	dataDevices="`fdisk -l | grep '^Disk /dev/' | grep $dataDiskSize | awk '{print $2}' | awk -F: '{print $1}' | sort | head -$nbDisks | tr '\n' ' ' | sed 's|/dev/||g'`"
    
    mkdir -p $SHARE_HOME
	mkdir -p $NFS_DATA
	setup_data_disks $NFS_DATA "xfs" "$dataDevices" "nfsdata"

    chown $HPC_USER:$HPC_GROUP $NFS_DATA
	
	echo "$NFS_DATA    *(rw,async)" >> /etc/exports

    echo "$SHARE_HOME  *(rw,async)" >> /etc/exports
    
    systemctl enable rpcbind || echo "Already enabled"
    systemctl enable nfs-server || echo "Already enabled"
    systemctl start rpcbind || echo "Already enabled"
    systemctl start nfs-server || echo "Already enabled"
	exportfs
	exportfs -a
	exportfs 
}


setup_user()
{
    # disable selinux
    sed -i 's/enforcing/disabled/g' /etc/selinux/config
    setenforce permissive
    
    groupadd -g $HPC_GID $HPC_GROUP
    
    # Don't require password for HPC user sudo
    echo "$HPC_USER ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
    
    # Disable tty requirement for sudo
    sed -i 's/^Defaults[ ]*requiretty/# Defaults requiretty/g' /etc/sudoers
   
	useradd -c "HPC User" -g $HPC_GROUP -m -d $SHARE_HOME/$HPC_USER -s /bin/bash -u $HPC_UID $HPC_USER

	mkdir -p $SHARE_HOME/$HPC_USER/.ssh

	# Configure public key auth for the HPC user
	ssh-keygen -t rsa -f $SHARE_HOME/$HPC_USER/.ssh/id_rsa -q -P ""
	cat $SHARE_HOME/$HPC_USER/.ssh/id_rsa.pub >> $SHARE_HOME/$HPC_USER/.ssh/authorized_keys

	echo "Host *" > $SHARE_HOME/$HPC_USER/.ssh/config
	echo "    StrictHostKeyChecking no" >> $SHARE_HOME/$HPC_USER/.ssh/config
	echo "    UserKnownHostsFile /dev/null" >> $SHARE_HOME/$HPC_USER/.ssh/config
	echo "    PasswordAuthentication no" >> $SHARE_HOME/$HPC_USER/.ssh/config

	# Fix .ssh folder ownership
	chown -R $HPC_USER:$HPC_GROUP $SHARE_HOME/$HPC_USER

	# Fix permissions
	chmod 700 $SHARE_HOME/$HPC_USER/.ssh
	chmod 644 $SHARE_HOME/$HPC_USER/.ssh/config
	chmod 644 $SHARE_HOME/$HPC_USER/.ssh/authorized_keys
	chmod 600 $SHARE_HOME/$HPC_USER/.ssh/id_rsa
	chmod 644 $SHARE_HOME/$HPC_USER/.ssh/id_rsa.pub
	
	chown $HPC_USER:$HPC_GROUP $NFS_DATA
}



install_pkgs
setup_disks
setup_user


exit 0


