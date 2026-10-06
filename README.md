# LiteLLM on OCI Hosted Applications

This project deploys a [LiteLLM](https://docs.litellm.ai/) proxy and its web UI on Oracle Cloud Infrastructure (OCI). It gives clients one OpenAI-compatible API endpoint and provides a UI for managing LiteLLM models and keys. The application is packaged as a container and runs as an OCI Generative AI Hosted Application; there is no Compute VM, Kubernetes cluster, separate REST service, or application database source tree in this repository.

The project was generated from OCI Starter. `starter.sh` wraps the Terraform, image build, registry push, and Hosted Deployment workflow.

## Architecture

```text
Browser / OpenAI-compatible client
              |
              v
Public OCI API Gateway  /<prefix>/*
              |  forwards requests and maps Authorization to x-litellm-api-key
              v
OCI Generative AI Hosted Application (one replica)
              |
              +-- LiteLLM proxy + UI container (port 8080)
              |      +-- OCI adapter for health probes, URL prefix, and headers
              |      +-- LiteLLM model routing and key management
              |
              +-- OCI-managed PostgreSQL storage (DATABASE_URL)
              +-- outbound access through the application subnet
```

Terraform in `src/terraform/` creates the VCN and subnets (unless existing network IDs are supplied), API Gateway, OCIR repositories, Hosted Application, PostgreSQL storage, IAM policy, and logging resources. The app subnet uses a private route through a NAT gateway. `public_ip_filters` controls permitted public CIDR ranges in the generated network rules. The Hosted Application itself is configured with a public endpoint and `NO_AUTH_CONFIG`; LiteLLM's master key is the application credential. Review the effective OCI network and access settings before exposing it.

The container is built from a pinned LiteLLM image in `src/app/ui/Dockerfile`. `config.yaml` starts with an empty `model_list`, stores model settings in the database, and reads the master key from `LITELLM_MASTER_KEY`. `launch.py`, `oci_adapter.py`, and `oci-client.js` adapt LiteLLM to OCI's probes, gateway path, and authentication header. During a build, the scripts push a versioned image to OCIR and use the OCI CLI to create or update the Hosted Deployment. That deployment step is outside Terraform.

## Prerequisites

- An OCI tenancy and compartment with permissions to create the resources above, plus access to OCI Generative AI Hosted Applications in the chosen region.
- OCI CLI credentials configured locally (the Terraform OCI provider uses the `DEFAULT` profile unless `config_file_profile` is set).
- Bash, Python 3, Terraform, OCI CLI, Docker, `jq`, `rsync`, and OpenSSL available on the build machine. Docker must be running.
- A public IP CIDR range from which you will access the deployment.

The OCI resources and Hosted Application may incur charges. Keep OCI credentials and LiteLLM keys out of source control.

## Install and deploy

1. In `terraform.tfvars`, replace both `__TO_FILL__` values with your OCI compartment OCID and an allowed CIDR list. For example:

   ```hcl
   prefix = "halitelm"
   compartment_ocid = "ocid1.compartment.oc1..."
   public_ip_filters = ["203.0.113.42/32"]
   ```

   Use your **actual** public IP address; the example address is only a placeholder. Other OCI values can be supplied through `TF_VAR_*` exports in `$HOME/.oci_starter_profile`. That profile is loaded after `terraform.tfvars` and overrides matching values.

2. From the repository root, review the plan and build:

   ```bash
   ./starter.sh help
   ./starter.sh terraform plan
   ./starter.sh build
   ```

   `build` applies Terraform, builds and pushes the LiteLLM image, configures the Hosted Application environment, and synchronizes the Hosted Deployment. It writes the public URL to `target/done.txt` and logs to `target/build.log` and `target/logs/`.

3. Open the User Interface URL printed by the build. The API base URL is that same URL, typically `https://<gateway-host>/<prefix>`. Common routes are `/v1/models` and `/v1/chat/completions` under that base URL. Configure at least one model in LiteLLM before expecting model requests to work; `config.yaml` starts with no models.

The build creates a master key in `target/litellm_master_key` if `LITELLM_MASTER_KEY` was not already set. Treat this file as a secret. Preserve the key across rebuilds and avoid printing it in shared logs or tickets. LiteLLM clients use the key as `Authorization: Bearer <key>`; the gateway maps that header to LiteLLM's configured `x-litellm-api-key` header.

## Operate and update

| Task | Command or file |
| --- | --- |
| Show available commands | `./starter.sh help` |
| Open a shell with the project environment | `./starter.sh env` |
| Preview infrastructure changes | `./starter.sh terraform plan` |
| Rebuild and redeploy app changes | `./starter.sh build app` |
| Rebuild infrastructure and app | `./starter.sh build` |
| See deployment URLs | `cat target/done.txt` |
| Read the latest build log | `cat target/build.log` |
| Clear a stale build lock after a stopped build | `./starter.sh unlock` |

Edit LiteLLM container behavior under `src/app/ui/`; edit OCI resources under `src/terraform/`. Run a Terraform plan before applying infrastructure changes. `bin/` contains the generated OCI Starter workflow. The generic help menu also lists Compute, bastion, database, and Kubernetes commands; those targets are not part of this Hosted Application stack.

## Remove the deployment

From the same checkout and Terraform state used for deployment, run:

```bash
./starter.sh destroy
```

The command asks for confirmation and destroys Terraform-managed resources. On successful cleanup, OCI Starter renames `target/` to `target.<timestamp>/`; review the timestamped destroy log under its `logs/` directory and the OCI console afterward. In particular, verify that the Hosted Deployment created by the OCI CLI, OCIR images, and PostgreSQL storage have been removed; these may need separate cleanup if OCI does not remove them with their parent resources. Retain the archived Terraform state until cleanup is complete, since it identifies the managed resources.

## Project layout

| Path | Purpose |
| --- | --- |
| `starter.sh`, `bin/` | OCI Starter entry point and deployment scripts |
| `terraform.tfvars` | Project-specific Terraform values |
| `src/terraform/` | OCI infrastructure definitions |
| `src/app/ui/` | LiteLLM image, configuration, and OCI adapter |
| `target/` | Generated state, logs, deployment URLs, and local secrets (ignored by Git) |
| `user_guide/` | General OCI Starter user guide |

For the broader OCI Starter workflow, see the local [user guide](user_guide/index.html).
