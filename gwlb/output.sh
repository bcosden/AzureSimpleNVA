#!/bin/bash

# VARIABLES
rg="gwlbnva"
loc="eastus"
vmnva="nvaVM"
vmapp="appVM"

if [  -z $(az group show -n $rg --query id -o tsv) ]; then
    echo -e "\nPlease confirm the resource group exists and the resources have been deployed."
else
    # output key variables
    nvapubip=$(az network public-ip show -n $vmnva"-pip" -g $rg --query ipAddress -o tsv)
    apppubip=$(az network public-ip show -n $vmapp"-pip" -g $rg --query ipAddress -o tsv)
    applbpip=$(az network public-ip show -n applb-pip -g $rg --query ipAddress -o tsv)

    echo "app lb ip: "$applbpip
    echo "app public ip: "$apppubip
    echo "nva public ip: "$nvapubip
    echo ""
    echo -e "To check deployment: \ncurl http://"$applbpip":8080/api/ip"
fi

