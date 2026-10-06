
#!/usr/bin/env bash
# build.sh
#
# Compute:
# - build the code 
# - create a $TARGET_DIR/compute/app/$APP_NAME directory with the files
# - and a start.sh to start the program
# Docker:
# - build the image
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
cd $SCRIPT_DIR
# Set the settings. For src/app/xxx or src/app/zzz/xxx or BUILD_HOST=bastion 
if [ -f "$SCRIPT_DIR/../../../starter.sh" ]; then
    . "$SCRIPT_DIR/../../../starter.sh" env -no-auto -silent
    . "$BIN_DIR/build_common.sh"
elif [ -f $HOME/compute/shared_compute.sh ]; then
    . $HOME/compute/shared_compute.sh
else
    echo "ERROR: Could not find project starter.sh or $HOME/compute/shared_compute.sh"
    exit 1
fi

if [ "$TF_VAR_deploy_type" = "hosted_app" ]; then
    KEY_FILE="$TARGET_DIR/litellm_master_key"
    if [ -n "${LITELLM_MASTER_KEY:-}" ]; then
        (umask 077; printf '%s\n' "$LITELLM_MASTER_KEY" > "$KEY_FILE")
    elif [ -s "$KEY_FILE" ]; then
        LITELLM_MASTER_KEY=$(cat "$KEY_FILE")
    else
        LITELLM_MASTER_KEY="sk-$(openssl rand -hex 32)" || exit 1
        (umask 077; printf '%s\n' "$LITELLM_MASTER_KEY" > "$KEY_FILE")
    fi
    chmod 600 "$KEY_FILE"
    export LITELLM_MASTER_KEY
    export SERVER_ROOT_PATH="${SERVER_ROOT_PATH:-/$TF_VAR_prefix}"
    export PROXY_BASE_URL="${PROXY_BASE_URL:-https://$APIGW_HOSTNAME}"
fi

if is_deploy_compute; then
    build_rsync .
else
    docker_build $APP_NAME
fi
