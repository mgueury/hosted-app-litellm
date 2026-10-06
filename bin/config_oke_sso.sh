#!/usr/bin/env bash
# Configure OCI IAM Identity Domains SSO at the shared Istio Gateway.
set -o pipefail

required_variables=(
  TF_VAR_idcs_url
  OCI_SSO_CLIENT_ID_B64
  OCI_SSO_CLIENT_SECRET_B64
  OCI_SSO_COOKIE_SECRET_B64
)

for variable_name in "${required_variables[@]}"; do
  if [ -z "${!variable_name:-}" ]; then
    echo "ERROR: ${variable_name} must be set when TF_VAR_security=openid"
    exit 1
  fi
done

mkdir -p "$TARGET_DIR/oke"
SSO_MANIFEST="$TARGET_DIR/oke/oci-sso.yaml"
cp "$PROJECT_DIR/src/oke/sso/oci-sso.yaml" "$SSO_MANIFEST"
file_replace_variables "$SSO_MANIFEST"

# Preserve the existing mesh configuration while registering the external
# authorization provider used by the AuthorizationPolicy in oci-sso.yaml.
ISTIO_CONFIG="$TARGET_DIR/oke/istio-config.json"
ISTIO_PATCH="$TARGET_DIR/oke/istio-sso-patch.json"
kubectl get configmap istio -n istio-system -o json > "$ISTIO_CONFIG"
python3 "$PROJECT_DIR/bin/config_oke_sso_merge_istio.py" "$ISTIO_CONFIG" "$ISTIO_PATCH"
kubectl patch configmap istio -n istio-system --type merge --patch-file "$ISTIO_PATCH"
exit_on_error "Register oauth2-proxy with Istio"

kubectl apply -f "$SSO_MANIFEST"
exit_on_error "Apply OCI SSO resources"
