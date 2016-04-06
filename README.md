# simpleMPIPOC
Templates and scripts for deploying a Premium NFS Server, a head node, and compute nodes 
uses a custom image for the compute cluster

Requires that a Premium Storage account be provisioned in advance for the NFS Server
Requires that a Standard Storage account be provisioned in advance with the custom image page blob residing in a container named "vhds". Requires an existing Virtual Network and subnet

Does not provision any Public IP addresses, so there should either be a VPN connection to an on-prem network, or a jump box with a public IP on the same Virtual Network.

Besides the admin user, it also provisions a user account on all of the machines with the name and password specified in the parameters. This user will have its home directory provisioned on the NFS server so that the .ssh directory will be shared among all the nodes enabling ssh connections between all of them.



