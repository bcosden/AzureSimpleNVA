#!/bin/bash

# VARIABLES
rg="gwlbnva"
loc="eastus"

BLACK="\033[30m"
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
PINK="\033[35m"
CYAN="\033[36m"
WHITE="\033[37m"
NORMAL="\033[0;39m"

usessh="true"
vmnva="nvaVM"
vmapp="appVM"
username="azureuser"
password="MyP@ssword123"
vmsize="Standard_D2S_v3"

# create a resource group
echo -e "$WHITE$(date +"%T")$GREEN Creating Resource Group$CYAN" $rg"$GREEN in $CYAN"$loc"$WHITE"
az group create -n $rg -l $loc -o none

# create NVA virtual network
echo -e "$WHITE$(date +"%T")$GREEN Creating NVA Virtual Network$WHITE"
az network vnet create --address-prefixes 10.1.0.0/16 -n nvaVnet -g $rg --subnet-name nva --subnet-prefixes 10.1.0.0/24 -o none

# create App virtual network
echo -e "$WHITE$(date +"%T")$GREEN Creating App Virtual Network$WHITE"
az network vnet create --address-prefixes 192.168.0.0/16 -n appVnet -g $rg --subnet-name app --subnet-prefixes 192.168.0.0/24 -o none

# create Application VM
echo -e "$WHITE$(date +"%T")$GREEN Create Application Public IP and NIC $WHITE"
az network public-ip create -g $rg -n $vmapp"-pip" --sku standard --allocation-method static -o none --only-show-errors
az network nic create -g $rg --vnet-name appVnet --subnet app -n $vmapp"NIC" --public-ip-address $vmapp"-pip" -o none

# default is to use your local .ssh key in folder ~/.ssh/id_rsa.pub
if [ $usessh = "true" ]; then
    echo -e "$WHITE$(date +"%T")$GREEN Creating Application VM using public key $WHITE"
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
else
    echo -e "$WHITE$(date +"%T")$GREEN Creating Application VM using default password $WHITE"
    az vm create -n $vmapp -g $rg \
        --image ubuntults \
        --size $vmsize \
        --nics $vmapp"NIC" \
        --admin-username $username \
        --admin-password $password \
        --custom-data cloud-appinit \
        --output none \
        --only-show-errors
fi

# create NSG at subnet level and set access policy
echo -e "$WHITE$(date +"%T")$GREEN Creating Subnet NSG for appVnet $WHITE"
az network nsg create -g $rg -n "appVnet-nsg" -o none
az network vnet subnet update -g $rg -n app --vnet-name appVnet --network-security-group "appVnet-nsg" -o none

echo -e "$WHITE$(date +"%T")$GREEN Creating Access Policy for App $WHITE"
subid=$(az account show --query 'id' -o tsv)
uri='https://management.azure.com/subscriptions/'$subid'/resourceGroups/'$rg'/providers/Microsoft.Security/locations/'$loc'/jitNetworkAccessPolicies/'$vmapp'?api-version=2020-01-01'
json='{
  "kind": "Basic",
  "properties": {
    "virtualMachines": [
    {
      "id": "/subscriptions/'$subid'/resourceGroups/'$rg'/providers/Microsoft.Compute/virtualMachines/'$vmapp'",
      "ports": [
      {
        "number": 22,
        "protocol": "*",
        "allowedSourceAddressPrefix": "*",
        "maxRequestAccessDuration": "PT24H"
      },
      {
        "number": 8080,
        "protocol": "*",
        "allowedSourceAddressPrefix": "*",
        "maxRequestAccessDuration": "PT24H"
      }]
    }]
   }
  }'

az rest --method PUT \
    --url $uri  \
    --body "$json" \
    --output none

# create Application Load Balancer
echo -e "$WHITE$(date +"%T")$GREEN Creating App External Load Balancer$WHITE"
az network public-ip create -g $rg -n applb-pip --sku standard --allocation-method static -o none --only-show-errors
az network lb create -n applb -g $rg --sku Standard --vnet-name appVnet --public-ip-address applb-pip --backend-pool-name vms --frontend-ip-name vmfrontend -o none
echo "$(date +"%T") ...create probe"
az network lb probe create -n vmprobe --lb-name applb -g $rg --protocol tcp --port 8080 --interval 5 --threshold 2 -o none
echo "$(date +"%T") ...create rule(s)"
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
echo "$(date +"%T") ...attach app vm"
appvmnicid=$(az vm show -n $vmapp -g $rg --query 'networkProfile.networkInterfaces[0].id' -o tsv)
appvmconfig=$(az network nic show --ids $appvmnicid --query 'ipConfigurations[0].name' -o tsv)
az network nic ip-config address-pool add --nic-name $vmapp"NIC" -g $rg --ip-config-name $appvmconfig --lb-name applb --address-pool vms -o none

# test health ok
echo -e "$WHITE$(date +"%T")$GREEN Test Application Load Balancer Health $WHITE"
applbpip=$(az network public-ip show -n applb-pip -g $rg --query ipAddress -o tsv)
apppubip=$(az network public-ip show -n $vmapp"-pip" -g $rg --query ipAddress -o tsv)
echo "app public ip health check:"
curl "http://${apppubip}:8080/api/healthcheck"
echo "lb health check:"
curl "http://${applbpip}:8080/api/healthcheck"

# create GWLB
echo -e "$WHITE$(date +"%T")$GREEN Creating Gateway Load Balancer$WHITE"
az network lb create -n gwlb -g $rg --sku Gateway --vnet-name nvaVnet --subnet nva --backend-pool-name nvas --frontend-ip-name nvafrontend -o none --only-show-errors
az network lb address-pool tunnel-interface add --address-pool nvas --lb-name gwlb -g $rg --type External --protocol VXLAN --identifier '901' --port '10801' -o none --only-show-errors
echo "$(date +"%T") ...create probe"
az network lb probe create -n nvaprobe --lb-name gwlb -g $rg --protocol tcp --port 22 --interval 5 --threshold 2 -o none
echo "$(date +"%T") ...create rule"
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
echo -e "$WHITE$(date +"%T")$GREEN Create NVA Public IP and NIC $WHITE"
az network public-ip create -g $rg -n $vmnva"-pip" --sku standard --allocation-method static -o none --only-show-errors
az network nic create -g $rg --vnet-name nvaVnet --subnet nva -n $vmnva"NIC" --public-ip-address $vmnva"-pip" --ip-forwarding -o none

# default is to use your local .ssh key in folder ~/.ssh/id_rsa.pub
if [ $usessh = "true" ]; then
    echo -e "$WHITE$(date +"%T")$GREEN Creating NVA VM using public key $WHITE"
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
else
    echo -e "$WHITE$(date +"%T")$GREEN Creating NVA VM using default password $WHITE"
    az vm create -n $vmnva -g $rg \
        --image ubuntults \
        --size $vmsize \
        --nics $vmnva"NIC" \
        --admin-username $username \
        --admin-password $password \
        --custom-data cloud-nvainit.tmp \
        --output none \
        --only-show-errors
fi

# create NSG at subnet level and set access policy
echo -e "$WHITE$(date +"%T")$GREEN Creating Subnet NSG for nvaVnet $WHITE"
az network nsg create -g $rg -n "nvaVnet-nsg" -o none
az network vnet subnet update -g $rg -n nva --vnet-name nvaVnet --network-security-group "nvaVnet-nsg" -o none

echo -e "$WHITE$(date +"%T")$GREEN Creating Access Policy for NVA $WHITE"
uri='https://management.azure.com/subscriptions/'$subid'/resourceGroups/'$rg'/providers/Microsoft.Security/locations/'$loc'/jitNetworkAccessPolicies/'$vmnva'?api-version=2020-01-01'
json='{
  "kind": "Basic",
  "properties": {
    "virtualMachines": [
    {
      "id": "/subscriptions/'$subid'/resourceGroups/'$rg'/providers/Microsoft.Compute/virtualMachines/'$vmnva'",
      "ports": [
      {
        "number": 22,
        "protocol": "*",
        "allowedSourceAddressPrefix": "*",
        "maxRequestAccessDuration": "PT24H"
      }]
    }]
   }
  }'

az rest --method PUT \
    --url $uri  \
    --body "$json" \
    --output none

# Add nva to backend of gwlb
echo "$(date +"%T") ...attach nva vm"
nvanicid=$(az vm show -n $vmnva -g $rg --query 'networkProfile.networkInterfaces[0].id' -o tsv)
nvaconfig=$(az network nic show --ids $nvanicid --query 'ipConfigurations[0].name' -o tsv)
az network nic ip-config address-pool add --nic-name $vmnva"NIC" -g $rg --ip-config-name $nvaconfig --lb-name gwlb --address-pool nvas -o none

# chain app lb to nva lb
echo -e "$WHITE$(date +"%T")$GREEN Chain App Load Balancer to Gateway Load Balancer$WHITE"
gwlbid=$(az network lb frontend-ip show --lb-name gwlb -g $rg -n nvafrontend --query id -o tsv)
az network lb frontend-ip update -n vmfrontend --lb-name applb -g $rg --public-ip-address applb-pip --gateway-lb $gwlbid -o none --only-show-errors

# output key variables
echo -e "$WHITE$(date +"%T")$GREEN Deployment Complete: $WHITE"
echo "app lb ip: "$applbpip
nvapubip=$(az network public-ip show -n $vmnva"-pip" -g $rg --query ipAddress -o tsv)
echo "app public ip: "$apppubip
echo "nva public ip: "$nvapubip
echo ""
echo -e "To check deployment: \ncurl http://"$applbpip":8080/api/ip"
echo ""
echo "It may take up to 5 minutes before the API will respond ...."
