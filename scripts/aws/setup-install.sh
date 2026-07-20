#!/bin/sh

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT

# Amazon CloudWatch Agent — AWS install
#
# Installs the agent against the IAM role the AWS trust setup created:
#
#   aws_ec2     pushes install.sh to the instance via SSM
#               (requires: aws)
#   aws_eks     installs the CloudWatch Observability Helm chart
#               (requires: aws, helm, kubectl)
#   aws_ecs     prints the sidecar container definition to add to the task
#               (requires: aws)
#
# Usage:
#     CWAGENT_PLATFORM=aws_ec2 \
#     CWAGENT_AWS_INSTANCE_ID=i-123 \
#     CWAGENT_AWS_REGION=us-west-2 \
#       ./aws/setup-install.sh
#
# Environment variables:
#   Common:
#     CWAGENT_PLATFORM              aws_ec2 | aws_ecs | aws_eks
#     CWAGENT_IAM_ROLE_NAME         IAM role name (default: CloudWatchAgentServerRole)
#     CWAGENT_AWS_REGION            AWS region telemetry is sent to (required)
#     CWAGENT_SKIP_INSTALL          Skip installation (print command instead)
#   aws_ec2:
#     CWAGENT_AWS_INSTANCE_ID       EC2 instance ID
#     CWAGENT_INSTALL_URL           Override package/artifact download URL
#   aws_eks:
#     CWAGENT_K8S_CLUSTER_NAME      Cluster name
#     CWAGENT_K8S_NAMESPACE         Namespace (default: amazon-cloudwatch)
#     CWAGENT_HELM_REPO             Override Helm chart repository
#   aws_ecs:
#     CWAGENT_AWS_ECS_LAUNCH_TYPE   fargate | ec2 (default: fargate)
#     CWAGENT_IMAGE                 Override agent container image

set -eu

PLATFORM="${CWAGENT_PLATFORM:-}"
ROLE_NAME="${CWAGENT_IAM_ROLE_NAME:-CloudWatchAgentServerRole}"
REGION="${CWAGENT_AWS_REGION:-}"
INSTANCE_ID="${CWAGENT_AWS_INSTANCE_ID:-}"
CLUSTER_NAME="${CWAGENT_K8S_CLUSTER_NAME:-}"
NAMESPACE="${CWAGENT_K8S_NAMESPACE:-}"
ECS_LAUNCH_TYPE="${CWAGENT_AWS_ECS_LAUNCH_TYPE:-}"
SKIP_INSTALL="${CWAGENT_SKIP_INSTALL:-}"
INSTALL_URL="${CWAGENT_INSTALL_URL:-}"
CONTAINER_IMAGE="${CWAGENT_IMAGE:-public.ecr.aws/cloudwatch-agent/cloudwatch-agent:latest}"
HELM_CHART_REPO="${CWAGENT_HELM_REPO:-https://aws-observability.github.io/helm-charts}"

DOWNLOAD_BASE="https://amazoncloudwatch-agent.s3.amazonaws.com"
# Where the target fetches the install payload (install.sh / install.ps1) from.
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
  CWAGENT_PLATFORM=aws_ec2 CWAGENT_AWS_INSTANCE_ID=i-123 $0
  CWAGENT_PLATFORM=aws_eks CWAGENT_K8S_CLUSTER_NAME=<cluster> $0
  CWAGENT_PLATFORM=aws_ecs $0

Environment variables:
  Common:
    CWAGENT_PLATFORM              aws_ec2 | aws_ecs | aws_eks
    CWAGENT_IAM_ROLE_NAME         IAM role name (default: CloudWatchAgentServerRole)
    CWAGENT_AWS_REGION            AWS region (required)
    CWAGENT_SKIP_INSTALL          Skip installation (print command instead)
  aws_ec2:
    CWAGENT_AWS_INSTANCE_ID       EC2 instance ID
  aws_eks:
    CWAGENT_K8S_CLUSTER_NAME      Cluster name
    CWAGENT_K8S_NAMESPACE         Namespace (default: amazon-cloudwatch)
  aws_ecs:
    CWAGENT_AWS_ECS_LAUNCH_TYPE   fargate | ec2 (default: fargate)
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
     command -v aws >/dev/null 2>&1 || die "AWS CLI is required but not installed"
     aws sts get-caller-identity >/dev/null 2>&1 || die "AWS credentials not configured (run 'aws configure' or set AWS_PROFILE)"

     if [ "${PLATFORM}" = "aws_eks" ] && [ "${SKIP_INSTALL}" != "true" ]; then
          command -v helm >/dev/null 2>&1 || die "Helm is required for EKS installs (or set CWAGENT_SKIP_INSTALL=true)"
          command -v kubectl >/dev/null 2>&1 || die "kubectl is required for EKS installs (or set CWAGENT_SKIP_INSTALL=true)"
     fi
}

# =============================================================================
# Install payload builders (EC2 path)
# =============================================================================

# Emit the one-line command that fetches install.sh and runs it on a Linux
# target, with the given env assignments as a prefix. $1 = env assignments.
linux_install_cmd() {
     envs="$1"
     printf 'curl -fsSL %s/install.sh | %s sh' "${SCRIPT_BASE_URL}" "${envs}"
}

# Windows counterpart. The prelude + fetch are wrapped into one -EncodedCommand
# base64 payload (UTF-16LE) so the outer command needs no quoting through SSM.
# $1 = PowerShell env prelude (e.g. "$env:CWAGENT_INSTALL_URL='...'; ")
windows_install_cmd() {
     ps_prelude="$1"
     ps_script="${ps_prelude}Invoke-WebRequest -Uri ${SCRIPT_BASE_URL}/install.ps1 -OutFile \$env:TEMP\\cwagent-install.ps1; & \$env:TEMP\\cwagent-install.ps1"
     encoded=$(printf '%s' "${ps_script}" | iconv -f utf-8 -t utf-16le 2>/dev/null | base64 | tr -d '\n')
     [ -n "${encoded}" ] || return 1
     printf 'powershell -NoProfile -EncodedCommand %s' "${encoded}"
}

# Run a command on an EC2 instance via SSM. $1 = document name
# (AWS-RunShellScript | AWS-RunPowerShellScript), $2 = command.
run_via_ssm() {
     ssm_doc="$1"
     ssm_cmd="$2"

     logaction "Running install via SSM"
     COMMAND_ID=$(aws ssm send-command \
          --instance-ids "${INSTANCE_ID}" \
          --document-name "${ssm_doc}" \
          --parameters "commands=[\"${ssm_cmd}\"]" \
          --region "${REGION}" --query 'Command.CommandId' --output text)

     aws ssm wait command-executed \
          --command-id "${COMMAND_ID}" \
          --instance-id "${INSTANCE_ID}" --region "${REGION}" 2>/dev/null || true

     SSM_OUTPUT=$(aws ssm get-command-invocation \
          --command-id "${COMMAND_ID}" \
          --instance-id "${INSTANCE_ID}" \
          --region "${REGION}" --query 'StandardOutputContent' --output text)
     SSM_STATUS_DETAIL=$(aws ssm get-command-invocation \
          --command-id "${COMMAND_ID}" \
          --instance-id "${INSTANCE_ID}" \
          --region "${REGION}" --query 'StatusDetails' --output text)

     echo "${SSM_OUTPUT}"
     if [ "${SSM_STATUS_DETAIL}" != "Success" ]; then
          aws ssm get-command-invocation \
               --command-id "${COMMAND_ID}" \
               --instance-id "${INSTANCE_ID}" \
               --region "${REGION}" --query 'StandardErrorContent' --output text >&2
          die "SSM command finished with status: ${SSM_STATUS_DETAIL}"
     fi
}

# Print manual install instructions for a Linux instance.
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
# AWS EC2 install
# =============================================================================

install_aws_ec2() {
     if [ -z "${INSTANCE_ID}" ]; then usage; fi

     INSTANCE_PLATFORM=$(aws ec2 describe-instances \
          --instance-ids "${INSTANCE_ID}" \
          --region "${REGION}" \
          --query 'Reservations[0].Instances[0].Platform' --output text 2>/dev/null || true)

     if [ "${SKIP_INSTALL}" != "true" ]; then
          SSM_STATUS=$(aws ssm describe-instance-information \
               --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
               --query 'InstanceInformationList[0].PingStatus' \
               --region "${REGION}" --output text 2>/dev/null || true)

          if [ "${SSM_STATUS}" = "Online" ]; then
               section "Installing agent on ${INSTANCE_ID}..."
               install_env=""
               [ -n "${INSTALL_URL}" ] && install_env="CWAGENT_INSTALL_URL=${INSTALL_URL}"
               if [ "${INSTANCE_PLATFORM}" = "windows" ]; then
                    ps_prelude=""
                    [ -n "${INSTALL_URL}" ] && ps_prelude="\$env:CWAGENT_INSTALL_URL='${INSTALL_URL}'; "
                    if INSTALL_CMD=$(windows_install_cmd "${ps_prelude}"); then
                         run_via_ssm "AWS-RunPowerShellScript" "${INSTALL_CMD}"
                         log "Agent installed on ${INSTANCE_ID}"
                         return
                    fi
               else
                    if INSTALL_CMD=$(linux_install_cmd "${install_env}"); then
                         run_via_ssm "AWS-RunShellScript" "${INSTALL_CMD}"
                         log "Agent installed on ${INSTANCE_ID}"
                         return
                    fi
               fi
               logwarn "could not build the install command (iconv is required for Windows targets)"
          else
               logwarn "SSM agent is not available on ${INSTANCE_ID}"
          fi
     fi

     echo ""
     echo "Done. Run the following on ${INSTANCE_ID} to install and start the agent:"
     echo ""
     if [ "${INSTANCE_PLATFORM}" = "windows" ]; then
          print_windows_install
          echo ""
          echo "  # Configure and start with the default OpenTelemetry config:"
          echo "  ${CTL_PS1} -Action fetch-config -Mode ec2 -ConfigLocation default:otel -Start"
     else
          print_linux_install
          echo ""
          echo "  # Configure and start with the default OpenTelemetry config:"
          echo "  sudo ${CTL} -a fetch-config -m ec2 -c default:otel -s"
     fi
}

# =============================================================================
# AWS EKS install
# =============================================================================

install_aws_eks() {
     if [ -z "${CLUSTER_NAME}" ]; then usage; fi

     NAMESPACE="${NAMESPACE:-amazon-cloudwatch}"

     # No roleArn on the Helm command: pod identity supplies the agent's
     # credentials on EKS, and the chart injects roleArn only under k8sMode=AKS.
     if [ "${SKIP_INSTALL}" != "true" ]; then
          section "Installing CloudWatch Observability Helm chart on ${CLUSTER_NAME}..."
          logaction "Configuring kubeconfig for ${CLUSTER_NAME}"
          aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}"

          logaction "Installing via Helm"
          helm repo add aws-observability "${HELM_CHART_REPO}" 2>/dev/null || true
          helm repo update aws-observability
          helm upgrade --install amazon-cloudwatch-observability aws-observability/amazon-cloudwatch-observability \
               --set k8sMode=EKS \
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
          printf '    --set k8sMode=EKS \\\n'
          printf '    --set region=%s \\\n' "${REGION}"
          printf '    --set clusterName=%s \\\n' "${CLUSTER_NAME}"
          printf "    --set-string 'agents[0].config=default:otel' \\\\\n"
          printf '    --namespace %s \\\n' "${NAMESPACE}"
          printf '    --create-namespace\n'
     fi
}

# =============================================================================
# AWS ECS install
#
# The ECS "install" is a container added to an existing task definition, so this
# prints that definition rather than deploying anything.
# =============================================================================

install_aws_ecs() {
     ECS_LAUNCH_TYPE="${ECS_LAUNCH_TYPE:-fargate}"

     ROLE_ARN=$(aws iam get-role \
          --role-name "${ROLE_NAME}" \
          --query Role.Arn --output text)

     section "Add this container to the task definition's containerDefinitions:"
     echo ""
     cat <<EOF
    {
      "name": "cloudwatch-agent",
      "image": "${CONTAINER_IMAGE}",
      "essential": false,$(
          if [ "${ECS_LAUNCH_TYPE}" = "ec2" ]; then
               cat <<PORTS

      "portMappings": [
        { "containerPort": 4317, "hostPort": 4317, "protocol": "tcp" },
        { "containerPort": 4318, "hostPort": 4318, "protocol": "tcp" }
      ],
PORTS
          fi
     )
      "environment": [
        { "name": "USE_DEFAULT_CONFIG", "value": "otel" }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-create-group": "True",
          "awslogs-group": "/ecs/cloudwatch-agent",
          "awslogs-region": "${REGION}",
          "awslogs-stream-prefix": "agent"
        }
      }
    }
EOF

     echo ""
     echo "Also set on the task definition:"
     if [ "${ECS_LAUNCH_TYPE}" = "ec2" ]; then
          echo "  \"taskRoleArn\": \"${ROLE_ARN}\","
          echo "  \"networkMode\": \"bridge\""
          echo ""
          echo "Add to the application container:"
          echo "  \"links\": [\"cloudwatch-agent\"]"
          echo "  \"environment\": [{\"name\": \"OTEL_EXPORTER_OTLP_ENDPOINT\", \"value\": \"http://cloudwatch-agent:4317\"}]"
     else
          echo "  \"taskRoleArn\": \"${ROLE_ARN}\""
     fi
}

main() {
     case "${1:-}" in -h | --help) usage ;; esac

     if [ -t 0 ] && [ -z "${PLATFORM}" ]; then
          ask "Platform (aws_ec2 | aws_ecs | aws_eks):"
          read -r PLATFORM
     fi

     case "${PLATFORM}" in
     aws_ec2 | aws_ecs | aws_eks) ;;
     *) die "unsupported platform: ${PLATFORM:-<unset>} (valid: aws_ec2, aws_ecs, aws_eks)" ;;
     esac

     # Prompt for any remaining inputs when interactive.
     if [ -t 0 ]; then
          case "${PLATFORM}" in
          aws_ec2)
               prompt INSTANCE_ID "Instance ID"
               ;;
          aws_eks)
               prompt CLUSTER_NAME "Cluster name"
               prompt NAMESPACE "Namespace" "amazon-cloudwatch"
               ;;
          aws_ecs)
               prompt ECS_LAUNCH_TYPE "Launch type (fargate|ec2)" "fargate"
               ;;
          esac
     fi

     check_prerequisites

     # Region is where telemetry lands and is baked into the endpoint, so never
     # guess it. Take the env var, fall back to the AWS CLI config, then prompt
     # on a TTY, and fail rather than default silently.
     if [ -z "${REGION}" ]; then
          REGION=$(aws configure get region 2>/dev/null || true)
     fi
     if [ -z "${REGION}" ] && [ -t 0 ]; then
          prompt REGION "AWS region telemetry is sent to"
     fi
     [ -n "${REGION}" ] || die "CWAGENT_AWS_REGION is required (set it or run 'aws configure set region <region>')"

     case "${PLATFORM}" in
     aws_ec2) install_aws_ec2 ;;
     aws_eks) install_aws_eks ;;
     aws_ecs) install_aws_ecs ;;
     esac
}

main "$@"
