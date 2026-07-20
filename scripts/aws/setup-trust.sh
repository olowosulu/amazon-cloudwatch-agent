#!/bin/sh

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT

# Amazon CloudWatch Agent — AWS trust setup
#
# Sets up the IAM role the agent assumes to send OpenTelemetry (OTLP) telemetry
# to CloudWatch, and attaches CloudWatchAgentServerPolicy to it. What identifies
# the agent to that role differs by platform:
#
#   aws_ec2     instance profile on the instance, existing one reused if present
#   aws_ecs     ECS task role (ecs-tasks.amazonaws.com)
#   aws_eks     EKS Pod Identity: pod-identity-agent addon + association
#   azure_vm    web-identity trust for the Azure tenant OIDC provider
#   azure_aks   web-identity trust for the AKS issuer OIDC provider
#
# OTLP traces also need Transaction Search, a per-region setting covering the
# whole account. This only reports when it is off, unless
# CWAGENT_AWS_ENABLE_TRANSACTION_SEARCH opts in to enabling it.
#
# Nothing existing is replaced, so this is safe to re-run: a role keeps its other
# trust statements and policies, and an instance keeps its instance profile.
# Attaching the policy to a role that was already on the instance is the one
# change to something the caller owns, so it needs CWAGENT_AWS_UPDATE_INSTANCE_ROLE.
#
# Requires IAM write access, "aws", and "jq". For azure_vm and azure_aks it also
# takes an identity value from the Azure setup (the tenant ID or the OIDC issuer
# URL). Outputs the role ARN.
#
# Usage:
#     CWAGENT_PLATFORM=aws_eks \
#     CWAGENT_K8S_CLUSTER_NAME=my-cluster \
#     CWAGENT_AWS_REGION=us-west-2 \
#       ./aws/setup-trust.sh
#
# Environment variables:
#   Common:
#     CWAGENT_PLATFORM                        aws_ec2 | aws_ecs | aws_eks | azure_vm | azure_aks
#     CWAGENT_IAM_ROLE_NAME                   IAM role name (default: CloudWatchAgentServerRole)
#     CWAGENT_AWS_REGION                      AWS region telemetry is sent to (required;
#                                             falls back to the AWS CLI config if unset)
#     CWAGENT_EMIT_ENV                        When "1", print eval-able KEY='value' lines
#                                             on stdout and route all logging to stderr
#     CWAGENT_AWS_ENABLE_TRANSACTION_SEARCH   When "true", enable Transaction Search
#                                             if it is off
#   aws_ec2:
#     CWAGENT_AWS_INSTANCE_ID                 EC2 instance ID
#     CWAGENT_AWS_UPDATE_INSTANCE_ROLE        When "true", attach the policy to the
#                                             role already on the instance
#   aws_eks:
#     CWAGENT_K8S_CLUSTER_NAME                Cluster name
#     CWAGENT_K8S_NAMESPACE                   Namespace (default: amazon-cloudwatch)
#   azure_vm:
#     CWAGENT_AZURE_TENANT_ID                 Azure tenant ID
#   azure_aks:
#     CWAGENT_AZURE_OIDC_ISSUER               AKS OIDC issuer URL
#     CWAGENT_K8S_NAMESPACE                   Namespace (default: amazon-cloudwatch)

set -eu

PLATFORM="${CWAGENT_PLATFORM:-}"
TENANT_ID="${CWAGENT_AZURE_TENANT_ID:-}"
OIDC_ISSUER="${CWAGENT_AZURE_OIDC_ISSUER:-}"
NAMESPACE="${CWAGENT_K8S_NAMESPACE:-}"
INSTANCE_ID="${CWAGENT_AWS_INSTANCE_ID:-}"
UPDATE_INSTANCE_ROLE="${CWAGENT_AWS_UPDATE_INSTANCE_ROLE:-}"
ENABLE_TXN_SEARCH="${CWAGENT_AWS_ENABLE_TRANSACTION_SEARCH:-}"
CLUSTER_NAME="${CWAGENT_K8S_CLUSTER_NAME:-}"
ROLE_NAME="${CWAGENT_IAM_ROLE_NAME:-CloudWatchAgentServerRole}"
REGION="${CWAGENT_AWS_REGION:-}"
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
  CWAGENT_PLATFORM=aws_eks   CWAGENT_K8S_CLUSTER_NAME=<cluster>  $0
  CWAGENT_PLATFORM=aws_ec2   CWAGENT_AWS_INSTANCE_ID=i-123       $0
  CWAGENT_PLATFORM=azure_aks CWAGENT_AZURE_OIDC_ISSUER=https://... $0
  CWAGENT_PLATFORM=azure_vm  CWAGENT_AZURE_TENANT_ID=<tenant>    $0

Environment variables:
  Common:
    CWAGENT_PLATFORM                        aws_ec2 | aws_ecs | aws_eks | azure_vm | azure_aks
    CWAGENT_IAM_ROLE_NAME                   IAM role name (default: CloudWatchAgentServerRole)
    CWAGENT_AWS_REGION                      AWS region telemetry is sent to (required)
    CWAGENT_EMIT_ENV                        Print eval-able KEY='value' lines on stdout
    CWAGENT_AWS_ENABLE_TRANSACTION_SEARCH   Enable Transaction Search in the region
  aws_ec2:
    CWAGENT_AWS_INSTANCE_ID                 EC2 instance ID
    CWAGENT_AWS_UPDATE_INSTANCE_ROLE        Attach the policy to the existing role
  aws_eks:
    CWAGENT_K8S_CLUSTER_NAME                Cluster name
    CWAGENT_K8S_NAMESPACE                   Namespace (default: amazon-cloudwatch)
  azure_vm:
    CWAGENT_AZURE_TENANT_ID                 Azure tenant ID
  azure_aks:
    CWAGENT_AZURE_OIDC_ISSUER               AKS OIDC issuer URL
    CWAGENT_K8S_NAMESPACE                   Namespace (default: amazon-cloudwatch)
EOF
     exit 1
}

# =============================================================================
# Env-var emit (CWAGENT_EMIT_ENV)
#
# add_env accumulates output values; emit_env prints them as eval-able KEY='value'
# lines on stdout, only under CWAGENT_EMIT_ENV. In the human path they are logged
# instead. Values are single-quoted for the documented
# eval "$(... | CWAGENT_EMIT_ENV=1 sh)" usage; empty values are dropped.
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
#
# The identity values (tenant ID, OIDC issuer) come from the Azure identity
# setup. When run by hand they can be pasted in at the prompts rather than
# passed through the environment.
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
     printf '  aws_ec2     EC2 instance\n' >&3
     printf '  aws_ecs     ECS task (sidecar)\n' >&3
     printf '  aws_eks     EKS cluster\n' >&3
     printf '  azure_vm    Azure VM\n' >&3
     printf '  azure_aks   AKS cluster\n' >&3
     ask "Platform:"
     read -r choice
     case "${choice}" in
     aws_ec2) PLATFORM=aws_ec2 ;;
     aws_ecs) PLATFORM=aws_ecs ;;
     aws_eks) PLATFORM=aws_eks ;;
     azure_vm) PLATFORM=azure_vm ;;
     azure_aks) PLATFORM=azure_aks ;;
     *) die "invalid platform: ${choice}" ;;
     esac

     printf '\n' >&3
     case "${PLATFORM}" in
     aws_ec2)
          prompt INSTANCE_ID "Instance ID"
          ;;
     aws_eks)
          prompt CLUSTER_NAME "Cluster name"
          prompt NAMESPACE "Namespace" "amazon-cloudwatch"
          ;;
     azure_vm)
          prompt TENANT_ID "Azure tenant ID"
          ;;
     azure_aks)
          prompt OIDC_ISSUER "AKS OIDC issuer URL"
          prompt NAMESPACE "Namespace" "amazon-cloudwatch"
          ;;
     esac
     prompt ROLE_NAME "IAM role name" "${ROLE_NAME}"
}

check_prerequisites() {
     command -v aws >/dev/null 2>&1 || die "AWS CLI is required but not installed"
     command -v jq >/dev/null 2>&1 || die "jq is required but not installed"
     AWS_CLI_VERSION=$(aws --version 2>&1 | grep -o 'aws-cli/[0-9.]*' | cut -d/ -f2)
     if [ "$(printf '%s\n' "2.22.0" "${AWS_CLI_VERSION}" | sort -V | head -1)" != "2.22.0" ]; then
          logwarn "AWS CLI ${AWS_CLI_VERSION} detected (2.22+ recommended for full functionality)"
     fi
     AWS_IDENTITY=$(aws sts get-caller-identity --query '[Account, Arn]' --output text 2>&1) || die "AWS credentials not configured (run 'aws configure' or set AWS_PROFILE)"
     AWS_ACCOUNT=$(printf '%s' "${AWS_IDENTITY}" | cut -f1)
     AWS_ARN=$(printf '%s' "${AWS_IDENTITY}" | cut -f2)
     AWS_ALIAS=$(aws iam list-account-aliases --query 'AccountAliases[0]' --output text 2>/dev/null || true)
     if [ -n "${AWS_ALIAS}" ] && [ "${AWS_ALIAS}" != "None" ]; then
          log "AWS account: ${AWS_ACCOUNT} (${AWS_ALIAS})"
     else
          log "AWS account: ${AWS_ACCOUNT}"
     fi
     log "AWS identity: ${AWS_ARN}"
}

# =============================================================================
# Shared helpers
# =============================================================================

ensure_iam_role() {
     new_statement="$1"
     full_policy="{\"Version\":\"2012-10-17\",\"Statement\":[${new_statement}]}"

     if ! aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
          logaction "Creating IAM role ${ROLE_NAME}"
          aws iam create-role \
               --role-name "${ROLE_NAME}" \
               --assume-role-policy-document "${full_policy}" \
               >/dev/null
          return
     fi

     existing=$(aws iam get-role --role-name "${ROLE_NAME}" \
          --query 'Role.AssumeRolePolicyDocument' --output json)

     new_principal=$(printf '%s' "${new_statement}" | jq -r \
          '(.Principal | if type == "object" then to_entries[0].value else . end)')

     # Statements for different principals coexist on one role (EC2, ECS, EKS,
     # and the Azure federations all key off distinct principals). If a
     # statement for this principal is already byte-identical there is nothing
     # to do; if it exists but differs (e.g. a changed namespace in the :sub
     # condition) it must be replaced, not left stale; otherwise append.
     state=$(printf '%s' "${existing}" | jq -r \
          --arg principal "${new_principal}" \
          --argjson stmt "${new_statement}" \
          '[.Statement[] | select((.Principal | if type == "object" then to_entries[0].value else . end) == $principal)] as $m
           | if ($m | length) == 0 then "absent"
             elif ($m | any(. == $stmt)) then "current"
             else "stale" end')

     if [ "${state}" = "current" ]; then
          log "IAM role ${ROLE_NAME} trust policy up to date"
          return
     fi

     if [ "${state}" = "stale" ]; then
          logaction "Updating trust statement on ${ROLE_NAME}"
          merged=$(printf '%s' "${existing}" | jq \
               --arg principal "${new_principal}" \
               --argjson stmt "${new_statement}" \
               '.Statement = ([.Statement[] | select((.Principal | if type == "object" then to_entries[0].value else . end) != $principal)] + [$stmt])')
     else
          logaction "Merging trust statement into ${ROLE_NAME}"
          merged=$(printf '%s' "${existing}" | jq \
               --argjson stmt "${new_statement}" \
               '.Statement += [$stmt]')
     fi

     aws iam update-assume-role-policy \
          --role-name "${ROLE_NAME}" \
          --policy-document "${merged}" \
          >/dev/null
}

attach_permissions_policy() {
     aws iam attach-role-policy \
          --role-name "${ROLE_NAME}" \
          --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy 2>/dev/null || true
     log "Managed policy CloudWatchAgentServerPolicy attached"
}

TXN_SEARCH_DOC="https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Enable-TransactionSearch.html"

ensure_transaction_search() {
     TRACE_DEST_RC=""
     TRACE_DEST=$(aws xray get-trace-segment-destination --region "${REGION}" --query 'Destination' --output text 2>/dev/null) || TRACE_DEST_RC=$?

     if [ -n "${TRACE_DEST_RC}" ]; then
          logwarn "Could not check Transaction Search. OTLP traces need it enabled in ${REGION}:"
          logwarn "${TXN_SEARCH_DOC}"
          return
     fi
     if [ "${TRACE_DEST}" = "CloudWatchLogs" ]; then
          return
     fi

     if [ -t 0 ] && [ -z "${EMIT_ENV}" ] && [ "${ENABLE_TXN_SEARCH}" != "true" ]; then
          ask "Enable Transaction Search for the whole account in ${REGION}? [y/N]"
          read -r answer
          case "${answer}" in [yY]*) ENABLE_TXN_SEARCH="true" ;; esac
     fi

     if [ "${ENABLE_TXN_SEARCH}" != "true" ]; then
          logwarn "OTLP traces need Transaction Search, which is off in ${REGION}. Enabling it"
          logwarn "changes how X-Ray traces are ingested for the whole account in this region."
          logwarn "Rerun with CWAGENT_AWS_ENABLE_TRANSACTION_SEARCH=true to enable it, or:"
          logwarn "${TXN_SEARCH_DOC}"
          return
     fi

     logaction "Enabling Transaction Search in ${REGION}"
     TXN_ERR=$(aws xray update-trace-segment-destination --destination CloudWatchLogs --region "${REGION}" 2>&1 >/dev/null) || TXN_RC=1
     if [ -z "${TXN_RC:-}" ]; then
          log "Transaction Search enabled"
     else
          logwarn "Could not enable Transaction Search:"
          logwarn "${TXN_ERR}"
          logwarn "${TXN_SEARCH_DOC}"
     fi
}

# =============================================================================
# AWS EC2 trust
# =============================================================================

trust_aws_ec2() {
     if [ -z "${INSTANCE_ID}" ]; then usage; fi

     EC2_ROLE_TRUST='{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }'

     # An instance that already has a profile keeps it. The profile is never
     # swapped: that would revoke every other permission its role grants, which
     # this script cannot know about, and would drop the SSM access the install
     # step needs. Instead the policy is attached to the role already there,
     # which requires opting in, since that role belongs to the caller. A role
     # reached this way already trusts ec2.amazonaws.com, so no trust change is
     # needed.
     CURRENT_PROFILE_ARN=$(aws ec2 describe-iam-instance-profile-associations \
          --filters "Name=instance-id,Values=${INSTANCE_ID}" "Name=state,Values=associated" \
          --query 'IamInstanceProfileAssociations[0].IamInstanceProfile.Arn' \
          --region "${REGION}" --output text 2>/dev/null || true)

     if [ -n "${CURRENT_PROFILE_ARN}" ] && [ "${CURRENT_PROFILE_ARN}" != "None" ]; then
          PROFILE_NAME="${CURRENT_PROFILE_ARN##*/}"
          EXISTING_ROLE=$(aws iam get-instance-profile \
               --instance-profile-name "${PROFILE_NAME}" \
               --query 'InstanceProfile.Roles[0].RoleName' --output text 2>/dev/null || true)

          if [ -z "${EXISTING_ROLE}" ] || [ "${EXISTING_ROLE}" = "None" ]; then
               die "Instance profile ${PROFILE_NAME} has no role attached"
          fi

          section "Using existing instance profile..."
          log "Instance profile ${PROFILE_NAME} attached to ${INSTANCE_ID}"
          log "Role: ${EXISTING_ROLE}"
          ROLE_NAME="${EXISTING_ROLE}"

          # Nothing to do if the policy is already there, so a re-run stays quiet
          # and needs no opt-in.
          if aws iam list-attached-role-policies --role-name "${ROLE_NAME}" \
               --query 'AttachedPolicies[?PolicyName==`CloudWatchAgentServerPolicy`] | [0].PolicyName' \
               --output text 2>/dev/null | grep -q CloudWatchAgentServerPolicy; then
               log "Managed policy CloudWatchAgentServerPolicy already attached"
               return
          fi

          if [ -t 0 ] && [ -z "${EMIT_ENV}" ] && [ "${UPDATE_INSTANCE_ROLE}" != "true" ]; then
               ask "Attach CloudWatchAgentServerPolicy to ${ROLE_NAME}? [y/N]"
               read -r answer
               case "${answer}" in [yY]*) UPDATE_INSTANCE_ROLE="true" ;; esac
          fi
          if [ "${UPDATE_INSTANCE_ROLE}" != "true" ]; then
               die "${ROLE_NAME} is missing CloudWatchAgentServerPolicy — attach it manually, or set CWAGENT_AWS_UPDATE_INSTANCE_ROLE=true to have this script attach it"
          fi

          attach_permissions_policy
          return
     fi

     # No profile attached — create the role, its instance profile, and associate.
     PROFILE_NAME="${ROLE_NAME}"

     section "Configuring IAM role..."
     ensure_iam_role "${EC2_ROLE_TRUST}"
     attach_permissions_policy

     section "Configuring instance profile..."
     ensure_instance_profile "${PROFILE_NAME}"
     logaction "Associating instance profile with ${INSTANCE_ID}"
     aws ec2 associate-iam-instance-profile \
          --instance-id "${INSTANCE_ID}" \
          --iam-instance-profile Name="${PROFILE_NAME}" --region "${REGION}" >/dev/null
}

# Create the instance profile and bind the role if it does not already exist.
# The sleep covers IAM's eventual consistency before the profile is associated.
ensure_instance_profile() {
     profile="$1"
     if aws iam get-instance-profile --instance-profile-name "${profile}" >/dev/null 2>&1; then
          log "Instance profile ${profile} exists"
          return
     fi
     logaction "Creating instance profile ${profile}"
     aws iam create-instance-profile --instance-profile-name "${profile}" >/dev/null
     aws iam add-role-to-instance-profile \
          --instance-profile-name "${profile}" --role-name "${ROLE_NAME}" >/dev/null
     logaction "Waiting for propagation..."
     sleep 10
}

# =============================================================================
# AWS ECS trust
# =============================================================================

trust_aws_ecs() {
     section "Configuring IAM task role..."

     ensure_iam_role '{
    "Effect": "Allow",
    "Principal": { "Service": "ecs-tasks.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }'

     attach_permissions_policy
}

# =============================================================================
# AWS EKS trust
# =============================================================================

trust_aws_eks() {
     if [ -z "${CLUSTER_NAME}" ]; then usage; fi

     NAMESPACE="${NAMESPACE:-amazon-cloudwatch}"

     section "Configuring EKS Pod Identity..."

     if aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name eks-pod-identity-agent --region "${REGION}" >/dev/null 2>&1; then
          log "Pod Identity Agent addon installed"
     else
          logaction "Installing Pod Identity Agent addon"
          aws eks create-addon \
               --cluster-name "${CLUSTER_NAME}" \
               --addon-name eks-pod-identity-agent \
               --region "${REGION}" >/dev/null
     fi

     section "Configuring IAM role..."

     ensure_iam_role '{
    "Effect": "Allow",
    "Principal": { "Service": "pods.eks.amazonaws.com" },
    "Action": ["sts:AssumeRole", "sts:TagSession"]
  }'

     attach_permissions_policy

     ROLE_ARN=$(aws iam get-role \
          --role-name "${ROLE_NAME}" \
          --query Role.Arn --output text)

     section "Configuring pod identity association..."

     EXISTING_ASSOC=$(aws eks list-pod-identity-associations \
          --cluster-name "${CLUSTER_NAME}" \
          --namespace "${NAMESPACE}" \
          --service-account cloudwatch-agent \
          --region "${REGION}" \
          --query 'associations[0].associationId' --output text 2>/dev/null || true)

     if [ -n "${EXISTING_ASSOC}" ] && [ "${EXISTING_ASSOC}" != "None" ]; then
          EXISTING_ROLE=$(aws eks describe-pod-identity-association \
               --cluster-name "${CLUSTER_NAME}" \
               --association-id "${EXISTING_ASSOC}" \
               --region "${REGION}" \
               --query 'association.roleArn' --output text 2>/dev/null || true)
          if [ "${EXISTING_ROLE}" = "${ROLE_ARN}" ]; then
               log "Pod identity association exists"
          else
               logaction "Updating association role to ${ROLE_ARN}"
               aws eks update-pod-identity-association \
                    --cluster-name "${CLUSTER_NAME}" \
                    --association-id "${EXISTING_ASSOC}" \
                    --role-arn "${ROLE_ARN}" \
                    --region "${REGION}" >/dev/null
          fi
     else
          logaction "Creating association for ${NAMESPACE}/cloudwatch-agent"
          aws eks create-pod-identity-association \
               --cluster-name "${CLUSTER_NAME}" \
               --region "${REGION}" \
               --namespace "${NAMESPACE}" \
               --service-account cloudwatch-agent \
               --role-arn "${ROLE_ARN}" >/dev/null
     fi
}

# =============================================================================
# Azure VM trust
# =============================================================================

trust_azure_vm() {
     if [ -z "${TENANT_ID}" ]; then
          die "CWAGENT_AZURE_TENANT_ID is required for azure_vm (produced by azure/setup-identity.sh)"
     fi

     OIDC_AUDIENCE="https://management.azure.com/"

     section "Configuring AWS trust..."

     PROVIDER_ARN=$(aws iam list-open-id-connect-providers \
          --query "OpenIDConnectProviderList[?ends_with(Arn, 'sts.windows.net/${TENANT_ID}/')].Arn | [0]" \
          --output text 2>/dev/null || true)

     if [ -n "${PROVIDER_ARN}" ] && [ "${PROVIDER_ARN}" != "None" ]; then
          log "OIDC provider exists"
     else
          logaction "Registering OIDC provider"
          aws iam create-open-id-connect-provider \
               --url "https://sts.windows.net/${TENANT_ID}/" \
               --client-id-list "${OIDC_AUDIENCE}" \
               --thumbprint-list "626d44e704d1ceabe3bf0d53397464ac8080142c" \
               >/dev/null
     fi

     ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

     TRUST_STATEMENT=$(
          cat <<EOF
{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/sts.windows.net/${TENANT_ID}/"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "sts.windows.net/${TENANT_ID}/:aud": "${OIDC_AUDIENCE}"
      }
    }
  }
EOF
     )

     ensure_iam_role "${TRUST_STATEMENT}"
     attach_permissions_policy
}

# =============================================================================
# Azure AKS trust
# =============================================================================

trust_azure_aks() {
     if [ -z "${OIDC_ISSUER}" ]; then
          die "CWAGENT_AZURE_OIDC_ISSUER is required for azure_aks (produced by azure/setup-identity.sh)"
     fi

     NAMESPACE="${NAMESPACE:-amazon-cloudwatch}"
     OIDC_HOST="${OIDC_ISSUER#https://}"

     section "Configuring AWS trust..."

     PROVIDER_ARN=$(aws iam list-open-id-connect-providers \
          --query "OpenIDConnectProviderList[?contains(Arn, '${OIDC_HOST}')].Arn | [0]" \
          --output text 2>/dev/null || true)

     if [ -n "${PROVIDER_ARN}" ] && [ "${PROVIDER_ARN}" != "None" ]; then
          log "OIDC provider exists"
     else
          logaction "Registering OIDC provider"
          aws iam create-open-id-connect-provider \
               --url "${OIDC_ISSUER}" \
               --client-id-list sts.amazonaws.com \
               >/dev/null
     fi

     ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

     TRUST_STATEMENT=$(
          cat <<EOF
{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_HOST}:sub": "system:serviceaccount:${NAMESPACE}:cloudwatch-agent",
        "${OIDC_HOST}:aud": "sts.amazonaws.com"
      }
    }
  }
EOF
     )

     ensure_iam_role "${TRUST_STATEMENT}"
     attach_permissions_policy
}

main() {
     case "${1:-}" in -h | --help) usage ;; esac

     # Interactive only on a real TTY and never under CWAGENT_EMIT_ENV (the
     # dispatcher eval-chains this script and cannot answer prompts).
     if [ -t 0 ] && [ -z "${EMIT_ENV}" ] && [ -z "${PLATFORM}" ]; then
          interactive_setup
     fi

     case "${PLATFORM}" in
     aws_ec2 | aws_ecs | aws_eks | azure_vm | azure_aks) ;;
     *) die "unsupported platform: ${PLATFORM:-<unset>} (valid: aws_ec2, aws_ecs, aws_eks, azure_vm, azure_aks)" ;;
     esac

     check_prerequisites

     # Region is where telemetry lands and is baked into the role/endpoint, so
     # never guess it. Take the env var, fall back to the AWS CLI config, then
     # prompt on a TTY, and fail rather than default silently.
     if [ -z "${REGION}" ]; then
          REGION=$(aws configure get region 2>/dev/null || true)
     fi
     if [ -z "${REGION}" ] && [ -t 0 ] && [ -z "${EMIT_ENV}" ]; then
          prompt REGION "AWS region telemetry is sent to"
     fi
     [ -n "${REGION}" ] || die "CWAGENT_AWS_REGION is required (set it or run 'aws configure set region <region>')"

     case "${PLATFORM}" in
     aws_ec2) trust_aws_ec2 ;;
     aws_ecs) trust_aws_ecs ;;
     aws_eks) trust_aws_eks ;;
     azure_vm) trust_azure_vm ;;
     azure_aks) trust_azure_aks ;;
     esac

     ROLE_ARN=$(aws iam get-role \
          --role-name "${ROLE_NAME}" \
          --query Role.Arn --output text)
     log "Role ARN: ${ROLE_ARN}"

     ensure_transaction_search

     add_env CWAGENT_PLATFORM "${PLATFORM}"
     add_env CWAGENT_ROLE_ARN "${ROLE_ARN}"
     add_env CWAGENT_AWS_REGION "${REGION}"
     # Carried through so the install step is one self-contained paste, with no
     # values to re-enter by hand.
     add_env CWAGENT_AWS_INSTANCE_ID "${INSTANCE_ID}"
     add_env CWAGENT_K8S_CLUSTER_NAME "${CLUSTER_NAME}"
     add_env CWAGENT_K8S_NAMESPACE "${NAMESPACE}"

     emit_env
}

main "$@"
