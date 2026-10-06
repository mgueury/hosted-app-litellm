# -- Variables ---------------------------------------------
# Values can be overwritten by "export TF_VAR_xxx=xxx" in $HOME/.oci_starter_profile

# Prefix to all resources created by terraform
prefix="halitelm"

# An list of IP Ranges that can access port like 80/443 on the internet. Typically:
#   - All internet - ["0.0.0.0/0"]
#   - or ["123.45.67.89/32"]. Using your Laptop IP. To get your Laptop IP, use by example https://whatismyipaddress.com
public_ip_filters="__TO_FILL__"

# Compartment
compartment_ocid="__TO_FILL__"

