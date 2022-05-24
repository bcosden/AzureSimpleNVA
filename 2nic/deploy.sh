#!/bin/bash

# VARIABLES
rg="rsQuagga-2nic"
loc="eastus"

vmname="QuaggaVM"
vmtest="TestVM"
username="azureuser"
password="MyP@ssword123"
vmsize="Standard_D2S_v3"

# create a resource group
echo '['$(date +"%T")'] Creating Resource Group' $rg 'in' $loc
az group create -n $rg -l $loc -o none

# create a virtual network
echo '['$(date +"%T")'] Creating Virtual Network hubVnet and RouteServerSubnet'
az network vnet create --address-prefixes 10.1.0.0/16 -n hubVnet -g $rg --subnet-name RouteServerSubnet --subnet-prefixes 10.1.1.0/25 -o none

# create route table
echo '['$(date +"%T")'] Creating route table for QuaggaVM external interace to internet'
az network route-table create -g $rg -n extroute --disable-bgp-route-propagation true -o none
az network route-table route create -n to_internet -g $rg --address-prefix 0.0.0.0/0 --next-hop-type Internet --route-table-name extroute -o none

# create subnets
echo '['$(date +"%T")'] Creating subnets'
echo ".... creating subnet1"
az network vnet subnet create -g $rg --vnet-name hubVnet -n subnet1 --address-prefixes 10.1.2.0/24 -o none
echo ".... creating external"
az network vnet subnet create -g $rg --vnet-name hubVnet -n external --address-prefixes 10.1.3.0/24 --route-table extroute -o none
echo ".... creating internal"
az network vnet subnet create -g $rg --vnet-name hubVnet -n internal --address-prefixes 10.1.4.0/24 -o none
echo ".... creating GatewaySubnet"
az network vnet subnet create -g $rg --vnet-name hubVnet -n GatewaySubnet --address-prefixes 10.1.5.0/24 -o none
echo ".... creating AzureBastionSubnet"
az network vnet subnet create -g $rg --vnet-name hubVnet -n AzureBastionSubnet --address-prefixes 10.1.6.0/26 -o none

# create route server
echo '['$(date +"%T")'] Creating Routeserver'
subnet_id=$(az network vnet subnet show \
    --name RouteServerSubnet \
    --resource-group $rg \
    --vnet-name hubVnet \
    --query id -o tsv) 

az network public-ip create \
    --name rshub-pip \
    --resource-group $rg \
    --version IPv4 \
    --sku Standard \
    --output none --only-show-errors

az network routeserver create \
    --name rshub \
    --resource-group $rg \
    --hosted-subnet $subnet_id \
    --public-ip-address rshub-pip \
    --output none

# Create bastion to support access to other VM's that are not reachable publicly
echo '['$(date +"%T")'] Creating Bastion'
az network public-ip create --name bastion-pip --resource-group $rg -l $loc --sku Standard -o none --only-show-errors
az network bastion create -g $rg -n bastion --public-ip-address bastion-pip --vnet-name hubVnet -l $loc -o none --only-show-errors

# Turn on SSH tunneling
# az cli does not have a property to enable SSH tunneling, so must be done via rest API
echo '['$(date +"%T")'] Enable Bastion Tunneling'
subid=$(az account show --query 'id' -o tsv)
uri='https://management.azure.com/subscriptions/'$subid'/resourceGroups/'$rg'/providers/Microsoft.Network/bastionHosts/bastion?api-version=2021-08-01'
json='{
  "location": "'$loc'",
  "properties": {
    "enableTunneling": "true",
    "ipConfigurations": [
      {
        "name": "bastion_ip_config",
        "properties": {
          "subnet": {
            "id": "/subscriptions/'$subid'/resourceGroups/'$rg'/providers/Microsoft.Network/virtualNetworks/hubVnet/subnets/AzureBastionSubnet"
          },
          "publicIPAddress": {
            "id": "/subscriptions/'$subid'/resourceGroups/'$rg'/providers/Microsoft.Network/publicIPAddresses/bastion-pip"
          }
        }
      }
    ]
  }
}'

az rest --method PUT \
    --url $uri  \
    --body "$json"  \
    --output none

# create QuaggaVM
mypip=$(curl -4 ifconfig.io -s)
echo '['$(date +"%T")'] Create Public IP, NSG, and Allow SSH on port 22 for IP: '$mypip
az network nsg create -g $rg -n $vmname"NSG" -o none
az network nsg rule create -n "Allow-SSH" --nsg-name $vmname"NSG" --priority 300 -g $rg --direction Inbound --protocol TCP --source-address-prefixes $mypip --destination-port-ranges 22 -o none
az network public-ip create -n $vmname"-pip" -g $rg --version IPv4 --sku Standard -o none --only-show-errors 

echo '['$(date +"%T")'] Creating Quagga VM'
az network nic create -g $rg --vnet-name hubVnet --subnet internal -n $vmname"IntNIC" --private-ip-address 10.1.4.10 --ip-forwarding true -o none
az network nic create -g $rg --vnet-name hubVnet --subnet external -n $vmname"ExtNIC" --public-ip-address $vmname"-pip" --private-ip-address 10.1.3.10 --network-security-group $vmname"NSG" --ip-forwarding true -o none
az vm create -n $vmname -g $rg \
    --image ubuntults \
    --size $vmsize \
    --nics $vmname"ExtNIC" $vmname"IntNIC" \
    --authentication-type ssh \
    --admin-username $username \
    --ssh-key-values @~/.ssh/id_rsa.pub \
    --custom-data cloud-init \
    --output none \
    --only-show-errors

# create a testVM
echo '['$(date +"%T")'] Creating Test VM'
az network nic create -g $rg --vnet-name hubVnet --subnet subnet1 -n $vmtest"NIC" -o none
az vm create -n $vmtest -g $rg \
    --image ubuntults \
    --size $vmsize \
    --nics $vmtest"NIC" \
    --authentication-type ssh \
    --admin-username $username \
    --ssh-key-values @~/.ssh/id_rsa.pub \
    --output none \
    --only-show-errors

# enable b2b
echo '['$(date +"%T")'] Enable B2B on RouteServer'
az network routeserver update --name rshub --resource-group $rg --allow-b2b-traffic true -o none

# create peering
echo '['$(date +"%T")'] Creating RouteServer Peering'
az network routeserver peering create \
    --name Quagga \
    --peer-ip 10.1.4.10 \
    --peer-asn 65001 \
    --routeserver rshub \
    --resource-group $rg \
    --output none

# list routes
echo '['$(date +"%T")'] Quagga deployed. Listing Advertised Routes:'
az network routeserver peering list-advertised-routes \
    --name Quagga \
    --routeserver rshub \
    --resource-group $rg

echo '['$(date +"%T")'] Listing Learned Routes:'
az network routeserver peering list-learned-routes \
    --name Quagga \
    --routeserver rshub \
    --resource-group $rg

echo "To check Quagga route table"
echo "ssh azureuser@"$(az vm show -g $rg -n $vmname --show-details --query "publicIps" -o tsv)
echo "vtysh"
echo "show ip bgp"
