#!/bin/bash
# Kong Cloud Gateway on EKS - Automated Stack Teardown
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Tears down the EKS infrastructure including Istio Gateway and Ambient mesh.
# The Kong Cloud Gateway (in Kong's AWS account) must be deleted separately
# via Konnect UI or API.
#
# DESTRUCTION ORDER:
# ==================
# 1. Delete Istio Gateway resource (triggers NLB deprovisioning via LB Controller)
# 2. Wait for Internal NLB to be fully deprovisioned
# 3. Delete ArgoCD applications (cascade deletes Istio components, apps)
# 4. Cleanup Istio CRDs and remaining K8s resources
# 5. Run terraform destroy (handles EKS, VPC, Transit Gateway, RAM share)
# 6. Remind to delete Cloud Gateway in Konnect (Kong's AWS account)
#
# WHY THIS ORDER:
# The Istio Gateway creates an internal NLB via the AWS LB Controller.
# If we delete EKS before the NLB is deprovisioned, the NLB and its
# ENIs will be orphaned, blocking VPC deletion in terraform destroy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/.."
TERRAFORM_DIR="${REPO_DIR}/terraform"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*"; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
preflight_checks() {
    log "Running pre-flight checks..."

    for cmd in kubectl aws terraform jq; do
        if ! command -v "$cmd" &>/dev/null; then
            error "$cmd is required but not installed."
            exit 1
        fi
    done

    if ! kubectl cluster-info &>/dev/null; then
        warn "Cannot connect to Kubernetes cluster. Skipping K8s cleanup steps."
        return 1
    fi

    log "Pre-flight checks passed."
    return 0
}

# ---------------------------------------------------------------------------
# Step 1: Delete Istio Gateway (triggers NLB deprovisioning)
# ---------------------------------------------------------------------------
delete_istio_gateway() {
    log "Step 1: Deleting Istio Gateway resource (triggers NLB removal)..."

    # Delete the Gateway resource first -- this tells the LB Controller
    # to deprovision the internal NLB that Kong connects to via Transit GW
    if kubectl get gateway kong-cloud-gw-gateway -n istio-ingress &>/dev/null; then
        kubectl delete gateway kong-cloud-gw-gateway -n istio-ingress --timeout=120s 2>/dev/null || true
        log "Istio Gateway deleted. NLB deprovisioning initiated."
    else
        log "Istio Gateway not found (already deleted or not deployed)."
    fi

    # Also delete any HTTPRoutes to clean up references
    if kubectl get httproute -n gateway-health &>/dev/null 2>&1; then
        kubectl delete httproute --all -n gateway-health --timeout=60s 2>/dev/null || true
    fi
    if kubectl get httproute -n sample-apps &>/dev/null 2>&1; then
        kubectl delete httproute --all -n sample-apps --timeout=60s 2>/dev/null || true
    fi
    if kubectl get httproute -n api-services &>/dev/null 2>&1; then
        kubectl delete httproute --all -n api-services --timeout=60s 2>/dev/null || true
    fi

    log "Gateway and HTTPRoute resources deleted."
}

# ---------------------------------------------------------------------------
# Step 2: Wait for NLB to be fully deprovisioned
# ---------------------------------------------------------------------------
wait_for_nlb_cleanup() {
    log "Step 2: Waiting for Internal NLB to be deprovisioned..."

    # Check if any LoadBalancer services remain (created by Istio Gateway)
    local lb_services
    lb_services=$(kubectl get svc --all-namespaces -o json 2>/dev/null | \
        jq -r '.items[] | select(.spec.type == "LoadBalancer") | "\(.metadata.namespace)/\(.metadata.name)"' || true)

    if [[ -n "$lb_services" ]]; then
        warn "Found remaining LoadBalancer services:"
        echo "$lb_services" | while read -r svc; do echo "  - $svc"; done

        # Force delete any remaining LB services
        echo "$lb_services" | while read -r svc; do
            local ns="${svc%%/*}"
            local name="${svc##*/}"
            kubectl delete svc "$name" -n "$ns" --timeout=120s 2>/dev/null || true
        done
    fi

    # Wait for AWS to fully remove the NLB and release ENIs
    # This prevents "DependencyViolation" errors during terraform destroy
    log "Waiting 90s for AWS to fully deprovision NLB and release ENIs..."
    sleep 90
    log "NLB cleanup wait complete."
}

# ---------------------------------------------------------------------------
# Step 3: Delete ArgoCD applications (cascade deletes everything)
# ---------------------------------------------------------------------------
delete_argocd_apps() {
    log "Step 3: Deleting ArgoCD applications..."

    if kubectl get app cloud-gateway-root -n argocd &>/dev/null; then
        kubectl delete app cloud-gateway-root -n argocd --timeout=300s 2>/dev/null || true
        log "Waiting for ArgoCD cascade deletion (Istio components, apps)..."
        kubectl wait --for=delete app/cloud-gateway-root -n argocd --timeout=300s 2>/dev/null || true
    fi

    # Safety net - delete any remaining ArgoCD apps
    local remaining_apps
    remaining_apps=$(kubectl get app -n argocd -o name 2>/dev/null || true)
    if [[ -n "$remaining_apps" ]]; then
        warn "Deleting remaining ArgoCD apps..."
        echo "$remaining_apps" | while read -r app; do
            kubectl delete "$app" -n argocd --timeout=120s 2>/dev/null || true
        done
    fi

    log "ArgoCD applications deleted."
}

# ---------------------------------------------------------------------------
# Step 4: Cleanup Istio CRDs and K8s namespaces
# ---------------------------------------------------------------------------
cleanup_k8s_resources() {
    log "Step 4: Cleaning up Istio and K8s resources..."

    # Delete application namespaces
    for ns in istio-ingress gateway-health sample-apps api-services; do
        if kubectl get ns "$ns" &>/dev/null; then
            log "Deleting namespace: $ns"
            kubectl delete ns "$ns" --timeout=120s 2>/dev/null || true
        fi
    done

    # Delete Istio system namespace (contains istiod, cni, ztunnel)
    if kubectl get ns istio-system &>/dev/null; then
        log "Deleting namespace: istio-system"
        kubectl delete ns istio-system --timeout=180s 2>/dev/null || true
    fi

    # Cleanup Gateway API CRDs (may have finalizers)
    log "Cleaning up Gateway API CRDs..."
    for crd in gateways.gateway.networking.k8s.io \
               httproutes.gateway.networking.k8s.io \
               referencegrants.gateway.networking.k8s.io \
               gatewayclasses.gateway.networking.k8s.io \
               grpcroutes.gateway.networking.k8s.io \
               tcproutes.gateway.networking.k8s.io \
               tlsroutes.gateway.networking.k8s.io \
               udproutes.gateway.networking.k8s.io \
               backendtlspolicies.gateway.networking.k8s.io \
               backendlbpolicies.gateway.networking.k8s.io; do
        if kubectl get crd "$crd" &>/dev/null; then
            kubectl delete crd "$crd" --timeout=60s 2>/dev/null || true
        fi
    done

    # Cleanup Istio CRDs
    log "Cleaning up Istio CRDs..."
    kubectl get crd -o name 2>/dev/null | grep -E 'istio\.io|tetrate\.io' | while read -r crd; do
        kubectl delete "$crd" --timeout=60s 2>/dev/null || true
    done

    log "K8s cleanup complete."
}

# ---------------------------------------------------------------------------
# Step 5: Terraform destroy
# ---------------------------------------------------------------------------
terraform_destroy() {
    log "Step 5: Running terraform destroy..."

    cd "$TERRAFORM_DIR"

    if [[ ! -d ".terraform" ]]; then
        terraform init
    fi

    terraform destroy -auto-approve

    log "Terraform destroy complete."
}

# ---------------------------------------------------------------------------
# Step 6: Remind about Konnect cleanup (Kong's AWS account)
# ---------------------------------------------------------------------------
remind_konnect_cleanup() {
    echo ""
    echo "=========================================="
    echo "  Konnect Cleanup Required"
    echo "=========================================="
    echo ""
    echo "The Kong Cloud Gateway runs in KONG'S AWS account (not yours)."
    echo "It must be deleted separately via:"
    echo ""
    echo "  Option A: Konnect UI"
    echo "    https://cloud.konghq.com -> Gateway Manager -> Delete"
    echo ""
    echo "  Option B: Konnect API"
    echo "    curl -X DELETE \"https://\${KONNECT_REGION}.api.konghq.com/v2/control-planes/\${CP_ID}\" \\"
    echo "      -H \"Authorization: Bearer \$KONNECT_TOKEN\""
    echo ""
    echo "  Option C: Terraform (if using konnect provider)"
    echo "    terraform destroy -chdir=terraform/konnect"
    echo ""
    echo "NOTE: The Transit Gateway attachment on Kong's side will be"
    echo "automatically cleaned up when the Cloud Gateway is deleted."
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo "================================================="
    echo "  Kong Cloud Gateway EKS - Stack Teardown"
    echo "  (Istio Gateway + Ambient Mesh + Kong Cloud GW)"
    echo "================================================="
    echo ""
    echo "This will destroy:"
    echo "  - Istio Gateway (internal NLB)"
    echo "  - Istio Ambient mesh (istiod, cni, ztunnel)"
    echo "  - All backend applications"
    echo "  - ArgoCD and all managed apps"
    echo "  - EKS cluster, VPC, Transit Gateway"
    echo ""
    echo "This will NOT destroy:"
    echo "  - Kong Cloud Gateway (in Kong's AWS account)"
    echo "    → Delete separately in Konnect"
    echo ""

    local k8s_available=true
    preflight_checks || k8s_available=false

    if [[ "$k8s_available" == true ]]; then
        delete_istio_gateway
        wait_for_nlb_cleanup
        delete_argocd_apps
        cleanup_k8s_resources
    else
        warn "Skipping K8s cleanup. Running terraform destroy directly."
        warn "If terraform fails due to orphaned NLBs, manually delete them in AWS Console:"
        warn "  EC2 -> Load Balancers -> Delete internal NLBs"
        warn "  Then re-run terraform destroy."
    fi

    terraform_destroy
    remind_konnect_cleanup

    echo ""
    log "EKS stack teardown complete."
    log "Remember to delete the Cloud Gateway in Konnect (see above)."
    echo ""
}

main "$@"
