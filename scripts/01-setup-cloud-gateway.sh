#!/bin/bash
# Setup Kong Konnect Dedicated Cloud Gateway
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Creates a Konnect control plane with Dedicated Cloud Gateway,
# provisions the cloud gateway network, and configures Transit Gateway
# attachment for private connectivity to EKS backend services.
#
# Prerequisites:
#   1. A Konnect Personal Access Token (kpat_xxx)
#   2. EKS cluster deployed with Terraform (for VPC ID, Transit Gateway ID)
#   3. AWS Transit Gateway shared via RAM with Kong's account
#
# Usage:
#   export KONNECT_REGION="au"
#   export KONNECT_TOKEN="kpat_xxx..."
#   export TRANSIT_GATEWAY_ID="tgw-xxxxxxxxx"      # From terraform output
#   export RAM_SHARE_ARN="arn:aws:ram:..."          # From terraform output
#   export EKS_VPC_CIDR="10.0.0.0/16"              # Your VPC CIDR
#   ./scripts/01-setup-cloud-gateway.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error(){ echo -e "${RED}[ERROR]${NC} $*"; }
info() { echo -e "${CYAN}[CONFIG]${NC} $*"; }

CP_NAME="kong-cloud-gateway-eks"
DCGW_NETWORK_NAME="eks-backend-network"
DCGW_CIDR="192.168.0.0/16"
KONG_GW_VERSION="3.9"

# ---------------------------------------------------------------------------
# Validate environment variables
# ---------------------------------------------------------------------------
validate_env() {
    local missing=false

    if [[ -z "${KONNECT_REGION:-}" ]]; then
        error "KONNECT_REGION not set (e.g., us, eu, au)"
        missing=true
    fi
    if [[ -z "${KONNECT_TOKEN:-}" ]]; then
        error "KONNECT_TOKEN not set (Personal Access Token from Konnect)"
        missing=true
    fi

    if [[ "$missing" == true ]]; then
        echo ""
        echo "Usage:"
        echo "  export KONNECT_REGION=\"au\""
        echo "  export KONNECT_TOKEN=\"kpat_xxx...\""
        echo "  export TRANSIT_GATEWAY_ID=\"tgw-xxx\"    # Optional: for Transit GW setup"
        echo "  export RAM_SHARE_ARN=\"arn:aws:ram:...\"  # Optional: for Transit GW setup"
        echo "  export EKS_VPC_CIDR=\"10.0.0.0/16\"      # Optional: for Transit GW setup"
        echo "  ./scripts/01-setup-cloud-gateway.sh"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Step 1: Create Control Plane
# ---------------------------------------------------------------------------
create_control_plane() {
    log "Step 1: Creating Konnect control plane: ${CP_NAME}"

    if [[ -n "${CONTROL_PLANE_ID:-}" ]]; then
        log "  Using existing control plane: ${CONTROL_PLANE_ID}"
        return
    fi

    CP_RESPONSE=$(curl -s -X POST \
        "https://${KONNECT_REGION}.api.konghq.com/v2/control-planes" \
        -H "Authorization: Bearer $KONNECT_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{
            \"name\": \"${CP_NAME}\",
            \"cluster_type\": \"CLUSTER_TYPE_CONTROL_PLANE\",
            \"labels\": {
                \"env\": \"poc\",
                \"type\": \"cloud-gateway\",
                \"managed-by\": \"script\"
            }
        }")

    CONTROL_PLANE_ID=$(echo "$CP_RESPONSE" | jq -r '.id')

    if [[ -z "$CONTROL_PLANE_ID" || "$CONTROL_PLANE_ID" == "null" ]]; then
        error "Failed to create control plane"
        error "Response: $CP_RESPONSE"
        exit 1
    fi

    log "  Control Plane ID: ${CONTROL_PLANE_ID}"
}

# ---------------------------------------------------------------------------
# Step 2: Create Cloud Gateway Network
# ---------------------------------------------------------------------------
create_network() {
    log "Step 2: Creating Cloud Gateway Network: ${DCGW_NETWORK_NAME}"

    # Get provider account ID for the region
    PROVIDER_ACCOUNTS=$(curl -s \
        "https://global.api.konghq.com/v2/cloud-gateways/provider-accounts" \
        -H "Authorization: Bearer $KONNECT_TOKEN")

    PROVIDER_ACCOUNT_ID=$(echo "$PROVIDER_ACCOUNTS" | jq -r \
        ".data[] | select(.provider == \"aws\" and .region_id == \"ap-southeast-2\") | .id" | head -1)

    if [[ -z "$PROVIDER_ACCOUNT_ID" || "$PROVIDER_ACCOUNT_ID" == "null" ]]; then
        warn "Could not find provider account for ap-southeast-2."
        warn "Available regions:"
        echo "$PROVIDER_ACCOUNTS" | jq -r '.data[] | select(.provider == "aws") | "  \(.region_id)"'
        warn "You may need to create the network manually in Konnect UI."
        return
    fi

    NETWORK_RESPONSE=$(curl -s -X POST \
        "https://global.api.konghq.com/v2/cloud-gateways/networks" \
        -H "Authorization: Bearer $KONNECT_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{
            \"name\": \"${DCGW_NETWORK_NAME}\",
            \"cloud_gateway_provider_account_id\": \"${PROVIDER_ACCOUNT_ID}\",
            \"region\": \"ap-southeast-2\",
            \"availability_zones\": [\"apse2-az1\", \"apse2-az2\"],
            \"cidr_block\": \"${DCGW_CIDR}\"
        }")

    NETWORK_ID=$(echo "$NETWORK_RESPONSE" | jq -r '.id')

    if [[ -z "$NETWORK_ID" || "$NETWORK_ID" == "null" ]]; then
        error "Failed to create network"
        error "Response: $NETWORK_RESPONSE"
        warn "You may need to create this via Konnect UI instead."
        return
    fi

    log "  Network ID: ${NETWORK_ID}"
    log "  Network provisioning takes ~30 minutes. Check status in Konnect dashboard."
}

# ---------------------------------------------------------------------------
# Step 3: Create Data Plane Group Configuration
# ---------------------------------------------------------------------------
create_dp_group() {
    log "Step 3: Creating Data Plane Group Configuration"

    if [[ -z "${NETWORK_ID:-}" ]]; then
        warn "Network ID not available. Create data plane group manually in Konnect UI."
        return
    fi

    CONFIG_RESPONSE=$(curl -s -X PUT \
        "https://global.api.konghq.com/v2/cloud-gateways/configurations" \
        -H "Authorization: Bearer $KONNECT_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{
            \"control_plane_id\": \"${CONTROL_PLANE_ID}\",
            \"version\": \"${KONG_GW_VERSION}\",
            \"control_plane_geo\": \"au\",
            \"dataplane_groups\": [{
                \"provider\": \"aws\",
                \"region\": \"ap-southeast-2\",
                \"cloud_gateway_network_id\": \"${NETWORK_ID}\",
                \"autoscale\": {
                    \"kind\": \"autopilot\",
                    \"base_rps\": 100
                }
            }]
        }")

    CONFIG_ID=$(echo "$CONFIG_RESPONSE" | jq -r '.id // .message // "unknown"')
    log "  Configuration: $CONFIG_ID"
}

# ---------------------------------------------------------------------------
# Step 4: Attach Transit Gateway (optional)
# ---------------------------------------------------------------------------
attach_transit_gateway() {
    if [[ -z "${TRANSIT_GATEWAY_ID:-}" || -z "${RAM_SHARE_ARN:-}" || -z "${EKS_VPC_CIDR:-}" ]]; then
        echo ""
        warn "Transit Gateway variables not set. Skipping TGW attachment."
        warn "To connect to EKS services, set up Transit Gateway manually:"
        warn "  1. Create Transit Gateway in your AWS account"
        warn "  2. Share via AWS RAM with Kong's account"
        warn "  3. Attach in Konnect UI: API Gateway → Network → Attach Transit Gateway"
        return
    fi

    if [[ -z "${NETWORK_ID:-}" ]]; then
        warn "Network ID not available. Attach Transit Gateway manually in Konnect UI."
        return
    fi

    log "Step 4: Attaching Transit Gateway to Cloud Gateway Network"

    TGW_RESPONSE=$(curl -s -X POST \
        "https://global.api.konghq.com/v2/cloud-gateways/networks/${NETWORK_ID}/transit-gateways" \
        -H "Authorization: Bearer $KONNECT_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{
            \"name\": \"eks-transit-gateway\",
            \"transit_gateway_attachment_config\": {
                \"kind\": \"aws-transit-gateway-attachment\",
                \"transit_gateway_id\": \"${TRANSIT_GATEWAY_ID}\",
                \"ram_share_arn\": \"${RAM_SHARE_ARN}\",
                \"dns_config\": [],
                \"cidr_blocks\": [\"${EKS_VPC_CIDR}\"]
            }
        }")

    TGW_ID=$(echo "$TGW_RESPONSE" | jq -r '.id // .message // "unknown"')
    log "  Transit Gateway attachment: $TGW_ID"
    log "  Accept the attachment in AWS Console: VPC → Transit Gateway Attachments"
}

# ---------------------------------------------------------------------------
# Print next steps
# ---------------------------------------------------------------------------
show_next_steps() {
    echo ""
    echo "=========================================="
    echo "  Cloud Gateway Setup Summary"
    echo "=========================================="
    echo ""
    echo "Control Plane ID: ${CONTROL_PLANE_ID:-'N/A'}"
    echo "Network ID:       ${NETWORK_ID:-'N/A'}"
    echo "Region:           ${KONNECT_REGION}"
    echo ""
    echo "Next steps:"
    echo "  1. Wait for network provisioning (~30 minutes)"
    echo "     Check: https://cloud.konghq.com → API Gateway → Networks"
    echo ""
    echo "  2. Set up Transit Gateway (if not done above):"
    echo "     - Create Transit Gateway in your AWS account"
    echo "     - Share via AWS RAM with Kong's AWS account"
    echo "     - Attach in Konnect UI or via API"
    echo "     - Accept attachment in AWS Console"
    echo "     - Update VPC route tables"
    echo ""
    echo "  3. Configure DNS for backend services:"
    echo "     - Create Route53 Private Hosted Zone"
    echo "     - Add records for internal NLB endpoints"
    echo "     - Associate with Cloud Gateway network in Konnect"
    echo ""
    echo "  4. Configure routes in Konnect:"
    echo "     deck gateway sync -s deck/kong.yaml"
    echo ""
    echo "  5. Verify data plane nodes:"
    echo "     https://cloud.konghq.com → Gateway Manager → Data Plane Nodes"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo "=============================================="
    echo "  Kong Konnect Dedicated Cloud Gateway Setup"
    echo "=============================================="
    echo ""

    validate_env
    create_control_plane
    create_network
    create_dp_group
    attach_transit_gateway
    show_next_steps
}

main "$@"
