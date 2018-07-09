#!/bin/bash
set +x
MASTER_NAME=$1
echo $MASTER_NAME

# disable selinux
    sed -i 's/enforcing/disabled/g' /etc/selinux/config
    setenforce permissive

# Shares
SHARE_HOME=/share/home
NFS_ON_MASTER=/share/data
NFS_MOUNT=/share/data

mkdir -p /share
mkdir -p $SHARE_HOME

# User
HPC_USER=hpcuser
HPC_UID=7007
HPC_GROUP=hpc
HPC_GID=7007


install_pkgs()
{
    yum -y install epel-release
    yum -y install zlib zlib-devel bzip2 bzip2-devel bzip2-libs openssl openssl-devel openssl-libs gcc gcc-c++ nfs-utils rpcbind mdadm wget python-pip openmpi openmpi-devel automake autoconf pdsh 
    yum -y install redhat-lsb
}

mount_nfs()
{

	yum -y install nfs-utils nfs-utils-lib
	
	mkdir -p ${NFS_MOUNT}

	showmount -e ${MASTER_NAME}
	mount -t nfs ${MASTER_NAME}:${NFS_ON_MASTER} ${NFS_MOUNT}
	
	echo "${MASTER_NAME}:${NFS_ON_MASTER} ${NFS_MOUNT} nfs defaults,nofail  0 0" >> /etc/fstab
}


setup_user()
{  

	echo "$MASTER_NAME:$SHARE_HOME $SHARE_HOME    nfs4    rw,auto,_netdev 0 0" >> /etc/fstab
	mount -a
	mount
   
    groupadd -g $HPC_GID $HPC_GROUP

    # Don't require password for HPC user sudo
    echo "$HPC_USER ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
    
    # Disable tty requirement for sudo
    sed -i 's/^Defaults[ ]*requiretty/# Defaults requiretty/g' /etc/sudoers

	useradd -c "HPC User" -g $HPC_GROUP -d $SHARE_HOME/$HPC_USER -s /bin/bash -u $HPC_UID $HPC_USER


}

install_cuda_drivers()
{  
    rpm -Uvh https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
    yum -y install dkms
    
    CUDA_REPO_PKG=cuda-repo-rhel7-9.1.85-1.x86_64.rpm
    wget http://developer.download.nvidia.com/compute/cuda/repos/rhel7/x86_64/${CUDA_REPO_PKG} -O /tmp/${CUDA_REPO_PKG}
    
    rpm -ivh /tmp/${CUDA_REPO_PKG}
    rm -f /tmp/${CUDA_REPO_PKG}
    
    yum -y install cuda-drivers
    
    yum -y install cuda
	
}

install_pkgs
mount_nfs
setup_user
install_cuda_drivers

reboot
