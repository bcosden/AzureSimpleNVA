# AzureSimpleNVA
Deploy a simple NVA using BGP to inject routes

This deployment uses Azure CLI as a teching tool to understand how an NVA is deployed and configured in Linux

1nic: Deploys a FRR NVA device with a single NIC for east-west and north-south
2nic: Deploys a Quagga NVA device with a dual NIC for internet breakout on the 1st NIC and east-west on 2nd NIC.
GWLB: Deploys a sample Gateway Load Balancer configuration using Linux. It shows how VXLAN tunnels are established.

