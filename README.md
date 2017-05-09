# simpleMPIPOC
Templates and scripts for deploying a Master Node which serves as an NFS Server and a JumpBox to the Compute Nodes.  It will also deploy the compute nodes to a VM Scale Set.  All the machines are built using Managed Storage.

It will provision the resources onto an existing V-Net.

The images to be deployed on the Mater and the Compute nodes can be selected from input parameters.  

Besides the admin user, it also provisions a user account on all of the machines named "hpcuser".  This user will have its home directory provisioned on the NFS server so that the .ssh directory will be shared among all the nodes enabling ssh connections between all of them.
So, all MPI jobs must be run as the "hpcuser".


[![Click to deploy template on Azure](http://azuredeploy.net/deploybutton.png "Click to deploy template on Azure")](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fgrandparoach%2FsimpleMPIPOC%2FCat%2Fazuredeploy.json)  



