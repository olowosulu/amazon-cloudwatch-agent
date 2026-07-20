#!/bin/sh

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT

# Amazon CloudWatch Agent — Azure install
#
# Installs the agent against an existing AWS IAM role:
#
#   azure_vm    pushes install.sh to the VM via "az vm run-command"
#               (requires: az)
#   azure_aks   installs the CloudWatch Observability Helm chart
#               (requires: az, helm, kubectl)
#
# Takes the role ARN and region the AWS trust setup produced; both are required.
#
# Usage:
#     CWAGENT_PLATFORM=azure_aks \
#     CWAGENT_ROLE_ARN=arn:aws:iam::... \
#     CWAGENT_AWS_REGION=us-west-2 \
#     CWAGENT_AZURE_RESOURCE_GROUP=rg \
#     CWAGENT_K8S_CLUSTER_NAME=cluster \
#       ./azure/setup-install.sh
#
# Environment variables:
#   Common:
#     CWAGENT_PLATFORM              azure_vm | azure_aks
#     CWAGENT_ROLE_ARN              IAM role ARN (required)
#     CWAGENT_AWS_REGION            AWS region telemetry is sent to (required)
#     CWAGENT_AZURE_RESOURCE_GROUP  Resource group
#     CWAGENT_SKIP_INSTALL          Skip installation (print command instead)
#   azure_vm:
#     CWAGENT_AZURE_VM_NAME         VM name
#     CWAGENT_INSTALL_URL           Override package/artifact download URL
#   azure_aks:
#     CWAGENT_K8S_CLUSTER_NAME      Cluster name
#     CWAGENT_K8S_NAMESPACE         Namespace (default: amazon-cloudwatch)
#     CWAGENT_HELM_REPO             Override Helm chart repository

set -eu

PLATFORM="${CWAGENT_PLATFORM:-}"
ROLE_ARN="${CWAGENT_ROLE_ARN:-}"
REGION="${CWAGENT_AWS_REGION:-}"
RESOURCE_GROUP="${CWAGENT_AZURE_RESOURCE_GROUP:-}"
VM_NAME="${CWAGENT_AZURE_VM_NAME:-}"
CLUSTER_NAME="${CWAGENT_K8S_CLUSTER_NAME:-}"
NAMESPACE="${CWAGENT_K8S_NAMESPACE:-}"
SKIP_INSTALL="${CWAGENT_SKIP_INSTALL:-}"
INSTALL_URL="${CWAGENT_INSTALL_URL:-}"
HELM_CHART_REPO="${CWAGENT_HELM_REPO:-https://aws-observability.github.io/helm-charts}"

DOWNLOAD_BASE="https://amazoncloudwatch-agent.s3.amazonaws.com"
# Where the VM fetches the install payload (install.sh / install.ps1) from.
SCRIPT_BASE_URL="https://raw.githubusercontent.com/aws/amazon-cloudwatch-agent/setup-scripts/scripts"
CTL="/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl"
CTL_PS1="& \"\${Env:ProgramFiles}\\Amazon\\AmazonCloudWatchAgent\\amazon-cloudwatch-agent-ctl.ps1\""

# =============================================================================
# Output helpers
# =============================================================================

section() { printf '\n%s\n' "$1"; }
if [ -t 1 ]; then
     log() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
     logaction() { printf '  \033[33m+\033[0m %s\n' "$1"; }
     logwarn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
     die() {
          printf '  \033[31m✗\033[0m %s\n' "$1" >&2
          exit 1
     }
     ask() { printf '\033[1m▸ %s\033[0m ' "$1"; }
else
     log() { printf '  ✓ %s\n' "$1"; }
     logaction() { printf '  + %s\n' "$1"; }
     logwarn() { printf '  ! %s\n' "$1"; }
     die() {
          printf '  ✗ %s\n' "$1" >&2
          exit 1
     }
     ask() { printf '▸ %s ' "$1"; }
fi

usage() {
     cat >&2 <<EOF
Usage:
  CWAGENT_PLATFORM=azure_aks CWAGENT_ROLE_ARN=arn:aws:iam::... $0

Environment variables:
  Common:
    CWAGENT_PLATFORM              azure_vm | azure_aks
    CWAGENT_ROLE_ARN              IAM role ARN (required)
    CWAGENT_AWS_REGION            AWS region (required)
    CWAGENT_AZURE_RESOURCE_GROUP  Resource group
    CWAGENT_SKIP_INSTALL          Skip installation (print command instead)
  azure_vm:
    CWAGENT_AZURE_VM_NAME         VM name
  azure_aks:
    CWAGENT_K8S_CLUSTER_NAME      Cluster name
    CWAGENT_K8S_NAMESPACE         Namespace (default: amazon-cloudwatch)
EOF
     exit 1
}

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

check_prerequisites() {
     command -v az >/dev/null 2>&1 || die "Azure CLI is required but not installed"
     az account show >/dev/null 2>&1 || die "Azure CLI not logged in (run 'az login')"

     if [ "${PLATFORM}" = "azure_aks" ] && [ "${SKIP_INSTALL}" != "true" ]; then
          command -v helm >/dev/null 2>&1 || die "Helm is required for AKS installs (or set CWAGENT_SKIP_INSTALL=true)"
          command -v kubectl >/dev/null 2>&1 || die "kubectl is required for AKS installs (or set CWAGENT_SKIP_INSTALL=true)"
     fi
}

# =============================================================================
# Install payload builders (VM path)
# =============================================================================

# Emit the one-line command that fetches install.sh and runs it on a Linux
# target, with the given env assignments as a prefix. $1 = env assignments.
linux_install_cmd() {
     envs="$1"
     printf 'curl -fsSL %s/install.sh | %s sh' "${SCRIPT_BASE_URL}" "${envs}"
}

# Windows counterpart. The prelude + fetch are wrapped into one -EncodedCommand
# base64 payload (UTF-16LE) so the outer command needs no quoting through
# run-command. $1 = PowerShell env prelude (e.g. "$env:CWAGENT_CLOUD='azure'; ")
windows_install_cmd() {
     ps_prelude="$1"
     ps_script="${ps_prelude}Invoke-WebRequest -Uri ${SCRIPT_BASE_URL}/install.ps1 -OutFile \$env:TEMP\\cwagent-install.ps1; & \$env:TEMP\\cwagent-install.ps1"
     encoded=$(printf '%s' "${ps_script}" | iconv -f utf-8 -t utf-16le 2>/dev/null | base64 | tr -d '\n')
     [ -n "${encoded}" ] || return 1
     printf 'powershell -NoProfile -EncodedCommand %s' "${encoded}"
}

# Run a command on an Azure VM via run-command. $1 = command ID
# (RunShellScript | RunPowerShellScript), $2 = command.
run_via_az() {
     az_command_id="$1"
     az_cmd="$2"
     RUN_MESSAGE=""

     logaction "Running install via az vm run-command"
     RUN_RESULT=$(az vm run-command invoke \
          --resource-group "${RESOURCE_GROUP}" \
          --name "${VM_NAME}" \
          --command-id "${az_command_id}" \
          --scripts "${az_cmd}" \
          -o json)

     # run-command returns one of two shapes: older builds emit separate
     # ComponentStatus/StdOut|StdErr entries; current ones return a single entry
     # whose message embeds both as "[stdout]\n...\n\n[stderr]\n...". Try the
     # split entries first, then fall back to splitting the combined message.
     if command -v jq >/dev/null 2>&1; then
          STDOUT=$(printf '%s' "${RUN_RESULT}" | jq -r '.value[] | select(.code == "ComponentStatus/StdOut/succeeded") | .message')
          STDERR=$(printf '%s' "${RUN_RESULT}" | jq -r '.value[] | select(.code == "ComponentStatus/StdErr/succeeded") | .message')
          if [ -z "${STDOUT}" ] && [ -z "${STDERR}" ]; then
               RUN_MESSAGE=$(printf '%s' "${RUN_RESULT}" | jq -r 'first(.value[] | select(.message != null) | .message) // ""')
          fi
     else
          STDOUT=$(printf '%s' "${RUN_RESULT}" | grep -A1 '"ComponentStatus/StdOut/succeeded"' | tail -1 | sed 's/.*"message": "//;s/"$//')
          STDERR=$(printf '%s' "${RUN_RESULT}" | grep -A1 '"ComponentStatus/StdErr/succeeded"' | tail -1 | sed 's/.*"message": "//;s/"$//')
          if [ -z "${STDOUT}" ] && [ -z "${STDERR}" ]; then
               RUN_MESSAGE=$(printf '%s' "${RUN_RESULT}" | grep '"message":' | head -1 | sed 's/.*"message": "//;s/"$//')
               # Turn the JSON-escaped newlines back into real ones so the split works.
               RUN_MESSAGE=$(printf '%b' "${RUN_MESSAGE}")
          fi
     fi

     if [ -n "${RUN_MESSAGE:-}" ]; then
          STDOUT=$(printf '%s' "${RUN_MESSAGE}" | sed -n '/^\[stdout\]$/,/^\[stderr\]$/p' | sed '1d;$d')
          STDERR=$(printf '%s' "${RUN_MESSAGE}" | sed -n '/^\[stderr\]$/,$p' | sed '1d')
     fi

     # run-command masks the exit code and the agent logs benign errors to
     # stderr, so key success off the install script's stdout sentinel (printed
     # only after it asserts the agent is running). Show stdout either way; add
     # the stderr transcript only on failure, for diagnosis.
     if [ -n "${STDOUT}" ]; then printf '%s\n' "${STDOUT}"; fi

     if ! printf '%s' "${STDOUT}" | grep -q 'Amazon CloudWatch Agent installed and running\.'; then
          [ -n "${STDERR}" ] && printf '%s\n' "${STDERR}" >&2
          die "Install script failed on ${VM_NAME}"
     fi
}

# Print manual install instructions for a Linux VM.
print_linux_install() {
     if [ -n "${INSTALL_URL}" ]; then
          echo "  # Download and install the agent package:"
          echo "  curl -fsSL '${INSTALL_URL}' -o /tmp/\$(basename '${INSTALL_URL}')"
          case "${INSTALL_URL}" in
          *.rpm) echo "  sudo rpm -Uvh /tmp/\$(basename '${INSTALL_URL}')" ;;
          *.deb) echo "  sudo dpkg -i /tmp/\$(basename '${INSTALL_URL}')" ;;
          *) echo "  # Install the downloaded artifact for this distribution" ;;
          esac
     else
          echo "  # Amazon Linux / RHEL:"
          echo "  sudo rpm -Uvh ${DOWNLOAD_BASE}/amazon_linux/\$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')/latest/amazon-cloudwatch-agent.rpm"
          echo ""
          echo "  # Ubuntu / Debian:"
          echo "  curl -fsSL ${DOWNLOAD_BASE}/ubuntu/\$(dpkg --print-architecture)/latest/amazon-cloudwatch-agent.deb -o /tmp/amazon-cloudwatch-agent.deb"
          echo "  sudo dpkg -i /tmp/amazon-cloudwatch-agent.deb"
     fi
}

print_windows_install() {
     if [ -n "${INSTALL_URL}" ]; then
          echo "  # Download and install the agent package:"
          echo "  Invoke-WebRequest -Uri '${INSTALL_URL}' -OutFile \$env:TEMP\\amazon-cloudwatch-agent.msi"
          echo "  msiexec /i \$env:TEMP\\amazon-cloudwatch-agent.msi"
     else
          echo "  Invoke-WebRequest -Uri ${DOWNLOAD_BASE}/windows/amd64/latest/amazon-cloudwatch-agent.msi -OutFile \$env:TEMP\\amazon-cloudwatch-agent.msi"
          echo "  msiexec /i \$env:TEMP\\amazon-cloudwatch-agent.msi"
     fi
}

# =============================================================================
# Azure VM install
# =============================================================================

install_azure_vm() {
     if [ -z "${RESOURCE_GROUP}" ] || [ -z "${VM_NAME}" ]; then usage; fi

     VM_OS=$(az vm show \
          --resource-group "${RESOURCE_GROUP}" \
          --name "${VM_NAME}" \
          --query "storageProfile.osDisk.osType" -o tsv 2>/dev/null || true)

     if [ "${SKIP_INSTALL}" != "true" ]; then
          section "Installing agent on ${VM_NAME}..."
          if [ "${VM_OS}" = "Windows" ]; then
               ps_prelude="\$env:CWAGENT_CLOUD='azure'; \$env:CWAGENT_ROLE_ARN='${ROLE_ARN}'; \$env:CWAGENT_AWS_REGION='${REGION}'; "
               [ -n "${INSTALL_URL}" ] && ps_prelude="${ps_prelude}\$env:CWAGENT_INSTALL_URL='${INSTALL_URL}'; "
               if INSTALL_CMD=$(windows_install_cmd "${ps_prelude}"); then
                    run_via_az "RunPowerShellScript" "${INSTALL_CMD}"
                    log "Agent installed on ${VM_NAME}"
                    return
               fi
          else
               install_env="CWAGENT_CLOUD=azure CWAGENT_ROLE_ARN=${ROLE_ARN} CWAGENT_AWS_REGION=${REGION}"
               [ -n "${INSTALL_URL}" ] && install_env="${install_env} CWAGENT_INSTALL_URL=${INSTALL_URL}"
               if INSTALL_CMD=$(linux_install_cmd "${install_env}"); then
                    run_via_az "RunShellScript" "${INSTALL_CMD}"
                    log "Agent installed on ${VM_NAME}"
                    return
               fi
          fi
          logwarn "could not build the install command (iconv is required for Windows targets)"
     fi

     echo ""
     echo "Done. Run the following on ${VM_NAME} to install and start the agent:"
     echo ""
     if [ "${VM_OS}" = "Windows" ]; then
          print_windows_install
          echo ""
          echo "  # Configure credentials and region, then start with the default OpenTelemetry config:"
          echo "  ${CTL_PS1} -Action set-env -EnvVar CWAGENT_ROLE_ARN=${ROLE_ARN}"
          echo "  ${CTL_PS1} -Action set-env -EnvVar AWS_REGION=${REGION}"
          echo "  ${CTL_PS1} -Action fetch-config -Mode auto -ConfigLocation default:otel -Start"
     else
          print_linux_install
          echo ""
          echo "  # Configure credentials and region, then start with the default OpenTelemetry config:"
          echo "  sudo ${CTL} -a set-env -e CWAGENT_ROLE_ARN=${ROLE_ARN}"
          echo "  sudo ${CTL} -a set-env -e AWS_REGION=${REGION}"
          echo "  sudo ${CTL} -a fetch-config -m auto -c default:otel -s"
     fi
}

# =============================================================================
# Azure AKS install
# =============================================================================

install_azure_aks() {
     if [ -z "${RESOURCE_GROUP}" ] || [ -z "${CLUSTER_NAME}" ]; then usage; fi

     NAMESPACE="${NAMESPACE:-amazon-cloudwatch}"

     if [ "${SKIP_INSTALL}" != "true" ]; then
          section "Installing CloudWatch Observability Helm chart on ${CLUSTER_NAME}..."
          logaction "Configuring kubeconfig for ${CLUSTER_NAME}"
          az aks get-credentials --resource-group "${RESOURCE_GROUP}" --name "${CLUSTER_NAME}" --overwrite-existing

          logaction "Installing via Helm"
          helm repo add aws-observability "${HELM_CHART_REPO}" 2>/dev/null || true
          helm repo update aws-observability
          helm upgrade --install amazon-cloudwatch-observability aws-observability/amazon-cloudwatch-observability \
               --set k8sMode=AKS \
               --set roleArn="${ROLE_ARN}" \
               --set region="${REGION}" \
               --set clusterName="${CLUSTER_NAME}" \
               --set-string 'agents[0].config=default:otel' \
               --namespace "${NAMESPACE}" \
               --create-namespace
          log "Chart installed on ${CLUSTER_NAME}"
     else
          echo ""
          echo "Done. Install the Amazon CloudWatch Observability Helm chart (requires kubeconfig for ${CLUSTER_NAME}):"
          echo ""
          echo "  helm repo add aws-observability ${HELM_CHART_REPO}"
          echo "  helm repo update aws-observability"
          printf '  helm upgrade --install amazon-cloudwatch-observability aws-observability/amazon-cloudwatch-observability \\\n'
          printf '    --set k8sMode=AKS \\\n'
          printf '    --set roleArn=%s \\\n' "${ROLE_ARN}"
          printf '    --set region=%s \\\n' "${REGION}"
          printf '    --set clusterName=%s \\\n' "${CLUSTER_NAME}"
          printf "    --set-string 'agents[0].config=default:otel' \\\\\n"
          printf '    --namespace %s \\\n' "${NAMESPACE}"
          printf '    --create-namespace\n'
     fi
}

main() {
     case "${1:-}" in -h | --help) usage ;; esac

     if [ -t 0 ] && [ -z "${PLATFORM}" ]; then
          ask "Platform (azure_vm | azure_aks):"
          read -r PLATFORM
     fi

     case "${PLATFORM}" in
     azure_vm | azure_aks) ;;
     *) die "unsupported platform: ${PLATFORM:-<unset>} (valid: azure_vm, azure_aks)" ;;
     esac

     # ROLE_ARN and region are required env vars and cannot be entered by hand.
     [ -n "${ROLE_ARN}" ] || die "CWAGENT_ROLE_ARN is required (produced by aws/setup-trust.sh)"
     [ -n "${REGION}" ] || die "CWAGENT_AWS_REGION is required (produced by aws/setup-trust.sh)"

     # Prompt for any remaining inputs when interactive.
     if [ -t 0 ]; then
          case "${PLATFORM}" in
          azure_vm)
               prompt RESOURCE_GROUP "Resource group"
               prompt VM_NAME "VM name"
               ;;
          azure_aks)
               prompt RESOURCE_GROUP "Resource group"
               prompt CLUSTER_NAME "Cluster name"
               prompt NAMESPACE "Namespace" "amazon-cloudwatch"
               ;;
          esac
     fi

     check_prerequisites

     case "${PLATFORM}" in
     azure_vm) install_azure_vm ;;
     azure_aks) install_azure_aks ;;
     esac
}

main "$@"
