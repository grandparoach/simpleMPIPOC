# simpleMPIPOC
Templates and scripts for deploying a Master Node which serves as an NFS Server to the Compute Nodes.  It will also deploy the compute nodes.  All the machines are built using Managed Storage.

It will provision the resources onto an existing V-Net, so there will not be any public IP addresses.

The sizes and images to be deployed on the Master and the Compute nodes can be selected from input parameters.  

Besides the admin user, it also provisions a user account on all of the machines named "hpcuser".  This user will have its home directory provisioned on the NFS server so that the .ssh directory will be shared among all the nodes enabling ssh connections between all of them.
So, all MPI jobs must be run as the "hpcuser". (sudo su hpcuser)

The nodes will be assigned static IP addresses based on the input parameters.  The starting address for the compute nodes will be specified by a prefix (i.e. 10.0.2) and an offset (i.e. 21), so that the address of the first compute node will be those two strings concatenated together (i.e. 10.0.2.21) and the rest of the Compute node addresses will increment from there.

For MPI jobs, be sure to select the H16r, or H16mr VMsku and the CentOS-HPC-7.1 image.  This will have the Infiniband drivers and the Intel MPI included in the image.

Also, be sure that there is no conflict elsewhere for the 172.16.0.0/16 address range as this is hardcoded for the Infiniband and it cannpt be changed.  Finally, make sure that the Environment variables are set according to the example at this site https://docs.microsoft.com/en-us/azure/virtual-machines/linux/classic/rdma-cluster as specified in the "Configure Intel MPI" section.

The DataDiskSize and nbDataDisks parameters refer to the NFS Server.  ndDataDisks of DataDiskSize will be attached to the NFS Server, then they will be formatted and combined into a single RAID 0 volume which will then be exported as the /share/data directory. 


[![Click to deploy template on Azure](http://azuredeploy.net/deploybutton.png "Click to deploy template on Azure")](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fgrandparoach%2FsimpleMPIPOC%2FCat%2Fazuredeploy.json)  



