## Project overview

This repository is an OCI Starter project that provisions resources on an Oracle Cloud
Infrastructure using terraform and deploys a small web application to it.

- `src/terraform/` defines the OCI infrastructure, including the network
  integration, bastion access, and Oracle Linux Compute instance.
- `src/app/` contains the several application that will be deployed service. Typically, 
    - `src/app/rest` contains a program with a rest API
- `src/app/ui/` contains the Nginx-based frontend image and its static UI assets.
- `src/app/db` contains the setup of the database
- `starter.sh` is the main workflow entry point; it can provision, build,
  configure, and destroy the stack.
- `terraform.tfvars` supplies environment-specific Terraform values, such as
  the permitted public IP range.

The intended flow is: configure `terraform.tfvars`, run `./starter.sh` (or
`./starter.sh build`), then use the bastion/Compute access commands for
deployment and troubleshooting.

User Guide is available in the user_guide directory.