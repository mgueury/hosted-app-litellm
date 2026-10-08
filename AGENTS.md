# Developer and coding agent guide

## Project architecture

This OCI Starter project deploys a LiteLLM proxy and admin UI in one container on OCI Generative AI Hosted Applications. The current application does not run on Compute, Nginx, or Kubernetes, and there is no separate REST application or database source tree. User installation, login, updates, and deletion instructions belong in [README.md](README.md).

```text
starter.sh -> OCI Starter scripts -> Terraform infrastructure
                         |
                         +-> UI image build -> OCIR -> Hosted Deployment (OCI CLI)

API client / browser -> API Gateway -> Hosted Application
                                          |
                                          +-> OCI adapter -> LiteLLM proxy + UI
                                          +-> PostgreSQL (DATABASE_URL)
                                          +-> Model provider APIs through app subnet / NAT
```

Terraform creates the network (or uses supplied network IDs), API Gateway, OCIR repositories, Hosted Application, IAM policy, and OCI logging resources. The Hosted Application uses a public endpoint, `NO_AUTH_CONFIG`, a custom outbound app subnet, and one replica. LiteLLM handles application authentication. PostgreSQL provisioning is invoked by Terraform through a CLI helper; Hosted Deployment image synchronization is also performed by the CLI, outside Terraform resource management.

## Repository map

| Location | Responsibility |
| --- | --- |
| `starter.sh`, `bin/oci_starter.sh` | Workflow entry point and command dispatch |
| `bin/auto_env.sh`, `terraform.tfvars` | Environment loading and deployment configuration |
| `src/terraform/` | Infrastructure and build/deletion dependency graph |
| `src/app/ui/` | LiteLLM container, configuration, launch wrapper, OCI adapter |
| `bin/hosted_app_storage_cli.sh` | PostgreSQL creation, readiness checks, and deletion |
| `bin/hosted_app_cli.sh` | Runtime environment and Hosted Deployment synchronization |
| `src/done.sh` | Public deployment links written to `target/done.txt` |
| `tests/` | Mocked storage lifecycle tests |
| `target/` | Generated state, logs, URLs, OCIDs, and secrets; ignored by Git |
| `user_guide/` | General OCI Starter documentation |

## Build and deployment flow

1. `starter.sh build` loads configuration and acquires a build lock. Environment loading reads generated `target/tf_env.sh`, project `terraform.tfvars`, then `$HOME/.oci_starter_profile`; later settings override earlier ones.
2. Terraform provisions infrastructure. `null_resource.litellm_postgres` invokes the storage helper; `data.local_file.litellm_postgres_ocid` reads the recorded OCID for the Hosted Application's `storage_configs` attachment.
3. OCI supplies that attachment's connection string to the container as `DATABASE_URL`. The project's generated Terraform environment provides gateway and registry settings to the build scripts.
4. `src/app/ui/build.sh` selects or generates the master key, sets the public origin and path prefix, and builds the image. `Dockerfile` pins the upstream LiteLLM image by digest and adds the OCI integration files.
5. The OCI Starter image workflow pushes the image to OCIR. `bin/hosted_app_cli.sh` finds the matching Hosted Application, merges the variables listed in `app.env` into its runtime environment, and preserves unrelated variables.
6. That helper creates the Hosted Deployment if absent. For an existing deployment, it adds the new immutable image artifact, then updates the active artifact. It waits for OCI work requests to succeed.
7. The after-build workflow calls `src/done.sh` to write public links. `starter.sh build app` performs the application rebuild/deployment workflow without a full infrastructure build.

## Runtime routing and authentication

API Gateway exposes `/<prefix>/*` and forwards requests to the Hosted Application's invoke URL. It renames `Authorization` to `x-litellm-api-key`, because the OCI invocation layer consumes `Authorization` before LiteLLM receives it.

`launch.py` creates writable runtime directories under `/tmp`, retains LiteLLM CLI initialization, and substitutes `oci_adapter:app` for the Uvicorn app entry point. Review this integration when updating the pinned LiteLLM image: it explicitly rejects an unexpected server entry point.

`oci_adapter.py` wraps LiteLLM's ASGI app. It maintains the `SERVER_ROOT_PATH` prefix, rewrites the public host and scheme using `PROXY_BASE_URL` so redirects remain on the gateway URL, and normalizes custom API key headers to a Bearer value. OCI probes `/health` and `/ready` map to LiteLLM's `/health/liveliness` and `/health/readiness`; the adapter preserves their status while removing response bodies.

At startup, the adapter injects `oci-client.js` into LiteLLM UI HTML. The browser shim moves Bearer authorization into the custom header only for requests to the same origin and project path. Preserve these origin/path boundaries when changing browser authentication.

`config.yaml` starts with an empty model list, enables database-backed model configuration, and reads the master key from `LITELLM_MASTER_KEY`. Runtime variables declared in `app.env` are `LITELLM_MASTER_KEY`, `SERVER_ROOT_PATH`, and `PROXY_BASE_URL`; OCI injects `DATABASE_URL` via the storage attachment.

The key selection order in `build.sh` is an exported master key, the saved `target/litellm_master_key`, then `sk-` plus 32 random bytes encoded as hex. The saved key has mode `600` and is reused across builds. It is also the default admin UI password (username `admin`). Never include actual keys, connection strings, or state contents in documentation or tests.

## PostgreSQL CLI lifecycle

The native `oci_generative_ai_hosted_application_storage` resource was replaced because of its creation bug. `null_resource.litellm_postgres` has stable triggers for paths, region, profile, compartment, display name, and tags; it must not use a timestamp trigger. Changes to these triggers schedule replacement, including deletion of the database.

The creation provisioner passes settings through environment variables to avoid shell interpolation of names and tags. The helper calls `hosted-application-storage create` with `POSTGRESQL` and `--wait-for-state SUCCEEDED` (1,200-second timeout). The CLI returns a work request when waiting: extract the single `CREATED` resource identifier from `data.resources`, rather than `data.id` (the work-request OCID). Only after successful creation, atomically save the storage OCID to `target/hosted_application_storage.ocid`, then verify it through `get` and wait for `ACTIVE` if needed (1,200-second timeout). On retry it verifies and reuses the recorded resource rather than creating a duplicate. Readiness failures retain the OCID file. If the create waiter fails before the OCID is saved, inspect OCI for a resource that may still be provisioning before retrying; that case cannot reuse the local file.

The destruction provisioner references only `self.triggers` and deletes the recorded OCID with `--force --wait-for-state SUCCEEDED`. Successful deletion removes the file; errors retain it. A missing or invalid OCID fails explicitly. Keep the file alongside Terraform state and retain the dependency through the local-file data source so the Hosted Application is destroyed before its storage. Destroy provisioners do not run for tainted resources, so interrupted or failed creation can require explicit CLI cleanup using the retained OCID.

This replacement assumes a fresh deployment; it does not migrate an existing native storage resource in Terraform state. Do not apply that resource transition to an existing database without designing a state migration first.

`starter.sh destroy` invokes the Terraform teardown and archives `target/` once state is empty. Hosted Deployment synchronization is outside Terraform: inspect OCI for remaining deployments or images if teardown fails.

## Development and verification

- Put container and LiteLLM runtime changes under `src/app/ui/`, infrastructure changes under `src/terraform/`, and workflow changes in the relevant `bin/` helper.
- Keep README instructions aligned with actual commands, generated URLs, and secret file locations.
- Preserve unrelated local changes and generated files; never commit `target/`, OCI credentials, or actual master keys.
- Check the storage helper with `bash -n bin/hosted_app_storage_cli.sh` and run `python3 -m unittest discover -s tests -v`. The tests mock OCI calls and cover creation arguments, retries, resource verification, deletion, and OCID retention after failures.
- Run `terraform fmt -check src/terraform/hosted_app.tf` and `terraform -chdir=src/terraform validate` after initialization. Use `./starter.sh terraform plan` to review infrastructure changes; do not run apply or destroy merely to validate code.
- For adapter changes or LiteLLM image upgrades, verify probes, `/ui/` navigation and redirects under the prefix, admin login, and API requests with a virtual key. Confirm persisted model configuration after a redeployment.
