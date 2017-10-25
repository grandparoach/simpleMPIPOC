# simpleMPIPOC
Templates and scripts for deploying a Master Node which serves as an NFS Server and a JumpBox to the Compute Nodes.  It will also deploy the compute nodes to a VM Scale Set. All the machines are built using Managed Storage.

It will provision an the VMSS onto and existing Virtual Network and Subnet.  There will be a Public IP address on the Master machine.

The images to be deployed on the Mater and the Compute nodes can be selected from input parameters.  

Besides the admin user, it also provisions a user account on all of the machines named "hpcuser".  This user will have its home directory provisioned on the NFS server so that the .ssh directory will be shared among all the nodes enabling ssh connections between all of them.
So, all MPI jobs must be run as the "hpcuser".

For MPI jobs, be sure to select the H16r, or H16mr VMsku and the CentOS-HPC-7.1 image.  This will have the Infiniband drivers and the Intel MPI included in the image.

Make sure that the Environment variables are set according to the example at this site https://docs.microsoft.com/en-us/azure/virtual-machines/linux/classic/rdma-cluster as specified in the "Configure Intel MPI" section.

The DataDiskSize and nbDataDisks parameters refer to the NFS Server.  ndDataDisks of DataDiskSize will be attached to the NFS Server, then they will be formatted and combined into a single RAID 0 volume which will then be exported as the /share/data directory. 


[![Click to deploy template on Azure](http://azuredeploy.net/deploybutton.png "Click to deploy template on Azure")](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fgrandparoach%2FsimpleMPIPOC%2Fhonda%2Fazuredeploy.json)  



