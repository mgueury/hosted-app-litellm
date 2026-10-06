#!/usr/bin/env bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
. $SCRIPT_DIR/../starter.sh env -no-auto -silent
. $BIN_DIR/build_common.sh
cd $SCRIPT_DIR/..
title "Config OKE"

export TARGET_OKE=$TARGET_DIR/oke
mkdir -p $TARGET_OKE

# One time configuration
if [ ! -f $KUBECONFIG ]; then
    create_kubeconfig
    
    # Check if Gateway Controller is installed
    if ! kubectl get gateway oke-gateway -n gateway >/dev/null 2>&1; then    
        # Deploy Latest istio-gateway
        kubectl create clusterrolebinding starter_clst_adm --clusterrole=cluster-admin --user=$TF_VAR_current_user_ocid
        echo "OKE Deploy: Role Binding created"  

        # See: https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengworkingwithistioaddonforgatewayapi.htm

        # Install Gateway API CRDs
        kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
        kubectl get crd gateways.gateway.networking.k8s.io
        # Deploy the Istio cluster add-on
        oci ce cluster install-addon --addon-name Istio --cluster-id $OKE_OCID --from-json file://src/oke/istio_addon.json
        oci ce cluster list-addons --cluster-id $OKE_OCID
        # Wait istiod
        echo "Waiting for istiod pod to be Running..."

        ELAPSED=0
        while true; do
            STATUS=$(kubectl get pods -n istio-system -l app=istiod -o jsonpath='{.items[0].status.phase}' 2>/dev/null)

            if [ "$STATUS" = "Running" ]; then
                echo "Istiod is Running ($ELAPSED secs)"
                break
            fi
            ELAPSED=$((ELAPSED + 5 ))
            if [ $ELAPSED -gt 300 ]; then
                exit_error "Istiod not started after 300 secs"
            fi
            echo "Waiting 5 secs..."
            sleep 5
        done

        # Create a Gateway
        kubectl apply -f src/oke/gateway.yaml
        # Wait 
        echo "Waiting for Gateway to be ready..."
        kubectl wait --for=condition=Programmed gateway/oke-gateway -n gateway --timeout=120s
        exit_on_error "Gateway Programmed State"

        # Get the IP
        oke_get_gateway_ip
        echo "Gateway ready: $TF_VAR_gateway_ip"
    else
        echo "OKE Deploy: Skipping creation of Gateway" 
    fi  

    if [ "${TF_VAR_tls}" == "new_http_01" ]; then
        # The OKE CertManager add-on installs cert-manager with Gateway API support
        # disabled. Enable it so HTTP-01 challenges can use the Istio Gateway above.
        if ! kubectl get deployment cert-manager -n cert-manager -o jsonpath='{.spec.template.spec.containers[0].args[*]}' | grep -q -- '--enable-gateway-api'; then
            kubectl patch deployment cert-manager -n cert-manager --type=json \
                -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--enable-gateway-api=true"}]'
            exit_on_error "Enable cert-manager Gateway API"
            kubectl rollout status deployment/cert-manager -n cert-manager --timeout=180s
            exit_on_error "Restart cert-manager with Gateway API enabled"
        fi
        cp src/oke/tls/gateway-tls.yaml ${TARGET_OKE}/gateway-tls.yaml
        file_replace_variables${TARGET_OKE}/gateway-tls.yaml
        kubectl apply -f ${TARGET_OKE}/gateway-tls.yaml
        exit_on_error "Apply OKE TLS resources"

        if [ "${TF_VAR_security:-false}" = "openid" ]; then
            $BIN_DIR/config_oke_sso.sh
            exit_on_error "Configure OCI SSO for OKE Gateway"
        fi
    fi
fi

if ! grep -q "TF_VAR_gateway_ip" $TARGET_DIR/tf_env.sh; then
    oke_get_gateway_ip
    echo "export TF_VAR_gateway_ip=$TF_VAR_gateway_ip" >> $TARGET_DIR/tf_env.sh
fi

# Create secrets
k8s_create_db_secret

# Create ocirsecret with DOCKER_TOKEN 
k8s_create_ocirsecret

# TF_ENV
export_to_configmap tf_env.sh