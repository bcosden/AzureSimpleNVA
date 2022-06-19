#!/bin/bash

# VARIABLES
rg="gwlbnva"
loc="eastus"
vmnva="nvaVM"
vmapp="appVM"

# output key variables
nvapubip=$(az network public-ip show -n $vmnva"-pip" -g $rg --query ipAddress -o tsv)
apppubip=$(az network public-ip show -n $vmapp"-pip" -g $rg --query ipAddress -o tsv)
applbpip=$(az network public-ip show -n applb-pip -g $rg --query ipAddress -o tsv)

echo "app lb ip: "$applbpip
echo "app public ip: "$apppubip
echo "nva public ip: "$nvapubip
echo ""
echo "To check deployment: curl http://"$applbpip":8080/api/ip"