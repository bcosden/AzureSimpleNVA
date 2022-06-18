#!/bin/bash

# VARIABLES
rg="gwlbnva"
loc="eastus"

vmname="nvaVM"
username="azureuser"
password="MyP@ssword123"
vmsize="Standard_D2S_v3"

# create a resource group
echo '['$(date +"%T")'] Creating Resource Group' $rg 'in' $loc
az group create -n $rg -l $loc -o none

# create a virtual network
echo '['$(date +"%T")'] Creating NVA Virtual Network'
az network vnet create --address-prefixes 10.1.0.0/16 -n nvaVnet -g $rg --subnet-name subnet1 --subnet-prefixes 10.1.0.0/24 -o none

echo '['$(date +"%T")'] Creating App Virtual Network'
az network vnet create --address-prefixes 192.168.0.0/16 -n appVnet -g $rg --subnet-name subnet1 --subnet-prefixes 192.168.0.0/24 -o none

