# EKS Kong Konnect Cloud Gateway - Main Terraform Configuration
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Kong Dedicated Cloud Gateway with EKS backend services.
# Kong data plane runs in Kong's managed infrastructure (not in EKS).
# Backend services in EKS are exposed via internal NLBs.
# Kong Cloud Gateway reaches backends via AWS Transit Gateway.
#
# Architecture Layers:
# ===================
# Layer 1: Cloud Foundations (Terraform)
#   - VPC, Subnets, NAT Gateway, Internet Gateway
#
# Layer 2: Base EKS Cluster Setup (Terraform)
#   - EKS Cluster, Node Groups, OIDC Provider
#   - IAM Roles (LB Controller IRSA)
#   - AWS Load Balancer Controller (creates internal NLBs for backend services)
#   - AWS Transit Gateway (for Kong Cloud Gateway ↔ EKS connectivity)
#   - ArgoCD Installation
#
# Layer 3: Backend Applications (ArgoCD)
#   - Sample Applications (app1, app2)
#   - Users API
#   - Health Responder
#   - Each exposed via internal NLB
#
# Layer 4: API Configuration (Konnect)
#   - Kong Cloud Gateway provisioned in Konnect (Kong's infrastructure)
#   - Routes, plugins, consumers via decK / Konnect UI
#   - Service upstreams point to internal NLB DNS names
#
# Layer 5: Edge Security (Terraform — optional)
#   - CloudFront distribution with WAF (DDoS, SQLi, XSS, rate limiting)
#   - Custom origin header for CloudFront bypass prevention
#   - Security response headers (HSTS, X-Frame-Options, etc.)
#
# Traffic Flow (with CloudFront):
# Client --> CloudFront (WAF) --> Kong Cloud GW (Kong's infra) --[Transit GW]--> Internal NLBs --> EKS
#
# Traffic Flow (without CloudFront):
# Client --> Kong Cloud GW (Kong's infra) --[Transit GW]--> Internal NLBs --> EKS Pods

locals {
  name_prefix  = "${var.project_name}-${var.environment}"
  cluster_name = "eks-${local.name_prefix}"
}

# ==============================================================================
# LAYER 1: CLOUD FOUNDATIONS
# ==============================================================================

# VPC Module - Network infrastructure
module "vpc" {
  source = "./modules/vpc"

  name_prefix        = local.name_prefix
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  cluster_name       = local.cluster_name
  enable_nat_gateway = var.enable_nat_gateway
  tags               = var.tags
}

# ==============================================================================
# LAYER 2: BASE EKS CLUSTER SETUP
# ==============================================================================

# EKS Module - Kubernetes cluster (hosts backend services only)
module "eks" {
  source = "./modules/eks"

  name_prefix        = local.name_prefix
  cluster_name       = local.cluster_name
  kubernetes_version = var.kubernetes_version

  # Use private subnets for cluster, private for nodes
  subnet_ids      = concat(module.vpc.public_subnet_ids, module.vpc.private_subnet_ids)
  node_subnet_ids = module.vpc.private_subnet_ids

  # System Node Pool
  system_node_count         = var.eks_node_count
  system_node_instance_type = var.eks_node_instance_type
  system_node_min_count     = var.system_node_min_count
  system_node_max_count     = var.system_node_max_count

  # User Node Pool (optional)
  enable_user_node_pool   = var.enable_user_node_pool
  user_node_count         = var.user_node_count
  user_node_instance_type = var.user_node_instance_type
  user_node_min_count     = var.user_node_min_count
  user_node_max_count     = var.user_node_max_count

  # Autoscaling
  enable_autoscaling = var.enable_eks_autoscaling

  # Logging
  enable_logging = var.enable_logging

  tags = var.tags
}

# IAM Module - AWS Load Balancer Controller IRSA role
module "iam" {
  source = "./modules/iam"

  name_prefix       = local.name_prefix
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  tags              = var.tags
}

# AWS Load Balancer Controller - Creates internal NLBs for backend services
# Backend services use type: LoadBalancer with internal NLB annotations.
# The LB Controller reconciles these into AWS internal NLBs that Kong Cloud
# Gateway can reach via Transit Gateway.
module "lb_controller" {
  source = "./modules/lb-controller"

  cluster_name       = module.eks.cluster_name
  iam_role_arn       = module.iam.lb_controller_role_arn
  region             = var.region
  vpc_id             = module.vpc.vpc_id
  cluster_dependency = module.eks.cluster_name
}

# Wait for LB Controller to be ready
resource "time_sleep" "wait_for_lb_controller" {
  depends_on      = [module.lb_controller]
  create_duration = "30s"
}

# ==============================================================================
# TRANSIT GATEWAY — Kong Cloud Gateway ↔ EKS Private Connectivity
# ==============================================================================
# Creates an AWS Transit Gateway and shares it via RAM so Kong's Cloud Gateway
# can establish private network connectivity to the EKS VPC.
#
# After terraform apply:
# 1. Run scripts/01-setup-cloud-gateway.sh to create Cloud GW and attach TGW
# 2. Accept the TGW attachment in AWS Console (VPC → Transit Gateway Attachments)
# 3. Update VPC route tables to route Kong's CIDR (192.168.0.0/16) via TGW

resource "aws_ec2_transit_gateway" "kong" {
  description = "Transit Gateway for Kong Cloud Gateway connectivity"

  amazon_side_asn                 = 64512
  auto_accept_shared_attachments  = "enable"
  default_route_table_association = "enable"
  default_route_table_propagation = "enable"
  dns_support                     = "enable"
  vpn_ecmp_support                = "enable"

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-kong-tgw"
  })
}

# Attach EKS VPC to Transit Gateway
resource "aws_ec2_transit_gateway_vpc_attachment" "eks" {
  subnet_ids         = module.vpc.private_subnet_ids
  transit_gateway_id = aws_ec2_transit_gateway.kong.id
  vpc_id             = module.vpc.vpc_id

  dns_support = "enable"

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-eks-tgw-attachment"
  })
}

# Route Kong Cloud Gateway CIDR (192.168.0.0/16) through Transit Gateway
# This allows return traffic from EKS to reach Kong's Cloud Gateway
resource "aws_route" "kong_cloud_gw" {
  count = length(module.vpc.private_route_table_ids)

  route_table_id         = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block = var.kong_cloud_gateway_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.kong.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.eks]
}

# Share Transit Gateway with Kong's AWS account via RAM
resource "aws_ram_resource_share" "kong_tgw" {
  name                      = "${local.name_prefix}-kong-tgw-share"
  allow_external_principals = true

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-kong-tgw-share"
  })
}

resource "aws_ram_resource_association" "kong_tgw" {
  resource_arn       = aws_ec2_transit_gateway.kong.arn
  resource_share_arn = aws_ram_resource_share.kong_tgw.arn
}

# Note: Kong's AWS account ID will be shown in the Konnect Cloud Gateway UI
# during network setup. Add it as a RAM principal:
#
# resource "aws_ram_principal_association" "kong_account" {
#   principal          = "<KONG_AWS_ACCOUNT_ID>"  # Shown in Konnect UI
#   resource_share_arn = aws_ram_resource_share.kong_tgw.arn
# }

# Security Group rule: Allow inbound from Kong Cloud Gateway CIDR
resource "aws_security_group_rule" "allow_kong_cloud_gw" {
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
  cidr_blocks       = [var.kong_cloud_gateway_cidr]
  security_group_id = module.eks.cluster_security_group_id
  description       = "Allow inbound from Kong Cloud Gateway via Transit Gateway"
}

# ==============================================================================
# LAYER 5: EDGE SECURITY — CloudFront + WAF (Optional)
# ==============================================================================
# Places CloudFront + WAF in front of Kong's Cloud Gateway proxy URL.
#
# Why: Kong Cloud Gateway has a public NLB. Adding CloudFront provides:
# - AWS WAF (DDoS protection, SQLi/XSS filtering, rate limiting, geo-blocking)
# - Security response headers (HSTS, X-Frame-Options, etc.)
# - CloudFront edge caching for static assets (optional)
# - Custom domain with ACM certificate
#
# CloudFront Bypass Prevention (two layers, either or both):
#
# 1. Origin mTLS (recommended, strongest):
#    CloudFront presents a client certificate during TLS handshake with Kong.
#    Kong validates the cert → rejects non-CloudFront connections.
#    Requires: ACM certificate in us-east-1 with clientAuth EKU.
#
# 2. Custom origin header (application-layer):
#    CloudFront injects X-CF-Secret. Kong pre-function validates it.
#    Simpler but weaker (shared secret).
#
# After terraform apply (if using custom header):
# 1. Edit deck/kong.yaml — uncomment the pre-function plugin
# 2. Set the secret value matching cf_origin_header_value
# 3. Sync: deck gateway sync -s deck/kong.yaml ...

module "cloudfront" {
  count  = var.enable_cloudfront ? 1 : 0
  source = "./modules/cloudfront"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name_prefix = local.name_prefix

  # Kong Cloud Gateway proxy URL (set after Cloud GW is provisioned)
  kong_cloud_gateway_domain = var.kong_cloud_gateway_domain

  # CloudFront bypass prevention — Layer 1: Origin mTLS
  origin_mtls_certificate_arn = var.origin_mtls_certificate_arn

  # CloudFront bypass prevention — Layer 2: Custom origin header
  cf_origin_header_name  = var.cf_origin_header_name
  cf_origin_header_value = var.cf_origin_header_value

  # WAF
  enable_waf          = var.enable_waf
  enable_rate_limiting = var.enable_waf_rate_limiting
  rate_limit          = var.waf_rate_limit

  # TLS
  acm_certificate_arn = var.cloudfront_certificate_arn
  custom_domain       = var.cloudfront_custom_domain

  # CloudFront
  price_class = var.cloudfront_price_class

  tags = var.tags
}

# ==============================================================================
# PRE-DESTROY CLEANUP
# Use ./scripts/destroy.sh for clean teardown. It deletes ArgoCD apps,
# removes internal NLBs, and runs terraform destroy.
# Kong Cloud Gateway must be deleted separately in Konnect.
# ==============================================================================

# ==============================================================================
# ARGOCD - GITOPS CONTINUOUS DELIVERY
# ==============================================================================

# ArgoCD - GitOps continuous delivery
module "argocd" {
  source = "./modules/argocd"

  argocd_version     = var.argocd_version
  service_type       = var.argocd_service_type
  insecure_mode      = true
  cluster_dependency = module.eks.cluster_name
}
