# LiteLLM on OCI Hosted Applications

Deploy the [LiteLLM](https://docs.litellm.ai/) proxy and admin UI on Oracle Cloud Infrastructure (OCI). Use the UI to configure models and API keys, then call those models through one OpenAI-compatible endpoint.

Developer and coding agent documentation is in [AGENTS.md](AGENTS.md).

## Architecture

```text
Browser / API client
        |
        v
OCI API Gateway: https://<gateway-host>/<prefix>
        |
        v
OCI Hosted Application: LiteLLM proxy + admin UI
        |                          |
        v                          v
Managed PostgreSQL          Model providers
```

## 1. Prepare your build machine

You need:

- An OCI tenancy and compartment with permission to create networking, API Gateway, OCIR repositories, Generative AI Hosted Applications and storage, IAM policies, and logs.
- Access to Hosted Applications in your selected OCI region.
- Bash, Python 3, Terraform, OCI CLI, Docker, `jq`, `rsync`, and OpenSSL. Start Docker before building.
- Configured OCI CLI credentials and an OCI auth token for pushing images to OCIR.

Run all commands below from this repository's root directory. OCI resources and model calls may incur charges.

## 2. Configure OCI

Edit `terraform.tfvars` and replace the `__TO_FILL__` values:

```hcl
prefix = "halitelm"
compartment_ocid = "ocid1.compartment.oc1..."
public_ip_filters = ["203.0.113.42/32"]
```

Use your own compartment OCID and actual public IP CIDR; the values above are examples. The CIDR list configures the generated network rules.

Additional OCI settings can be supplied in `$HOME/.oci_starter_profile`, for example:

```bash
export TF_VAR_compartment_ocid="ocid1.compartment.oc1..."
```

This profile is loaded after `terraform.tfvars` and overrides matching values. For more info see the [OCI Starter user guide](user_guide/index.html).

## 3. Install and deploy

Review the infrastructure plan, then build:

```bash
./starter.sh terraform plan
./starter.sh build
```

The build provisions infrastructure and PostgreSQL, builds and pushes the LiteLLM container, and deploys it to the Hosted Application. Wait for the build to finish successfully before logging in.

To watch progress from another terminal:

```bash
tail -f target/build.log
```

## 4. Find the LiteLLM link

After a successful build, show the deployment links:

```bash
cat target/done.txt
```

The `User Interface` entry gives the public base URL, normally:

```text
https://<gateway-host>/<prefix>/
```

**For the LiteLLM admin UI, append `ui/` to that URL:**

```text
https://<gateway-host>/<prefix>/ui/
```

For example, with the default prefix, the admin UI is at `https://<gateway-host>/halitelm/ui/`. Use the gateway hostname printed for your own deployment.

## 5. Find the password and log in

The default login credentials are:

| Field | Value |
| --- | --- |
| Username | `admin` |
| Password | The contents of `target/litellm_master_key` |

Display the password locally:

```bash
cat target/litellm_master_key
```

Copy the key into the password field on the LiteLLM login page. The page's `MASTER_KEY` refers to this project's `LITELLM_MASTER_KEY`. These are LiteLLM credentials, separate from your OCI console account. The default `admin` / master key login is described in the [LiteLLM quickstart](https://docs.litellm.ai/docs/proxy/docker_quick_start).

The build uses an exported `LITELLM_MASTER_KEY` if supplied; otherwise it reuses the saved key or generates one on the first application build. Keep the saved key across rebuilds. It grants admin access: do not commit it or paste it into shared logs.

If the file does not exist yet, check whether the build has reached the application build step and completed successfully.

## 6. Add a model and use the API

In the admin UI, open **Models + Endpoints**, add a model with its provider credentials, and test the connection. The initial deployment has no models configured. Create a virtual API key in the UI for your client.

The API base URL is `https://<gateway-host>/<prefix>`; do not include `/ui`. For example, to list available models:

```bash
export LITELLM_BASE_URL="https://<gateway-host>/halitelm"
read -r -s -p "LiteLLM API key: " LITELLM_API_KEY; echo
curl "$LITELLM_BASE_URL/v1/models" \
  -H "Authorization: Bearer $LITELLM_API_KEY"
unset LITELLM_API_KEY
```

Chat requests go to `$LITELLM_BASE_URL/v1/chat/completions`. For an OpenAI-compatible SDK that expects the versioned base URL, use `https://<gateway-host>/<prefix>/v1`.

## Update and troubleshoot

| Task | Command or location |
| --- | --- |
| Rebuild and redeploy the application | `./starter.sh build app` |
| Apply infrastructure changes and rebuild | `./starter.sh build` |
| Preview infrastructure changes | `./starter.sh terraform plan` |
| Find deployment links | `cat target/done.txt` |
| Follow the build | `tail -f target/build.log` |
| Find previous build logs | `target/logs/` |
| Read application service logs | OCI Logging, in the project's log group |
| Show available commands | `./starter.sh help` |
| Remove a stale lock after the build has stopped | `./starter.sh unlock` |

If login fails, check the `/ui/` URL and the saved key. If a model request fails, verify that the model is configured and that the client's API key has access to it. The generic OCI Starter help also lists commands for other deployment types; this project runs as a Hosted Application.

## Delete the deployment

1. Keep the original checkout and `target/` directory. Deletion needs both `target/terraform.tfstate` and `target/hosted_application_storage.ocid`.
2. Run:

   ```bash
   ./starter.sh destroy
   ```

3. Answer `yes` to the confirmation. This removes the deployed infrastructure and deletes the PostgreSQL database and its data. PostgreSQL deletion runs through the OCI CLI provisioner.
4. Check the destroy output and OCI console for remaining Hosted Deployments, registry images, or other project resources if cleanup reports errors.

After successful cleanup, OCI Starter renames `target/` to `target.<timestamp>/`. Keep the archived state and logs until cleanup is verified. Do not remove the OCID file before deletion: the storage helper requires it and retains it when deletion fails.
