"""Keep LiteLLM's CLI initialization and serve the OCI probe adapter."""

import os
from pathlib import Path

import uvicorn

for name in (
    "HOME", "XDG_CACHE_HOME", "LITELLM_UI_PATH", "LITELLM_ASSETS_PATH",
    "LITELLM_MIGRATION_DIR", "PRISMA_BINARY_CACHE_DIR",
):
    Path(os.environ[name]).mkdir(parents=True, exist_ok=True)

original_run = uvicorn.run


def run_with_oci_probes(*args, **kwargs):
    if kwargs.get("app") != "litellm.proxy.proxy_server:app":
        raise RuntimeError("Unsupported LiteLLM server entrypoint; review the OCI adapter")
    kwargs["app"] = "oci_adapter:app"
    return original_run(*args, **kwargs)


uvicorn.run = run_with_oci_probes

from litellm.proxy.proxy_cli import run_server

if __name__ == "__main__":
    run_server()
