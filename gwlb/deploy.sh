#!/bin/bash

# VARIABLES
rg="gwlbnva"
loc="eastus"

vmnva="nvaVM"
vmapp="appVM"
username="azureuser"
password="MyP@ssword123"
vmsize="Standard_D2S_v3"

# create a resource group
echo -e '\033[1m['$(date +"%T")']\033[32m Creating Resource Group\033[36m' $rg '\033[32min\033[36m' $loc
az group create -n $rg -l $loc -o none

# create NVA virtual network
echo -e '\033[1m['$(date +"%T")']\033[32m Creating NVA Virtual Network'
az network vnet create --address-prefixes 10.1.0.0/16 -n nvaVnet -g $rg --subnet-name nva --subnet-prefixes 10.1.0.0/24 -o none

# create App virtual network
echo -e '\033[1m['$(date +"%T")']\033[32m Creating App Virtual Network'
az network vnet create --address-prefixes 192.168.0.0/16 -n appVnet -g $rg --subnet-name app --subnet-prefixes 192.168.0.0/24 -o none

# create Application VM
echo -e '\033[1m['$(date +"%T")']\033[32m Creating Application VM'
az network nic create -g $rg --vnet-name appVnet --subnet app -n $vmapp"NIC" -o none
az vm create -n $vmapp -g $rg \
    --image ubuntults \
    --size $vmsize \
    --nics $vmapp"NIC" \
    --authentication-type ssh \
    --admin-username $username \
    --ssh-key-values @~/.ssh/id_rsa.pub \
    --custom-data cloud-appinit \
    --output none \
    --only-show-errors

# create Application Load Balancer
echo -e '\033[1m['$(date +"%T")']\033[32m Creating App External Load Balancer'
az network public-ip create -g $rg -n applb-pip --sku standard --allocation-method static -o none --only-show-errors
az network lb create -n applb -g $rg --sku Standard --vnet-name appVnet --public-ip-address applb-pip --backend-pool-name vms --frontend-ip-name vmfrontend -o none
echo '['$(date +"%T")'] create probe ...'
az network lb probe create -n vmprobe --lb-name applb -g $rg --protocol tcp --port 8080 --interval 5 --threshold 2 -o none
echo '['$(date +"%T")'] create rule(s) ...'
az network lb rule create --name vmrule \
    --lb-name applb \
    --resource-group $rg \
    --protocol tcp \
    --frontend-port 8080 \
    --backend-port 8080 \
    --frontend-ip-name vmfrontend \
    --backend-pool-name vms \
    --probe-name vmprobe \
    --output none

# attach backend pool to LB
echo '['$(date +"%T")'] attach app vm ...'
appvmnicid=$(az vm show -n $vmapp -g $rg --query 'networkProfile.networkInterfaces[0].id' -o tsv)
appvmconfig=$(az network nic show --ids $appvmnicid --query 'ipConfigurations[0].name' -o tsv)
az network nic ip-config address-pool add --nic-name $vmapp"NIC" -g $rg --ip-config-name $appvmconfig --lb-name applb --address-pool vms -o none

# test health ok
echo -e '\033[1m['$(date +"%T")']\033[32m Test Load Balancer Health'
applbpip=$(az network public-ip show -n applb-pip -g $rg --query ipAddress -o tsv)
curl "http://${applbpip}:8080/api/healthcheck"

# create GWLB
echo -e '\033[1m['$(date +"%T")']\033[32m Creating Gateway Load Balancer'
az network lb create -n gwlb -g $rg --sku Gateway --vnet-name nvaVnet --subnet nva --backend-pool-name nvas --frontend-ip-name nvafrontend -o none --only-show-errors
az network lb address-pool tunnel-interface add --address-pool nvas --lb-name gwlb -g $rg --type External --protocol VXLAN --identifier '901' --port '10801' -o none --only-show-errors
echo '['$(date +"%T")'] create probe ...'
az network lb probe create -n nvaprobe --lb-name gwlb -g $rg --protocol tcp --port 22 --interval 5 --threshold 2 -o none
echo '['$(date +"%T")'] create rule ...'
az network lb rule create --name nvarule \
    --lb-name gwlb \
    --resource-group $rg \
    --protocol All \
    --frontend-port 0 \
    --backend-port 0 \
    --frontend-ip-name nvafrontend \
    --backend-pool-name nvas \
    --probe-name nvaprobe \
    --output none

gwlbpip=$(az network lb frontend-ip show -n nvafrontend --lb-name gwlb -g $rg --query privateIpAddress -o tsv)
applbpip=$(az network public-ip show -n applb-pip -g $rg --query ipAddress -o tsv)
sed 's/GWLB_PIP/'$gwlbpip'/g;s/APPLB_PIP/'$applbpip'/g' cloud-nvainit > cloud-nvainit.tmp

# create NVA VM
mypip=$(curl -4 ifconfig.io -s)
echo -e '\033[1m['$(date +"%T")']\033[32m Create Public IP, NSG, and Allow SSH on port 22 for IP: '$mypip
az network nsg create -g $rg -n $vmnva"NSG" -o none
az network nsg rule create -n "Allow-SSH" --nsg-name $vmnva"NSG" --priority 300 -g $rg --direction Inbound --protocol TCP --source-address-prefixes $mypip --destination-port-ranges 22 -o none
az network public-ip create -g $rg -n $vmnva"-pip" --sku standard --allocation-method static -o none --only-show-errors
az network nic create -g $rg --vnet-name nvaVnet --subnet nva -n $vmnva"NIC" --public-ipAddress $vmnva"-pip" --network-security-group $vmnnva"NSG" --ip-forwarding -o none
az vm create -n $vmnva -g $rg \
    --image ubuntults \
    --size $vmsize \
    --nics $vmnva"NIC" \
    --authentication-type ssh \
    --admin-username $username \
    --ssh-key-values @~/.ssh/id_rsa.pub \
    --custom-data cloud-nvainit.tmp \
    --output none \
    --only-show-errors

# Add nva to backend of gwlb
echo '['$(date +"%T")'] attach nva vm ...'
nvanicid=$(az vm show -n $vmnva -g $rg --query 'networkProfile.networkInterfaces[0].id' -o tsv)
nvaconfig=$(az network nic show --ids $nvanicid --query 'ipConfigurations[0].name' -o tsv)
az network nic ip-config address-pool add --nic-name $vmnva"NIC" -g $rg --ip-config-name $nvaconfig --lb-name gwlb --address-pool nvas -o none

# chain app lb to nva lb
echo -e '\033[1m['$(date +"%T")']\033[32m Chain App Load Balancer to Gateway Load Balancer'
gwlbid=$(az network lb frontend-ip show --lb-name gwlb -g $rg -n nvafrontend --query id -o tsv)
az network lb frontend-ip update -n vmfrontend --lb-name applb -g $rg --public-ip-address applb-pip --gateway-lb $gwlbid -o none --only-show-errors

