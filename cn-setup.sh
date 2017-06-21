#!/bin/bash

set -x
#set -xeuo pipefail

if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi

if [ $# -lt 7 ] || [ $# -gt 8 ]; then
    echo "Usage: $0 <MasterHostname> <WorkerHostnamePrefix> <WorkerNodeCount> <HPCUserName> <TemplateBaseUrl> <ClusterFilesystem> <BeeGFSStoragePath> <OptionalCustomScriptUrl>"
    exit 1
fi

# Set user args
MASTER_HOSTNAME=$1
WORKER_HOSTNAME_PREFIX=$2
WORKER_COUNT=$3
TEMPLATE_BASE_URL="$5"
CLUSTERFS="$6"
CLUSTERFS_STORAGE="$7"
CUSTOM_SCRIPT_URL="$8"
LAST_WORKER_INDEX=$(($WORKER_COUNT - 1))

# Default to local disk
CLUSTERFS_STORAGE_PATH="/mnt/resource/storage"
if [ "$CLUSTERFS_STORAGE" == "Storage" ]; then
    CLUSTERFS_STORAGE_PATH="/data/beegfs/storage"
fi

# Shares
SHARE_ROOT=/share
SHARE_HOME=$SHARE_ROOT/home
SHARE_DATA=$SHARE_ROOT/data
SHARE_SCRATCH=$SHARE_ROOT/scratch
CLUSTERFS_METADATA_PATH=/data/beegfs/meta

# Munged
MUNGE_USER=munge
MUNGE_GROUP=munge
MUNGE_VERSION=0.5.11

# SLURM
SLURM_USER=slurm
SLURM_UID=6006
SLURM_GROUP=slurm
SLURM_GID=6006
SLURM_VERSION=15-08-1-1
SLURM_CONF_DIR=$SHARE_DATA/conf

# Hpc User
HPC_USER=$4
HPC_UID=7007
HPC_GROUP=hpc
HPC_GID=7007


# Returns 0 if this node is the master node.
#
is_master()
{
    hostname | grep "$MASTER_HOSTNAME"
    return $?
}


# Installs all required packages.
#
install_pkgs()
{
    if [ -d "/opt/intel/impi" ]; then
        # We're on the CentOS HPC image and need to freeze the kernel version
        sed -i 's/^exclude=kernel\*$/#exclude=kernel\*/g' /etc/yum.conf
    fi

    yum -y install epel-release
    yum -y install zlib zlib-devel bzip2 bzip2-devel bzip2-libs openssl \
            openssl-devel openssl-libs gcc gcc-c++ nfs-utils rpcbind mdadm \
            wget python-pip kernel kernel-devel openmpi openmpi-devel automake \
            autoconf munge munge-libs munge-devel rng-tools
}

# Partitions all data disks attached to the VM and creates
# a RAID-0 volume with them.
#
setup_data_disks()
{
    mountPoint="$1"
    filesystem="$2"
    createdPartitions=""

    # Loop through and partition disks until not found
    for disk in sdc sdd sde sdf sdg sdh sdi sdj sdk sdl sdm sdn sdo sdp sdq sdr; do
        fdisk -l /dev/$disk || break
        fdisk /dev/$disk << EOF
n
p
1


t
fd
w
EOF
        createdPartitions="$createdPartitions /dev/${disk}1"
    done

    # Create RAID-0 volume
    if [ -n "$createdPartitions" ]; then
        devices=`echo $createdPartitions | wc -w`
        mdadm --create /dev/md10 --level 0 --raid-devices $devices $createdPartitions
        if [ "$filesystem" == "xfs" ]; then
            mkfs -t $filesystem /dev/md10
            echo "/dev/md10 $mountPoint $filesystem rw,noatime,attr2,inode64,nobarrier,sunit=1024,swidth=4096,nofail 0 2" >> /etc/fstab
        else
            mkfs -t $filesystem /dev/md10
            echo "/dev/md10 $mountPoint $filesystem defaults,nofail 0 2" >> /etc/fstab
        fi
        mount /dev/md10
    fi
}

wait_for_master_nfs()
{
    while true; do
        showmount -e master | grep '^/share/home'
        if [ $? -eq 0 ]; then
            break;
        fi
        sleep 15
    done
}

wait_for_file()
{
    file=$1
    while true; do
        if [ -e "$file" ]; then
            break
        fi
        sleep 15
    done
}

# Creates and exports two shares on the master nodes:
#
# /share/home (for HPC user)
# /share/data
#
# These shares are mounted on all worker nodes.
#
setup_shares()
{
    if is_master; then
        if [ "$CLUSTERFS" == "BeeGFS" ]; then
            mkdir -p $CLUSTERFS_METADATA_PATH
            setup_data_disks $CLUSTERFS_METADATA_PATH "ext4"
            echo "$SHARE_HOME    *(rw,async)" >> /etc/exports
            echo "$SHARE_DATA    *(rw,async)" >> /etc/exports
        else
            mkdir -p $SHARE_ROOT
            setup_data_disks $SHARE_ROOT "ext4"
            echo "$SHARE_HOME    *(rw,async)" >> /etc/exports
            echo "$SHARE_DATA    *(rw,async)" >> /etc/exports
            echo "$SHARE_SCRATCH    *(rw,async)" >> /etc/exports
        fi

        mkdir -p $SHARE_HOME
        mkdir -p $SHARE_DATA
        mkdir -p $SHARE_SCRATCH

        systemctl enable rpcbind || echo "Already enabled"
        systemctl enable nfs-server || echo "Already enabled"
        systemctl start rpcbind || echo "Already enabled"
        systemctl start nfs-server || echo "Already enabled"
    else
        wait_for_master_nfs

        mkdir -p $SHARE_HOME
        mkdir -p $SHARE_DATA
        mkdir -p $SHARE_SCRATCH

        echo "master:$SHARE_HOME $SHARE_HOME    nfs4    rw,auto,_netdev 0 0" >> /etc/fstab
        echo "master:$SHARE_DATA $SHARE_DATA    nfs4    rw,auto,_netdev 0 0" >> /etc/fstab

        if [ "$CLUSTERFS" == "None" ]; then
            echo "master:$SHARE_SCRATCH $SHARE_SCRATCH    nfs4    rw,auto,_netdev 0 0" >> /etc/fstab
        fi

        mkdir -p $CLUSTERFS_STORAGE_PATH
        setup_data_disks $CLUSTERFS_STORAGE_PATH "xfs"

        mount -a
        mount | grep "^master:$SHARE_HOME"
        mount | grep "^master:$SHARE_DATA"

        if [ "$CLUSTERFS" == "None" ]; then
            mount | grep "^master:$SHARE_SCRATCH"
        fi
    fi
}

# Downloads/builds/installs munged on the node.
# The munge key is generated on the master node and placed
# in the data share.
# Worker nodes copy the existing key from the data share.
#
install_munge()
{
    if is_master; then
        dd if=/dev/urandom bs=1 count=1024 > /etc/munge/munge.key
        mkdir -p $SLURM_CONF_DIR
        cp /etc/munge/munge.key $SLURM_CONF_DIR
    else
        wait_for_file $SLURM_CONF_DIR/munge.key
        cp $SLURM_CONF_DIR/munge.key /etc/munge/munge.key
    fi

    chown -R munge: /etc/munge/ /var/log/munge/
    chmod 0700 /etc/munge/ /var/log/munge/

    chown munge: /etc/munge/munge.key
    chmod 0400 /etc/munge/munge.key

    systemctl enable munge
    systemctl start munge

    cd $cwd
}

# Installs and configures slurm.conf on the node.
# This is generated on the master node and placed in the data
# share.  All nodes create a sym link to the SLURM conf
# as all SLURM nodes must share a common config file.
#
install_slurm_config()
{
    if is_master; then

        mkdir -p $SLURM_CONF_DIR

        if [ -e "$TEMPLATE_BASE_URL/slurm.template.conf" ]; then
            cp "$TEMPLATE_BASE_URL/slurm.template.conf" .
        else
            wget "$TEMPLATE_BASE_URL/slurm.template.conf"
        fi

        cpuCount="`nproc`"

        cat slurm.template.conf |
        sed 's/__MASTER__/'"$MASTER_HOSTNAME"'/g' |
                sed 's/__WORKER_HOSTNAME_PREFIX__/'"$WORKER_HOSTNAME_PREFIX"'/g' |
                sed 's/__LAST_WORKER_INDEX__/'"$LAST_WORKER_INDEX"'/g' |
                sed 's/__CPU_COUNT__/'"$cpuCount"'/g' > $SLURM_CONF_DIR/slurm.conf

    else
        wait_for_file $SLURM_CONF_DIR/slurm.conf
    fi

    ln -s $SLURM_CONF_DIR/slurm.conf /etc/slurm/slurm.conf
}

# Downloads, builds and installs SLURM on the node.
# Starts the SLURM control daemon on the master node and
# the agent on worker nodes.
#
install_slurm()
{
    groupadd -g $SLURM_GID $SLURM_GROUP

    useradd -M -u $SLURM_UID -c "SLURM service account" -g $SLURM_GROUP -s /usr/sbin/nologin $SLURM_USER

    mkdir -p /etc/slurm /var/spool/slurmd /var/run/slurmd /var/run/slurmctld /var/log/slurmd /var/log/slurmctld

    chown -R slurm:slurm /var/spool/slurmd /var/run/slurmd /var/run/slurmctld /var/log/slurmd /var/log/slurmctld

    wget https://github.com/SchedMD/slurm/archive/slurm-$SLURM_VERSION.tar.gz
    tar xvfz slurm-$SLURM_VERSION.tar.gz
    cd slurm-slurm-$SLURM_VERSION
    ./configure -libdir=/usr/lib64 --prefix=/usr --sysconfdir=/etc/slurm && make && make install

    install_slurm_config

    if is_master; then
        wget $TEMPLATE_BASE_URL/slurmctld.service
        mv slurmctld.service /usr/lib/systemd/system
        systemctl daemon-reload
        systemctl enable slurmctld
        systemctl start slurmctld
    else
        wget $TEMPLATE_BASE_URL/slurmd.service
        mv slurmd.service /usr/lib/systemd/system
        systemctl daemon-reload
        systemctl enable slurmd
        systemctl start slurmd
    fi
}

# Adds a common HPC user to the node and configures public key SSh auth.
# The HPC user has a shared home directory (NFS share on master) and access
# to the data share.
#
setup_hpc_user()
{
    # disable selinux
    sed -i 's/enforcing/disabled/g' /etc/selinux/config
    setenforce permissive

    groupadd -g $HPC_GID $HPC_GROUP

    # Don't require password for HPC user sudo
    echo "$HPC_USER ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

    # Disable tty requirement for sudo
    sed -i 's/^Defaults[ ]*requiretty/# Defaults requiretty/g' /etc/sudoers

    if is_master; then

        useradd -c "HPC User" -g $HPC_GROUP -m -d $SHARE_HOME/$HPC_USER -s /bin/bash -u $HPC_UID $HPC_USER

        mkdir -p $SHARE_HOME/$HPC_USER/.ssh

        # Configure public key auth for the HPC user
        ssh-keygen -t rsa -f $SHARE_HOME/$HPC_USER/.ssh/id_rsa -q -P ""
        cat $SHARE_HOME/$HPC_USER/.ssh/id_rsa.pub > $SHARE_HOME/$HPC_USER/.ssh/authorized_keys

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

        # Give hpc user access to data share
        chown $HPC_USER:$HPC_GROUP $SHARE_DATA
    else
        useradd -c "HPC User" -g $HPC_GROUP -d $SHARE_HOME/$HPC_USER -s /bin/bash -u $HPC_UID $HPC_USER
    fi

    chown $HPC_USER:$HPC_GROUP $SHARE_SCRATCH
}

# Sets all common environment variables and system parameters.
#
setup_env()
{
    # Set unlimited mem lock
    echo "$HPC_USER hard memlock unlimited" >> /etc/security/limits.conf
    echo "$HPC_USER soft memlock unlimited" >> /etc/security/limits.conf

    # Intel MPI config for IB
    echo "# IB Config for MPI" > /etc/profile.d/mpi.sh
    echo "export I_MPI_FABRICS=shm:dapl" >> /etc/profile.d/mpi.sh
    echo "export I_MPI_DAPL_PROVIDER=ofa-v2-ib0" >> /etc/profile.d/mpi.sh
    echo "export I_MPI_DYNAMIC_CONNECTION=0" >> /etc/profile.d/mpi.sh
}

install_beegfs()
{
    wget -O beegfs-rhel7.repo http://www.beegfs.com/release/latest-stable/dists/beegfs-rhel7.repo
    mv beegfs-rhel7.repo /etc/yum.repos.d/beegfs.repo
    rpm --import http://www.beegfs.com/release/latest-stable/gpg/RPM-GPG-KEY-beegfs

    yum install -y beegfs-client beegfs-helperd beegfs-utils

    sed -i 's/^sysMgmtdHost.*/sysMgmtdHost = '$MASTER_HOSTNAME'/g' /etc/beegfs/beegfs-client.conf
    sed -i  's/Type=oneshot.*/Type=oneshot\nRestart=always\nRestartSec=5/g' /etc/systemd/system/multi-user.target.wants/beegfs-client.service
    echo "$SHARE_SCRATCH /etc/beegfs/beegfs-client.conf" > /etc/beegfs/beegfs-mounts.conf

    if is_master; then
        yum install -y beegfs-mgmtd beegfs-meta
        mkdir -p /data/beegfs/mgmtd
        sed -i 's|^storeMgmtdDirectory.*|storeMgmtdDirectory = /data/beegfs/mgmt|g' /etc/beegfs/beegfs-mgmtd.conf
        sed -i 's|^storeMetaDirectory.*|storeMetaDirectory = '$CLUSTERFS_METADATA_PATH'|g' /etc/beegfs/beegfs-meta.conf
        sed -i 's/^sysMgmtdHost.*/sysMgmtdHost = '$MASTER_HOSTNAME'/g' /etc/beegfs/beegfs-meta.conf
        /etc/init.d/beegfs-mgmtd start
        /etc/init.d/beegfs-meta start
    else
        yum install -y beegfs-storage
        sed -i 's|^storeStorageDirectory.*|storeStorageDirectory = '$CLUSTERFS_STORAGE_PATH'|g' /etc/beegfs/beegfs-storage.conf
        sed -i 's/^sysMgmtdHost.*/sysMgmtdHost = '$MASTER_HOSTNAME'/g' /etc/beegfs/beegfs-storage.conf
        /etc/init.d/beegfs-storage start
    fi

    systemctl daemon-reload
}

setup_swap()
{
    sed -i 's|^ResourceDisk.EnableSwap=n|ResourceDisk.EnableSwap=y|g' /etc/waagent.conf
    sed -i 's|^ResourceDisk.SwapSizeMB=0|ResourceDisk.SwapSizeMB=4096' /etc/waagent.conf
}

custom_script()
{
    if [ -n "$CUSTOM_SCRIPT_URL" ]; then
        mkdir custom_script
        cd custom_script
        filename="`echo "${CUSTOM_SCRIPT_URL##*/}" | cut -d? -f1`"
        wget -O $filename "$CUSTOM_SCRIPT_URL"
        chmod +x $filename
        ./$filename
        cd ..
        return $?
    fi
}

setup_swap
install_pkgs
setup_shares
setup_hpc_user

if [ "$CLUSTERFS" == "BeeGFS" ]; then
    install_beegfs
fi

install_munge
install_slurm
setup_env
custom_script
shutdown -r +1 &
exit 0
