#!/bin/sh

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT

# Amazon CloudWatch Agent — Azure identity setup
#
# Enables the Azure-side identity the agent authenticates with:
#
#   azure_vm    assigns a system-assigned managed identity to the VM
#   azure_aks   enables the OIDC issuer and workload identity on the cluster,
#               an "az aks update" that can take several minutes
#
# Requires only the Azure CLI ("az"). Outputs the tenant ID for azure_vm, or the
# OIDC issuer URL for azure_aks.
#
# Usage:
#   Interactive (TTY):
#     ./azure/setup-identity.sh
#
#   Environment variables (piped/automated):
#     CWAGENT_PLATFORM=azure_vm \
#     CWAGENT_AZURE_RESOURCE_GROUP=my-rg \
#     CWAGENT_AZURE_VM_NAME=my-vm \
#       ./azure/setup-identity.sh
#
# Environment variables:
#   Common:
#     CWAGENT_PLATFORM              azure_vm | azure_aks
#     CWAGENT_AZURE_RESOURCE_GROUP  Resource group
#     CWAGENT_EMIT_ENV              When "1", print eval-able KEY='value' lines
#                                   on stdout and route all logging to stderr
#   azure_vm:
#     CWAGENT_AZURE_VM_NAME         VM name
#   azure_aks:
#     CWAGENT_K8S_CLUSTER_NAME      Cluster name

set -eu

PLATFORM="${CWAGENT_PLATFORM:-}"
RESOURCE_GROUP="${CWAGENT_AZURE_RESOURCE_GROUP:-}"
VM_NAME="${CWAGENT_AZURE_VM_NAME:-}"
CLUSTER_NAME="${CWAGENT_K8S_CLUSTER_NAME:-}"
EMIT_ENV="${CWAGENT_EMIT_ENV:-}"

# =============================================================================
# Output helpers
#
# Under CWAGENT_EMIT_ENV stdout is a machine channel the caller captures and
# evaluates, so human output goes to fd 3 (redirected to stderr here, stdout
# otherwise) and every command must keep its own output off plain stdout. A
# stray line that looks like an assignment is indistinguishable from a real one.
# =============================================================================

if [ -n "${EMIT_ENV}" ]; then
     exec 3>&2
else
     exec 3>&1
fi

section() { printf '\n%s\n' "$1" >&3; }
if [ -t 3 ]; then
     log() { printf '  \033[32m✓\033[0m %s\n' "$1" >&3; }
     logaction() { printf '  \033[33m+\033[0m %s\n' "$1" >&3; }
     logwarn() { printf '  \033[33m!\033[0m %s\n' "$1" >&3; }
     die() {
          printf '  \033[31m✗\033[0m %s\n' "$1" >&2
          exit 1
     }
     ask() { printf '\033[1m▸ %s\033[0m ' "$1" >&3; }
else
     log() { printf '  ✓ %s\n' "$1" >&3; }
     logaction() { printf '  + %s\n' "$1" >&3; }
     logwarn() { printf '  ! %s\n' "$1" >&3; }
     die() {
          printf '  ✗ %s\n' "$1" >&2
          exit 1
     }
     ask() { printf '▸ %s ' "$1" >&3; }
fi

usage() {
     cat >&2 <<EOF
Usage:
  $0                    Interactive wizard (TTY)

  Or via environment variables:
  CWAGENT_PLATFORM=azure_vm CWAGENT_AZURE_RESOURCE_GROUP=rg CWAGENT_AZURE_VM_NAME=vm $0

Environment variables:
  Common:
    CWAGENT_PLATFORM              azure_vm | azure_aks
    CWAGENT_AZURE_RESOURCE_GROUP  Resource group
    CWAGENT_EMIT_ENV              Print eval-able KEY='value' lines on stdout
  azure_vm:
    CWAGENT_AZURE_VM_NAME         VM name
  azure_aks:
    CWAGENT_K8S_CLUSTER_NAME      Cluster name
EOF
     exit 1
}

# =============================================================================
# Env-var emit (CWAGENT_EMIT_ENV)
#
# Values are single-quoted for the documented
# eval "$(... | CWAGENT_EMIT_ENV=1 sh)" usage.
# =============================================================================

ENV_VARS=""
add_env() {
     [ -n "$2" ] || return 0
     ENV_VARS="${ENV_VARS}$1=$2
"
}

emit_env() {
     [ -n "${EMIT_ENV}" ] || return 0
     printf '%s' "${ENV_VARS}" | while IFS= read -r line; do
          [ -n "${line}" ] || continue
          printf "%s='%s'\n" "${line%%=*}" "${line#*=}"
     done
}

# =============================================================================
# Interactive mode
# =============================================================================

prompt() {
     var="$1"
     label="$2"
     default="${3:-}"
     eval "current=\${${var}}"
     [ -n "${current}" ] && return
     while true; do
          if [ -n "${default}" ]; then
               ask "${label} [${default}]:"
          else
               ask "${label}:"
          fi
          read -r input
          input="${input:-${default}}"
          [ -n "${input}" ] && break
     done
     eval "${var}=\"${input}\""
}

interactive_setup() {
     printf '\nSelect platform:\n' >&3
     printf '  azure_vm    Azure VM\n' >&3
     printf '  azure_aks   AKS cluster\n' >&3
     ask "Platform:"
     read -r choice
     case "${choice}" in
     azure_vm) PLATFORM=azure_vm ;;
     azure_aks) PLATFORM=azure_aks ;;
     *) die "invalid platform: ${choice}" ;;
     esac

     printf '\n' >&3
     case "${PLATFORM}" in
     azure_vm)
          prompt RESOURCE_GROUP "Resource group"
          prompt VM_NAME "VM name"
          ;;
     azure_aks)
          prompt RESOURCE_GROUP "Resource group"
          prompt CLUSTER_NAME "Cluster name"
          ;;
     esac
}

check_prerequisites() {
     command -v az >/dev/null 2>&1 || die "Azure CLI is required but not installed"
     AZ_CLI_VERSION=$(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo "0.0.0")
     if [ "$(printf '%s\n' "2.47.0" "${AZ_CLI_VERSION}" | sort -V | head -1)" != "2.47.0" ]; then
          logwarn "Azure CLI ${AZ_CLI_VERSION} detected (2.47+ recommended for full functionality)"
     fi
     az account show >/dev/null 2>&1 || die "Azure CLI not logged in (run 'az login')"
     AZ_SUB=$(az account show --query id -o tsv)
     AZ_NAME=$(az account show --query name -o tsv 2>/dev/null || true)
     if [ -n "${AZ_NAME}" ]; then
          log "Azure subscription: ${AZ_SUB} (${AZ_NAME})"
     else
          log "Azure subscription: ${AZ_SUB}"
     fi
}

# =============================================================================
# Azure VM identity
# =============================================================================

identity_azure_vm() {
     if [ -z "${RESOURCE_GROUP}" ] || [ -z "${VM_NAME}" ]; then usage; fi

     section "Configuring Azure VM identity..."

     IDENTITY=$(az vm show \
          --resource-group "${RESOURCE_GROUP}" \
          --name "${VM_NAME}" \
          --query "identity.principalId" -o tsv 2>/dev/null || true)

     if [ -n "${IDENTITY}" ] && [ "${IDENTITY}" != "None" ]; then
          log "Managed identity enabled on ${VM_NAME}"
     else
          logaction "Enabling managed identity (this may take a few minutes)"
          az vm identity assign \
               --resource-group "${RESOURCE_GROUP}" \
               --name "${VM_NAME}" \
               --output none
          log "Managed identity enabled on ${VM_NAME}"
     fi

     TENANT_ID=$(az account show --query tenantId -o tsv)
     log "Tenant: ${TENANT_ID}"

     add_env CWAGENT_PLATFORM "${PLATFORM}"
     add_env CWAGENT_AZURE_TENANT_ID "${TENANT_ID}"
}

# =============================================================================
# Azure AKS identity
# =============================================================================

identity_azure_aks() {
     if [ -z "${RESOURCE_GROUP}" ] || [ -z "${CLUSTER_NAME}" ]; then usage; fi

     section "Configuring AKS cluster..."

     OIDC_ENABLED=$(az aks show \
          --resource-group "${RESOURCE_GROUP}" \
          --name "${CLUSTER_NAME}" \
          --query "oidcIssuerProfile.enabled" -o tsv 2>/dev/null || true)

     if [ "${OIDC_ENABLED}" = "true" ]; then
          log "OIDC issuer and workload identity enabled"
     else
          logaction "Enabling OIDC issuer and workload identity (this may take a few minutes)"
          az aks update \
               --resource-group "${RESOURCE_GROUP}" \
               --name "${CLUSTER_NAME}" \
               --enable-oidc-issuer \
               --enable-workload-identity \
               --output none
     fi

     OIDC_ISSUER=$(az aks show \
          --resource-group "${RESOURCE_GROUP}" \
          --name "${CLUSTER_NAME}" \
          --query "oidcIssuerProfile.issuerUrl" -o tsv)

     log "OIDC issuer: ${OIDC_ISSUER}"

     add_env CWAGENT_PLATFORM "${PLATFORM}"
     add_env CWAGENT_AZURE_OIDC_ISSUER "${OIDC_ISSUER}"
}

main() {
     case "${1:-}" in -h | --help) usage ;; esac

     # Interactive only on a real TTY and never under CWAGENT_EMIT_ENV (the
     # dispatcher eval-chains this script and cannot answer prompts).
     if [ -t 0 ] && [ -z "${EMIT_ENV}" ] && [ -z "${PLATFORM}" ]; then
          interactive_setup
     fi

     case "${PLATFORM}" in
     azure_vm | azure_aks) ;;
     *) die "unsupported platform: ${PLATFORM:-<unset>} (valid: azure_vm, azure_aks)" ;;
     esac

     check_prerequisites

     case "${PLATFORM}" in
     azure_vm) identity_azure_vm ;;
     azure_aks) identity_azure_aks ;;
     esac

     emit_env
}

main "$@"
