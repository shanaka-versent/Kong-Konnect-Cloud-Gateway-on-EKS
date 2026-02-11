#!/bin/bash
# Kong Cloud Gateway on EKS - Generate TLS Certificates for Istio Gateway
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Generates self-signed TLS certificates for the Istio Gateway HTTPS listener.
# These certificates are OPTIONAL -- Kong Cloud Gateway can connect to the
# Istio Gateway internal NLB on port 80 (HTTP).
#
# If you want end-to-end TLS (Kong -> NLB -> Istio Gateway over HTTPS),
# run this script and create the TLS secret before deploying the Gateway.
#
# TLS Flow:
#   Kong Cloud GW --[HTTP/HTTPS]--> Transit GW --> Internal NLB --> Istio Gateway --[mTLS/Ambient]--> Pods

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="${SCRIPT_DIR}/../certs"
DOMAIN="${1:-kong-cloud-gw-poc.local}"
GATEWAY_NAME="kong-cloud-gw-gateway"

echo "=== Generating TLS Certificates for Istio Gateway ==="
echo ""
echo "Domain: ${DOMAIN}"
echo "Output directory: ${CERTS_DIR}"

mkdir -p "${CERTS_DIR}"

# Generate CA private key
echo "Generating CA private key..."
openssl genrsa -out "${CERTS_DIR}/ca.key" 4096

# Generate CA certificate
echo "Generating CA certificate..."
openssl req -new -x509 -days 365 -key "${CERTS_DIR}/ca.key" \
  -out "${CERTS_DIR}/ca.crt" \
  -subj "/C=AU/ST=NSW/L=Sydney/O=Kong Cloud GW POC/CN=Kong Cloud GW POC CA"

# Generate server private key
echo "Generating server private key..."
openssl genrsa -out "${CERTS_DIR}/server.key" 2048

# Create OpenSSL config for SAN
cat > "${CERTS_DIR}/server.cnf" << EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
C = AU
ST = NSW
L = Sydney
O = Kong Cloud GW POC
CN = ${DOMAIN}

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${DOMAIN}
DNS.2 = *.${DOMAIN}
DNS.3 = localhost
DNS.4 = ${GATEWAY_NAME}-istio.istio-ingress.svc.cluster.local
IP.1 = 127.0.0.1
EOF

# Generate server CSR
echo "Generating server CSR..."
openssl req -new -key "${CERTS_DIR}/server.key" \
  -out "${CERTS_DIR}/server.csr" \
  -config "${CERTS_DIR}/server.cnf"

# Sign server certificate with CA
echo "Signing server certificate..."
openssl x509 -req -days 365 \
  -in "${CERTS_DIR}/server.csr" \
  -CA "${CERTS_DIR}/ca.crt" \
  -CAkey "${CERTS_DIR}/ca.key" \
  -CAcreateserial \
  -out "${CERTS_DIR}/server.crt" \
  -extensions req_ext \
  -extfile "${CERTS_DIR}/server.cnf"

# Cleanup
rm -f "${CERTS_DIR}/server.csr" "${CERTS_DIR}/server.cnf" "${CERTS_DIR}/ca.srl"

echo ""
echo "=== Certificates Generated Successfully ==="
echo ""
echo "Files created:"
echo "  CA Certificate:     ${CERTS_DIR}/ca.crt"
echo "  Server Certificate: ${CERTS_DIR}/server.crt"
echo "  Server Key:         ${CERTS_DIR}/server.key"
echo ""
echo "=== Next Steps ==="
echo ""
echo "1. Create the Kubernetes TLS secret for Istio Gateway:"
echo ""
echo "   kubectl create namespace istio-ingress"
echo "   kubectl create secret tls istio-gateway-tls \\"
echo "     --cert=${CERTS_DIR}/server.crt \\"
echo "     --key=${CERTS_DIR}/server.key \\"
echo "     -n istio-ingress"
echo ""
echo "2. The HTTPS listener on the Gateway will use this secret."
echo "   Kong Cloud Gateway can connect on port 80 (HTTP) or 443 (HTTPS)."
echo ""
