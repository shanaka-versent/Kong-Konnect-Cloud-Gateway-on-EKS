# EKS Kong Konnect Cloud Gateway - IAM Module Variables
# @author Shanaka Jayasundera - shanakaj@gmail.com

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS OIDC provider ARN for IRSA role federation"
  type        = string
}

variable "oidc_provider_url" {
  description = "EKS OIDC provider URL without https:// for trust policy conditions"
  type        = string
}

variable "enable_external_secrets" {
  description = "Enable External Secrets Operator IRSA role"
  type        = bool
  default     = true
}

variable "enable_cognito" {
  description = "Enable Cognito auth-service IRSA role"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags for resources"
  type        = map(string)
  default     = {}
}
