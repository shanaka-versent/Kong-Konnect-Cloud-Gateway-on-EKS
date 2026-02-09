#!/bin/bash
# EKS Kong Konnect Cloud Gateway - Automated Stack Teardown
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Tears down the EKS infrastructure. The Kong Cloud Gateway (in Kong's infra)
# must be deleted separately via Konnect UI or API.
#
# DESTRUCTION ORDER:
# ==================
# 1. Delete ArgoCD applications (cascade deletes K8s resources)
# 2. Wait for LoadBalancer services (internal NLBs) to be removed
# 3. Run terraform destroy (handles EKS, VPC, Transit Gateway)
# 4. Remind to delete Cloud Gateway in Konnect

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
# Step 1: Delete ArgoCD applications
# ---------------------------------------------------------------------------
delete_argocd_apps() {
    log "Step 1: Deleting ArgoCD applications..."

    if kubectl get app cloud-gateway-root -n argocd &>/dev/null; then
        kubectl delete app cloud-gateway-root -n argocd --timeout=300s 2>/dev/null || true
        log "Waiting for ArgoCD cascade deletion..."
        kubectl wait --for=delete app/cloud-gateway-root -n argocd --timeout=300s 2>/dev/null || true
    fi

    # Safety net
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
# Step 2: Wait for internal NLBs to deprovision
# ---------------------------------------------------------------------------
delete_loadbalancer_services() {
    log "Step 2: Checking for remaining LoadBalancer services..."

    local lb_services
    lb_services=$(kubectl get svc --all-namespaces -o json 2>/dev/null | \
        jq -r '.items[] | select(.spec.type == "LoadBalancer") | "\(.metadata.namespace)/\(.metadata.name)"' || true)

    if [[ -n "$lb_services" ]]; then
        warn "Found LoadBalancer services (internal NLBs):"
        echo "$lb_services" | while read -r svc; do echo "  - $svc"; done

        echo "$lb_services" | while read -r svc; do
            local ns="${svc%%/*}"
            local name="${svc##*/}"
            kubectl delete svc "$name" -n "$ns" --timeout=120s 2>/dev/null || true
        done

        log "Waiting 90s for internal NLBs to deprovision..."
        sleep 90
    else
        log "No LoadBalancer services found."
    fi
}

# ---------------------------------------------------------------------------
# Step 3: Cleanup K8s namespaces
# ---------------------------------------------------------------------------
cleanup_k8s_resources() {
    log "Step 3: Cleaning up K8s resources..."

    for ns in api tenant-app1 tenant-app2 gateway-health; do
        if kubectl get ns "$ns" &>/dev/null; then
            kubectl delete ns "$ns" --timeout=120s 2>/dev/null || true
        fi
    done

    log "K8s cleanup complete."
}

# ---------------------------------------------------------------------------
# Step 4: Terraform destroy
# ---------------------------------------------------------------------------
terraform_destroy() {
    log "Step 4: Running terraform destroy..."

    cd "$TERRAFORM_DIR"

    if [[ ! -d ".terraform" ]]; then
        terraform init
    fi

    terraform destroy -auto-approve

    log "Terraform destroy complete."
}

# ---------------------------------------------------------------------------
# Step 5: Remind about Konnect cleanup
# ---------------------------------------------------------------------------
remind_konnect_cleanup() {
    echo ""
    echo "=========================================="
    echo "  Konnect Cleanup Required"
    echo "=========================================="
    echo ""
    echo "The Kong Cloud Gateway runs in Kong's infrastructure."
    echo "Delete it separately via:"
    echo ""
    echo "  Option A: Konnect UI"
    echo "    https://cloud.konghq.com → Gateway Manager → Delete"
    echo ""
    echo "  Option B: Konnect API"
    echo "    curl -X DELETE \"https://\${KONNECT_REGION}.api.konghq.com/v2/control-planes/\${CP_ID}\" \\"
    echo "      -H \"Authorization: Bearer \$KONNECT_TOKEN\""
    echo ""
    echo "  Option C: Terraform (if using konnect provider)"
    echo "    terraform destroy -chdir=terraform/konnect"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo "================================================="
    echo "  Kong Cloud Gateway EKS - Stack Teardown"
    echo "================================================="
    echo ""

    local k8s_available=true
    preflight_checks || k8s_available=false

    if [[ "$k8s_available" == true ]]; then
        delete_argocd_apps
        delete_loadbalancer_services
        cleanup_k8s_resources
    else
        warn "Skipping K8s cleanup. Running terraform destroy directly."
    fi

    terraform_destroy
    remind_konnect_cleanup

    echo ""
    log "EKS stack teardown complete."
    log "Remember to delete the Cloud Gateway in Konnect (see above)."
    echo ""
}

main "$@"
