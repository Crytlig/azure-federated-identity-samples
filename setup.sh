#!/bin/bash

set -e

if [ ! -f "./.env" ]; then
  echo "File \"./.env\" doesn't exist"
  echo "Please create the file and fill the following items: \

    SUBSCRIPTION_ID='XXXXXX'
    RESOURCE_GROUP_NAME='XXXXXX'
    LOCATION='XXXXXX'
    AKS_NAME='XXXXXX'
    APP_DISPLAYNAME='XXXXXX'"
  exit 1
fi

# Load variables from env file
set -o allexport; source .env; set +o allexport

# reference: https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect#example-subject-claims
GH_SUBJECT="repo:Crytlig/azure-federated-identity-samples:ref:refs/heads/main"

az account set --subscription ${SUBSCRIPTION_ID}

# create resource group
az group create -n ${RESOURCE_GROUP_NAME} -l ${LOCATION}

# create AKS cluster with Azure RBAC
az aks create \
  -g ${RESOURCE_GROUP_NAME} \
  -n ${AKS_NAME} \
  --enable-aad \
  --enable-azure-rbac \
  --generate-ssh-keys
    
# get AKS cluster resource ID
AKS_RESOURCE_ID=$(az aks show \
  -g ${RESOURCE_GROUP_NAME} \
  -n ${AKS_NAME} -o tsv --query "id" || true)

# Create AAD Application
AAD_APP=$(az ad app create --display-name ${APP_DISPLAYNAME} -o json)
APP_OID=$(echo ${AAD_APP} | jq -r ".id")
APP_ID=$(echo ${AAD_APP} | jq -r ".appId")

# Create AAD Service Principal from AAD application
# I don't use `az ad sp create-for-rbac` as that will create a password credential that I don't need
az ad sp create --id ${APP_OID}

SPN_OID=$(az ad sp show --id ${APP_ID} -o tsv --query "id")

# Create role assignment to the cluster
# this allows the SP to list user credential and performs k8s operations
az role assignment create \
  --role "Azure Kubernetes Service RBAC Cluster Admin" \
  --scope ${AKS_RESOURCE_ID} \
  --assignee-object-id ${SPN_OID} \
  --assignee-principal-type ServicePrincipal

# Create federated identity credential on the AAD app
az rest \
  --method POST \
  --uri "https://graph.microsoft.com/beta/applications/${APP_OID}/federatedIdentityCredentials" \
  --body "{\"name\":\"${APP_DISPLAYNAME}\",
          \"issuer\":\"https://token.actions.githubusercontent.com\",
          \"subject\":\"${GH_SUBJECT}\"
          ,\"description\":\"Testing federated credenital on GitHub actions\",
          \"audiences\":[\"api://AzureADTokenExchange\"]}"
