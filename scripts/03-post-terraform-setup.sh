#!/bin/bash
# EKS Kong Konnect Cloud Gateway - Post-Terraform Setup
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Run this script AFTER 'terraform apply' to display the internal NLB
# endpoints needed for Konnect service configuration.
#
# What it does:
#   1. Reads Terraform outputs (VPC ID, Transit Gateway ID, internal NLB DNS names)
#   2. Displays endpoints for Konnect service upstream configuration
#   3. Shows Transit Gateway setup instructions
#
# Usage:
#   ./scripts/03-post-terraform-setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/.."
TERRAFORM_DIR="${REPO_DIR}/terraform"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error(){ echo -e "${RED}[ERROR]${NC} $*"; }
info() { echo -e "${CYAN}[CONFIG]${NC} $*"; }

# ---------------------------------------------------------------------------
# Read Terraform outputs
# ---------------------------------------------------------------------------
read_terraform_outputs() {
    log "Reading Terraform outputs..."

    cd "$TERRAFORM_DIR"

    VPC_ID=$(terraform output -raw vpc_id 2>/dev/null || echo "N/A")
    VPC_CIDR=$(terraform output -raw vpc_cidr 2>/dev/null || echo "N/A")
    TRANSIT_GW_ID=$(terraform output -raw transit_gateway_id 2>/dev/null || echo "N/A")
    RAM_SHARE_ARN=$(terraform output -raw ram_share_arn 2>/dev/null || echo "N/A")

    cd "$REPO_DIR"

    echo ""
    log "Infrastructure Details:"
    echo "  VPC ID:              $VPC_ID"
    echo "  VPC CIDR:            $VPC_CIDR"
    echo "  Transit Gateway ID:  $TRANSIT_GW_ID"
    echo "  RAM Share ARN:       $RAM_SHARE_ARN"
    echo ""
}

# ---------------------------------------------------------------------------
# Get internal NLB endpoints from K8s
# ---------------------------------------------------------------------------
get_service_endpoints() {
    log "Fetching internal NLB endpoints from K8s services..."
    echo ""

    for svc_info in "api/users-api" "tenant-app1/sample-app-1" "tenant-app2/sample-app-2" "gateway-health/health-responder"; do
        ns="${svc_info%%/*}"
        svc="${svc_info##*/}"
        endpoint=$(kubectl get svc "$svc" -n "$ns" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
        echo "  ${svc} (${ns}): ${endpoint}"
    done
    echo ""
}

# ---------------------------------------------------------------------------
# Show Konnect configuration instructions
# ---------------------------------------------------------------------------
show_konnect_config() {
    echo ""
    echo "=========================================="
    echo "  Konnect Service Configuration"
    echo "=========================================="
    echo ""
    echo "Update deck/kong.yaml service URLs with the internal NLB endpoints above."
    echo "Format: http://<internal-nlb-dns>:80"
    echo ""
    echo "Example:"
    echo "  services:"
    echo "    - name: users-api"
    echo "      url: http://<users-api-nlb-dns>:80"
    echo ""
    echo "Then sync to Konnect:"
    echo "  deck gateway sync -s deck/kong.yaml \\"
    echo "    --konnect-addr https://\${KONNECT_REGION}.api.konghq.com \\"
    echo "    --konnect-token \$KONNECT_TOKEN \\"
    echo "    --konnect-control-plane-name kong-cloud-gateway-eks"
    echo ""
}

# ---------------------------------------------------------------------------
# Show Transit Gateway instructions
# ---------------------------------------------------------------------------
show_transit_gw_instructions() {
    echo ""
    echo "=========================================="
    echo "  Transit Gateway Setup"
    echo "=========================================="
    echo ""
    echo "To connect Kong Cloud Gateway to your EKS services:"
    echo ""
    echo "  1. Set up Konnect Cloud Gateway:"
    echo "     ./scripts/01-setup-cloud-gateway.sh"
    echo ""
    echo "  2. Accept TGW attachment in AWS Console:"
    echo "     VPC → Transit Gateway Attachments → Accept"
    echo ""
    echo "  3. Update VPC route tables:"
    echo "     Add route: 192.168.0.0/16 → Transit Gateway (${TRANSIT_GW_ID:-tgw-xxx})"
    echo ""
    echo "  4. Update Security Groups:"
    echo "     Allow inbound from 192.168.0.0/16 (Kong Cloud GW CIDR)"
    echo ""
    echo "  5. Configure DNS in Konnect:"
    echo "     Map internal NLB DNS names or create Private Hosted Zone"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo "=============================================="
    echo "  Post-Terraform Setup — Cloud Gateway"
    echo "=============================================="
    echo ""

    read_terraform_outputs
    get_service_endpoints
    show_konnect_config
    show_transit_gw_instructions
}

main "$@"
