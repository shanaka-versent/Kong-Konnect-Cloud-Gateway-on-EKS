# EKS Kong Konnect Cloud Gateway - IAM Module Outputs
# @author Shanaka Jayasundera - shanakaj@gmail.com

output "lb_controller_role_arn" {
  description = "AWS Load Balancer Controller IAM role ARN"
  value       = aws_iam_role.lb_controller.arn
}

output "lb_controller_policy_arn" {
  description = "AWS Load Balancer Controller IAM policy ARN"
  value       = aws_iam_policy.lb_controller.arn
}

output "external_secrets_role_arn" {
  description = "External Secrets Operator IAM role ARN (for IRSA)"
  value       = var.enable_external_secrets ? aws_iam_role.external_secrets[0].arn : ""
}
