#!/bin/bash
# Kong Cloud Gateway on EKS - Post-Terraform Setup
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Run this script AFTER 'terraform apply' AND after ArgoCD has synced
# (Istio Gateway created the internal NLB).
#
# What it does:
#   1. Reads Terraform outputs (VPC ID, Transit Gateway ID)
#   2. Waits for the Istio Gateway NLB to be provisioned
#   3. Displays the single NLB endpoint for Konnect service configuration
#   4. Shows Transit Gateway setup instructions
#
# Usage:
#   ./scripts/03-post-terraform-setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/.."
TERRAFORM_DIR="${REPO_DIR}/terraform"

# Auto-source .env if it exists (contains KONNECT_TOKEN etc.)
ENV_FILE="${REPO_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

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
# Get Istio Gateway NLB endpoint
# ---------------------------------------------------------------------------
get_gateway_endpoint() {
    log "Fetching Istio Gateway NLB endpoint..."
    echo ""

    # Wait for Gateway to be ready
    for i in {1..30}; do
        GATEWAY_STATUS=$(kubectl get gateway -n istio-ingress kong-cloud-gw-gateway -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null) || true
        if [ "$GATEWAY_STATUS" = "True" ]; then
            log "Gateway is ready"
            break
        fi
        if [ $i -eq 30 ]; then
            warn "Timeout waiting for Gateway. It may still be provisioning."
            warn "Check: kubectl get gateway -n istio-ingress"
            return
        fi
        echo -n "."
        sleep 10
    done

    NLB_HOSTNAME=$(kubectl get gateway -n istio-ingress kong-cloud-gw-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "pending")

    echo ""
    echo "=========================================="
    echo "  Istio Gateway NLB Endpoint"
    echo "=========================================="
    echo ""
    echo "  NLB DNS: ${NLB_HOSTNAME}"
    echo ""
    echo "  This is the SINGLE entry point for all Kong Cloud Gateway traffic."
    echo "  All services in deck/kong.yaml should use this NLB hostname."
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
    echo "Update ALL service URLs in deck/kong.yaml with the Istio Gateway NLB:"
    echo ""
    echo "  services:"
    echo "    - name: users-api"
    echo "      url: http://${NLB_HOSTNAME:-<istio-gateway-nlb-dns>}:80"
    echo "    - name: tenant-app1"
    echo "      url: http://${NLB_HOSTNAME:-<istio-gateway-nlb-dns>}:80"
    echo "    - name: tenant-app2"
    echo "      url: http://${NLB_HOSTNAME:-<istio-gateway-nlb-dns>}:80"
    echo "    - name: gateway-health"
    echo "      url: http://${NLB_HOSTNAME:-<istio-gateway-nlb-dns>}:80"
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
    echo "To connect Kong Cloud Gateway to the Istio Gateway NLB:"
    echo ""
    echo "  1. Set up Konnect Cloud Gateway:"
    echo "     ./scripts/02-setup-cloud-gateway.sh"
    echo "     (Handles RAM sharing, network provisioning, and TGW attachment automatically)"
    echo ""
    echo "  2. VPC route tables are auto-configured by Terraform:"
    echo "     Route: 192.168.0.0/16 -> Transit Gateway (${TRANSIT_GW_ID:-tgw-xxx})"
    echo ""
    echo "  3. Security Groups are auto-configured by Terraform:"
    echo "     Allow inbound from 192.168.0.0/16 (Kong Cloud GW CIDR)"
    echo ""
    echo "  Note: TGW attachment is auto-accepted (auto_accept_shared_attachments enabled)"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo "=============================================="
    echo "  Post-Terraform Setup -- Kong Cloud Gateway"
    echo "  with Istio Gateway (K8s Gateway API)"
    echo "=============================================="
    echo ""

    read_terraform_outputs
    get_gateway_endpoint
    show_konnect_config
    show_transit_gw_instructions
}

main "$@"
