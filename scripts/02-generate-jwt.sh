#!/bin/bash
# EKS Kong Konnect Cloud Gateway - Generate JWT Token for Demo Testing
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Generates an HS256 JWT token that authenticates against the demo-user
# JWT credential configured in Konnect (see deck/kong.yaml for reference).
#
# Usage:
#   ./scripts/02-generate-jwt.sh              # Token valid for 1 hour
#   ./scripts/02-generate-jwt.sh 3600         # Token valid for 3600 seconds
#
# The generated token can be used as:
#   curl -H "Authorization: Bearer <token>" <CLOUD_GW_URL>/api/users

set -e

# Configuration - must match the JWT credential configured in Konnect
JWT_ISS="demo-issuer"
JWT_SECRET="demo-secret-key-do-not-use-in-production"
EXPIRY_SECONDS="${1:-3600}"

# Helper: base64url encode (no padding, URL-safe)
base64url() {
    openssl base64 -e -A | tr '+/' '-_' | tr -d '='
}

# JWT Header
HEADER=$(printf '{"alg":"HS256","typ":"JWT"}' | base64url)

# JWT Payload
NOW=$(date +%s)
EXP=$((NOW + EXPIRY_SECONDS))
PAYLOAD=$(printf '{"iss":"%s","iat":%d,"exp":%d}' "$JWT_ISS" "$NOW" "$EXP" | base64url)

# JWT Signature (HMAC-SHA256)
SIGNATURE=$(printf '%s.%s' "$HEADER" "$PAYLOAD" \
  | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary \
  | base64url)

# Assemble token
TOKEN="${HEADER}.${PAYLOAD}.${SIGNATURE}"

echo "=== JWT Token Generated ==="
echo ""
echo "Issuer:  ${JWT_ISS}"
echo "Issued:  $(date -r "$NOW" 2>/dev/null || date -d "@$NOW" 2>/dev/null)"
echo "Expires: $(date -r "$EXP" 2>/dev/null || date -d "@$EXP" 2>/dev/null)"
echo ""
echo "Token:"
echo "${TOKEN}"
echo ""
echo "=== Usage ==="
echo ""
echo "curl -H \"Authorization: Bearer ${TOKEN}\" \${CLOUD_GW_URL}/api/users"
