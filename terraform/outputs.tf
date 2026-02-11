# EKS Kong Konnect Cloud Gateway - Terraform Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

# VPC Outputs
output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = module.vpc.vpc_cidr
}

# EKS Outputs
output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "eks_get_credentials_command" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

# ArgoCD Outputs
output "argocd_admin_password" {
  description = "ArgoCD admin password"
  value       = module.argocd.admin_password
  sensitive   = true
}

output "argocd_port_forward_command" {
  description = "Command to access ArgoCD UI"
  value       = "kubectl port-forward svc/argocd-server -n argocd 8080:443"
}

# LB Controller
output "lb_controller_role_arn" {
  description = "AWS Load Balancer Controller IAM role ARN"
  value       = module.iam.lb_controller_role_arn
}

# ==============================================================================
# TRANSIT GATEWAY OUTPUTS
# Use these values when configuring Kong Cloud Gateway in Konnect
# ==============================================================================

output "transit_gateway_id" {
  description = "Transit Gateway ID — provide to Konnect when attaching Cloud Gateway network"
  value       = aws_ec2_transit_gateway.kong.id
}

output "transit_gateway_arn" {
  description = "Transit Gateway ARN"
  value       = aws_ec2_transit_gateway.kong.arn
}

output "ram_share_arn" {
  description = "RAM Resource Share ARN — provide to Konnect for Transit Gateway attachment"
  value       = aws_ram_resource_share.kong_tgw.arn
}

# ==============================================================================
# CLOUDFRONT OUTPUTS (conditional)
# ==============================================================================

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID"
  value       = var.enable_cloudfront ? module.cloudfront[0].distribution_id : null
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name"
  value       = var.enable_cloudfront ? module.cloudfront[0].distribution_domain_name : null
}

output "cloudfront_url" {
  description = "CloudFront URL"
  value       = var.enable_cloudfront ? "https://${module.cloudfront[0].distribution_domain_name}" : null
}

output "waf_web_acl_arn" {
  description = "WAF Web ACL ARN"
  value       = var.enable_cloudfront ? module.cloudfront[0].waf_web_acl_arn : null
}

output "application_url" {
  description = "Application URL (CloudFront if enabled, otherwise Kong Cloud Gateway proxy URL)"
  value       = var.enable_cloudfront ? "https://${module.cloudfront[0].distribution_domain_name}" : "https://${var.kong_cloud_gateway_domain}"
}

# ==============================================================================
# KONG CLOUD GATEWAY SETUP
# ==============================================================================

output "kong_cloud_gateway_setup_command" {
  description = "Command to set up Kong Cloud Gateway with Transit Gateway"
  value       = <<-EOT
    # 1. Ensure .env has KONNECT_REGION and KONNECT_TOKEN set
    #    (Transit Gateway values are auto-read from Terraform outputs)

    # 2. Run the setup script:
    ./scripts/02-setup-cloud-gateway.sh

    # Auto-populated from Terraform:
    #   TRANSIT_GATEWAY_ID = ${aws_ec2_transit_gateway.kong.id}
    #   RAM_SHARE_ARN      = ${aws_ram_resource_share.kong_tgw.arn}
    #   EKS_VPC_CIDR       = ${module.vpc.vpc_cidr}
  EOT
}
