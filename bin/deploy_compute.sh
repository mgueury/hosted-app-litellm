#!/usr/bin/env bash
if [ "$PROJECT_DIR" == "" ]; then
    echo "ERROR: PROJECT_DIR undefined. Please use starter.sh deploy compute"
    exit 1
fi  
cd $PROJECT_DIR
. starter.sh env -silent

echo "COMPUTE_IP=$COMPUTE_IP"

# Create the target/compute directory
# tf_env.sh + tf_vars.sh
cp $TARGET_DIR/tf_*.sh $TARGET_DIR/compute/compute/.
# For app without src/terraform use the tf_env of TERRAFORM_COMMON_DIR
if [ ! -f $TARGET_DIR/tf_env.sh ] && [ $TERRAFORM_COMMON_DIR != "" ]; then
    cp $TERRAFORM_COMMON_DIR/target/tf_env.sh $TARGET_DIR/compute/compute/.
fi    

if -d src/compute; then 
    cp -R src/compute/* $TARGET_DIR/compute/.
fi

scp_via_bastion "target/compute/*" opc@$COMPUTE_IP:/home/opc/.
ssh -o StrictHostKeyChecking=no -oProxyCommand="$BASTION_PROXY_COMMAND" opc@$COMPUTE_IP "set -o pipefail; bash compute/compute_install.sh 2>&1 | tee compute/compute_install.log"
exit_on_error "Deploy Compute - ssh"

