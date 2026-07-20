#!/bin/sh

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT

# Amazon CloudWatch Agent — onboarding setup (dispatcher)
#
# Optional convenience wrapper over the standalone setup scripts, which document
# their own inputs and can be run directly instead. This one picks the platform
# and runs them in order:
#
#   aws_ec2 / aws_ecs / aws_eks
#       aws/setup-trust.sh -> aws/setup-install.sh
#   azure_vm / azure_aks
#       azure/setup-identity.sh -> aws/setup-trust.sh -> azure/setup-install.sh
#
# The AWS-native platforms run wholly in one AWS shell. The Azure platforms span
# clouds: identity and install need the Azure CLI, trust needs the AWS CLI. In a
# shell with every CLI this runs the whole chain; otherwise it runs the phases
# this shell can and prints a command to paste into the next shell, carrying the
# values each phase produced.
#
# The phase scripts are always fetched over the network, never read from
# alongside this file, so this needs "curl" and outbound access even when run
# from a local copy. CWAGENT_SCRIPT_BASE_URL overrides where they come from.
#
# Usage:
#   ./setup.sh                          Interactive wizard (TTY)
#   CWAGENT_PLATFORM=aws_ec2 CWAGENT_AWS_INSTANCE_ID=i-123 ./setup.sh
#
# Environment variables:
#   CWAGENT_PLATFORM                      aws_ec2 | aws_ecs | aws_eks | azure_vm | azure_aks
#   CWAGENT_IAM_ROLE_NAME                 IAM role name (default: CloudWatchAgentServerRole)
#   CWAGENT_AWS_REGION                    AWS region telemetry is sent to
#   CWAGENT_AWS_ENABLE_TRANSACTION_SEARCH When "true", enable Transaction Search
#                                         if it is off
#   CWAGENT_SKIP_INSTALL                  Skip installation (print command instead)
#   CWAGENT_INSTALL_URL                   Override package/artifact download URL
#   CWAGENT_SCRIPT_BASE_URL               URL hosting the setup scripts (for the
#                                         curl-piped path and the paste commands)
#   CWAGENT_HELM_REPO                     Override Helm chart repository
#   CWAGENT_IMAGE                         Override container image (ECS)
#
#   EC2:
#   CWAGENT_AWS_INSTANCE_ID               EC2 instance ID
#   CWAGENT_AWS_UPDATE_INSTANCE_ROLE      When "true", attach the policy to the
#                                         role already on the instance
#
#   ECS:
#   CWAGENT_AWS_ECS_LAUNCH_TYPE           fargate | ec2
#
#   Azure:
#   CWAGENT_AZURE_RESOURCE_GROUP          Resource group
#   CWAGENT_AZURE_VM_NAME                 VM name (azure_vm only)
#
#   Kubernetes (EKS, AKS):
#   CWAGENT_K8S_CLUSTER_NAME              Cluster name
#   CWAGENT_K8S_NAMESPACE                 Namespace (default: amazon-cloudwatch)

set -eu

PLATFORM="${CWAGENT_PLATFORM:-}"
ROLE_NAME="${CWAGENT_IAM_ROLE_NAME:-CloudWatchAgentServerRole}"
REGION="${CWAGENT_AWS_REGION:-}"
NAMESPACE="${CWAGENT_K8S_NAMESPACE:-}"
INSTANCE_ID="${CWAGENT_AWS_INSTANCE_ID:-}"
UPDATE_INSTANCE_ROLE="${CWAGENT_AWS_UPDATE_INSTANCE_ROLE:-}"
ENABLE_TXN_SEARCH="${CWAGENT_AWS_ENABLE_TRANSACTION_SEARCH:-}"
CLUSTER_NAME="${CWAGENT_K8S_CLUSTER_NAME:-}"
RESOURCE_GROUP="${CWAGENT_AZURE_RESOURCE_GROUP:-}"
VM_NAME="${CWAGENT_AZURE_VM_NAME:-}"
ECS_LAUNCH_TYPE="${CWAGENT_AWS_ECS_LAUNCH_TYPE:-}"
SKIP_INSTALL="${CWAGENT_SKIP_INSTALL:-}"
INSTALL_URL="${CWAGENT_INSTALL_URL:-}"
HELM_REPO="${CWAGENT_HELM_REPO:-}"
IMAGE="${CWAGENT_IMAGE:-}"
# Identity/trust values that cross the phase boundaries. On a resumed shell they
# arrive via the paste command; otherwise the phases below produce them.
TENANT_ID="${CWAGENT_AZURE_TENANT_ID:-}"
OIDC_ISSUER="${CWAGENT_AZURE_OIDC_ISSUER:-}"
ROLE_ARN="${CWAGENT_ROLE_ARN:-}"

# Where the phase scripts are fetched from and what the paste commands point at.
DEFAULT_BASE_URL="https://raw.githubusercontent.com/aws/amazon-cloudwatch-agent/setup-scripts/scripts"
BASE_URL="${CWAGENT_SCRIPT_BASE_URL:-${DEFAULT_BASE_URL}}"

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
  $0                    Interactive wizard (TTY)

  Or via environment variables:
  CWAGENT_PLATFORM=aws_ec2 CWAGENT_AWS_INSTANCE_ID=i-123 $0

Environment variables:
  CWAGENT_PLATFORM                        aws_ec2 | aws_ecs | aws_eks | azure_vm | azure_aks
  CWAGENT_IAM_ROLE_NAME                   IAM role name (default: CloudWatchAgentServerRole)
  CWAGENT_AWS_REGION                      AWS region telemetry is sent to
  CWAGENT_AWS_ENABLE_TRANSACTION_SEARCH   Enable Transaction Search in the region
  CWAGENT_SKIP_INSTALL                    Skip installation (print command instead)
  CWAGENT_INSTALL_URL                     Override package/artifact download URL
  CWAGENT_SCRIPT_BASE_URL                 URL hosting the setup scripts
  CWAGENT_HELM_REPO                       Override Helm chart repository
  CWAGENT_IMAGE                           Override container image (ECS)

  EC2:
  CWAGENT_AWS_INSTANCE_ID                 EC2 instance ID
  CWAGENT_AWS_UPDATE_INSTANCE_ROLE        Attach the policy to the existing role

  ECS:
  CWAGENT_AWS_ECS_LAUNCH_TYPE             fargate | ec2

  Azure:
  CWAGENT_AZURE_RESOURCE_GROUP            Resource group
  CWAGENT_AZURE_VM_NAME                   VM name (azure_vm only)

  Kubernetes (EKS, AKS):
  CWAGENT_K8S_CLUSTER_NAME                Cluster name
  CWAGENT_K8S_NAMESPACE                   Namespace (default: amazon-cloudwatch)
EOF
     exit 1
}

# =============================================================================
# Interactive wizard
#
# Collects the platform and its inputs up front so the phase scripts can run
# non-interactively (they are invoked with the values already in the
# environment, and under CWAGENT_EMIT_ENV they cannot prompt at all).
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
     if [ -z "${PLATFORM}" ]; then
          printf '\nSelect platform:\n'
          printf '  aws_ec2     EC2 instance\n'
          printf '  aws_ecs     ECS task (sidecar)\n'
          printf '  aws_eks     EKS cluster (Helm)\n'
          printf '  azure_vm    Azure VM\n'
          printf '  azure_aks   AKS cluster (Helm)\n'
          ask "Platform:"
          read -r PLATFORM
     fi

     printf '\n'
     case "${PLATFORM}" in
     aws_ec2) prompt INSTANCE_ID "Instance ID" ;;
     aws_ecs) prompt ECS_LAUNCH_TYPE "Launch type (fargate|ec2)" "fargate" ;;
     aws_eks)
          prompt CLUSTER_NAME "Cluster name"
          prompt NAMESPACE "Namespace" "amazon-cloudwatch"
          ;;
     azure_vm)
          prompt RESOURCE_GROUP "Resource group"
          prompt VM_NAME "VM name"
          ;;
     azure_aks)
          prompt RESOURCE_GROUP "Resource group"
          prompt CLUSTER_NAME "Cluster name"
          prompt NAMESPACE "Namespace" "amazon-cloudwatch"
          ;;
     *) die "invalid platform: ${PLATFORM}" ;;
     esac

     # Region is where telemetry lands. Offer the AWS CLI default when present.
     if [ -z "${REGION}" ] && have_aws; then
          REGION=$(aws configure get region 2>/dev/null || true)
     fi
     prompt REGION "AWS region telemetry is sent to" "${REGION}"
     prompt ROLE_NAME "IAM role name" "${ROLE_NAME}"
}

# =============================================================================
# Phase runners
# =============================================================================

have_az() { command -v az >/dev/null 2>&1; }
have_aws() { command -v aws >/dev/null 2>&1; }

# Export everything the phase scripts read, so a plain "sh <phase>" inherits it.
# Empty values are harmless: the phases fall back to their own defaults.
export_env() {
     export CWAGENT_PLATFORM="${PLATFORM}"
     export CWAGENT_IAM_ROLE_NAME="${ROLE_NAME}"
     export CWAGENT_AWS_REGION="${REGION}"
     export CWAGENT_K8S_NAMESPACE="${NAMESPACE}"
     export CWAGENT_AWS_INSTANCE_ID="${INSTANCE_ID}"
     export CWAGENT_AWS_UPDATE_INSTANCE_ROLE="${UPDATE_INSTANCE_ROLE}"
     export CWAGENT_AWS_ENABLE_TRANSACTION_SEARCH="${ENABLE_TXN_SEARCH}"
     export CWAGENT_K8S_CLUSTER_NAME="${CLUSTER_NAME}"
     export CWAGENT_AZURE_RESOURCE_GROUP="${RESOURCE_GROUP}"
     export CWAGENT_AZURE_VM_NAME="${VM_NAME}"
     export CWAGENT_AWS_ECS_LAUNCH_TYPE="${ECS_LAUNCH_TYPE}"
     export CWAGENT_SKIP_INSTALL="${SKIP_INSTALL}"
     export CWAGENT_INSTALL_URL="${INSTALL_URL}"
     export CWAGENT_HELM_REPO="${HELM_REPO}"
     export CWAGENT_IMAGE="${IMAGE}"
     export CWAGENT_AZURE_TENANT_ID="${TENANT_ID}"
     export CWAGENT_AZURE_OIDC_ISSUER="${OIDC_ISSUER}"
     export CWAGENT_ROLE_ARN="${ROLE_ARN}"
}

# Fetch a hosted phase script to stdout, failing loudly if it cannot be had.
# Piping curl straight into sh would hide the download error: the pipeline takes
# sh's status, and sh reading empty stdin exits 0, so a 404 looks like a phase
# that ran and did nothing.
fetch_phase() {
     rel="$1"
     command -v curl >/dev/null 2>&1 || die "curl is required to fetch ${rel}"
     curl -fsSL "${BASE_URL}/${rel}" || die "could not fetch ${BASE_URL}/${rel}"
}

# Run a phase script for its human output. CWAGENT_EMIT_ENV is unset so its
# progress prints normally.
run_phase() {
     rel="$1"
     export_env
     fetch_phase "${rel}" | CWAGENT_EMIT_ENV='' sh
}

# The only keys a phase is allowed to hand back. Deliberately excludes anything
# that selects code or artifacts to fetch and run: CWAGENT_SCRIPT_BASE_URL (where
# later phases come from), CWAGENT_INSTALL_URL (what gets installed on the
# target), CWAGENT_HELM_REPO and CWAGENT_IMAGE. Those are the operator's choice,
# set once in this shell, and a phase that could rewrite them would be
# redirecting later downloads.
PHASE_OUTPUT_KEYS="CWAGENT_PLATFORM
CWAGENT_AZURE_TENANT_ID
CWAGENT_AZURE_OIDC_ISSUER
CWAGENT_ROLE_ARN
CWAGENT_AWS_REGION
CWAGENT_AWS_INSTANCE_ID
CWAGENT_K8S_CLUSTER_NAME
CWAGENT_K8S_NAMESPACE"

# Run a phase under CWAGENT_EMIT_ENV and fold its emitted CWAGENT_* values back
# into this shell, so the next phase and any paste command pick them up. The
# phase routes its own logging to stderr, so progress is still visible.
load_phase() {
     rel="$1"
     export_env
     emitted=$(fetch_phase "${rel}" | CWAGENT_EMIT_ENV=1 sh)
     # Everything a phase writes to stdout arrives here as untrusted input, so
     # accept only the expected keys in the documented KEY='value' form. An
     # unfiltered eval would let a stray line redefine PATH or a download URL,
     # and on an empty emit it would run a bare "export" that prints the whole
     # environment. Unrecognized lines are dropped silently, since a phase may
     # emit keys this step does not consume.
     for phase_key in ${PHASE_OUTPUT_KEYS}; do
          safe_line=$(printf '%s\n' "${emitted}" | grep -E "^${phase_key}='[^']*'\$" | tail -1 || true)
          [ -n "${safe_line}" ] || continue
          eval "export ${safe_line}"
     done
     TENANT_ID="${CWAGENT_AZURE_TENANT_ID:-${TENANT_ID}}"
     OIDC_ISSUER="${CWAGENT_AZURE_OIDC_ISSUER:-${OIDC_ISSUER}}"
     ROLE_ARN="${CWAGENT_ROLE_ARN:-${ROLE_ARN}}"
     CLUSTER_NAME="${CWAGENT_K8S_CLUSTER_NAME:-${CLUSTER_NAME}}"
     NAMESPACE="${CWAGENT_K8S_NAMESPACE:-${NAMESPACE}}"
     REGION="${CWAGENT_AWS_REGION:-${REGION}}"
}

# Assert a phase produced the value the next one needs. A phase that failed to
# fetch or died early still lets the chain continue otherwise, and the symptom
# surfaces later as a resume command silently missing a key.
require_phase_output() {
     [ -n "$2" ] || die "$1 did not produce $3 — rerun it, or check CWAGENT_SCRIPT_BASE_URL"
}

# The identity phase yields the tenant ID for a VM and the OIDC issuer for AKS.
require_identity_output() {
     case "${PLATFORM}" in
     azure_vm) require_phase_output "azure/setup-identity.sh" "${TENANT_ID}" "a tenant ID" ;;
     azure_aks) require_phase_output "azure/setup-identity.sh" "${OIDC_ISSUER}" "an OIDC issuer URL" ;;
     esac
}

# Print the command to re-run this script in the next shell. Over-includes the
# known values: this script re-derives which phase to run from which are set, so
# a superset is harmless and keeps the paste one self-contained block.
print_resume() {
     hint="$1"
     block=""
     add_kv() {
          [ -n "$2" ] || return 0
          block="${block}      $1='$2' \\
"
     }
     add_kv CWAGENT_PLATFORM "${PLATFORM}"
     add_kv CWAGENT_AZURE_TENANT_ID "${TENANT_ID}"
     add_kv CWAGENT_AZURE_OIDC_ISSUER "${OIDC_ISSUER}"
     add_kv CWAGENT_ROLE_ARN "${ROLE_ARN}"
     add_kv CWAGENT_AZURE_RESOURCE_GROUP "${RESOURCE_GROUP}"
     add_kv CWAGENT_AZURE_VM_NAME "${VM_NAME}"
     add_kv CWAGENT_K8S_CLUSTER_NAME "${CLUSTER_NAME}"
     add_kv CWAGENT_K8S_NAMESPACE "${NAMESPACE}"
     add_kv CWAGENT_AWS_REGION "${REGION}"
     [ "${ROLE_NAME}" = "CloudWatchAgentServerRole" ] || add_kv CWAGENT_IAM_ROLE_NAME "${ROLE_NAME}"
     [ "${BASE_URL}" = "${DEFAULT_BASE_URL}" ] || add_kv CWAGENT_SCRIPT_BASE_URL "${BASE_URL}"

     printf '\nNext: run this in %s\n\n' "${hint}"
     # Strip the first line's indent so the pipe aligns with it: the paste reads
     # "curl ... \ | KEY='v' \ <indented KEYs> \ sh".
     printf '  curl -fsSL %s/setup.sh \\\n    | %s      sh\n' "${BASE_URL}" "${block#      }"
}

# =============================================================================
# Orchestration
# =============================================================================

# AWS-native platforms run entirely in one AWS shell: trust then install, both
# reading the same environment (install re-derives the role ARN from its name).
orchestrate_aws() {
     have_aws || die "AWS CLI is required for ${PLATFORM} (run in a shell that has it, e.g. AWS CloudShell)"
     run_phase aws/setup-trust.sh
     run_phase aws/setup-install.sh
}

# Azure platforms span clouds. identity_done / trust_done are read off the
# values already in the environment, so each shell resumes at the right phase.
orchestrate_azure() {
     case "${PLATFORM}" in
     azure_vm) [ -n "${TENANT_ID}" ] && identity_done=1 || identity_done="" ;;
     azure_aks) [ -n "${OIDC_ISSUER}" ] && identity_done=1 || identity_done="" ;;
     esac
     [ -n "${ROLE_ARN}" ] && trust_done=1 || trust_done=""

     if have_az && have_aws; then
          # One shell with both CLIs: run the whole chain.
          if [ -z "${identity_done}" ]; then
               load_phase azure/setup-identity.sh
               require_identity_output
          fi
          if [ -z "${trust_done}" ]; then
               load_phase aws/setup-trust.sh
               require_phase_output "aws/setup-trust.sh" "${ROLE_ARN}" "an IAM role ARN"
          fi
          run_phase azure/setup-install.sh
     elif have_aws; then
          # AWS shell: only the trust phase belongs here.
          [ -n "${identity_done}" ] || die "run azure/setup-identity.sh in Azure Cloud Shell first (it produces the tenant ID / OIDC issuer this phase needs)"
          if [ -z "${trust_done}" ]; then
               load_phase aws/setup-trust.sh
               require_phase_output "aws/setup-trust.sh" "${ROLE_ARN}" "an IAM role ARN"
          fi
          print_resume "Azure Cloud Shell (has the Azure CLI)"
     elif have_az; then
          # Azure shell: run identity if pending, install once trust is done.
          if [ -z "${identity_done}" ]; then
               load_phase azure/setup-identity.sh
               require_identity_output
               print_resume "AWS CloudShell (has the AWS CLI)"
          elif [ -n "${trust_done}" ]; then
               run_phase azure/setup-install.sh
          else
               print_resume "AWS CloudShell (has the AWS CLI)"
          fi
     else
          die "need the Azure CLI (identity/install) and/or the AWS CLI (trust) for ${PLATFORM}"
     fi
}

main() {
     case "${1:-}" in -h | --help) usage ;; esac

     if [ -t 0 ] && [ -z "${PLATFORM}" ]; then
          interactive_setup
     elif [ -z "${PLATFORM}" ]; then
          usage
     fi

     case "${PLATFORM}" in
     aws_ec2 | aws_ecs | aws_eks) orchestrate_aws ;;
     azure_vm | azure_aks) orchestrate_azure ;;
     *) die "unsupported platform: ${PLATFORM} (valid: aws_ec2, aws_ecs, aws_eks, azure_vm, azure_aks)" ;;
     esac
}

main "$@"
