# EKS Kong Konnect Cloud Gateway - CloudFront Distribution Variables
# @author Shanaka Jayasundera - shanakaj@gmail.com

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

# Kong Cloud Gateway Origin
variable "kong_cloud_gateway_domain" {
  description = "Kong Cloud Gateway proxy domain (e.g., <prefix>.au.kong-cloud.com). Get from Konnect dashboard → Gateway Manager → Data Plane Groups."
  type        = string
}

# CloudFront Bypass Prevention
variable "cf_origin_header_name" {
  description = "Custom header name injected by CloudFront for origin verification (CloudFront bypass prevention)"
  type        = string
  default     = "X-CF-Secret"
}

variable "cf_origin_header_value" {
  description = "Secret value for the custom origin header. Kong Cloud Gateway validates this via a pre-function or request-validator plugin."
  type        = string
  sensitive   = true
}

# S3 Origin Configuration (optional)
variable "enable_s3_origin" {
  description = "Enable S3 origin for static assets"
  type        = bool
  default     = false
}

variable "s3_bucket_regional_domain_name" {
  description = "S3 bucket regional domain name"
  type        = string
  default     = ""
}

variable "s3_bucket_arn" {
  description = "S3 bucket ARN (for OAC policy)"
  type        = string
  default     = ""
}

# WAF Configuration
variable "enable_waf" {
  description = "Enable WAF Web ACL on CloudFront"
  type        = bool
  default     = true
}

variable "enable_rate_limiting" {
  description = "Enable rate limiting rule in WAF"
  type        = bool
  default     = true
}

variable "rate_limit" {
  description = "Rate limit threshold (requests per 5 minutes per IP)"
  type        = number
  default     = 2000
}

# SSL/TLS Configuration
variable "acm_certificate_arn" {
  description = "ACM certificate ARN for custom domain (must be in us-east-1)"
  type        = string
  default     = ""
}

variable "custom_domain" {
  description = "Custom domain for CloudFront distribution"
  type        = string
  default     = ""
}

# Cache Configuration
variable "price_class" {
  description = "CloudFront price class"
  type        = string
  default     = "PriceClass_100" # US, Canada, Europe
}

# Geo Restriction
variable "geo_restriction_type" {
  description = "Geo restriction type (none, whitelist, blacklist)"
  type        = string
  default     = "none"
}

variable "geo_restriction_locations" {
  description = "List of country codes for geo restriction"
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags for resources"
  type        = map(string)
  default     = {}
}
