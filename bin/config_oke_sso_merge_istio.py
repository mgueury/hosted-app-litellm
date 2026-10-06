#!/usr/bin/env python3
"""Add the oauth2-proxy extension provider to an Istio ConfigMap patch.

This script intentionally depends only on Python's standard library. It preserves
the existing mesh YAML verbatim and is idempotent: a later run leaves an existing
oauth2-proxy provider untouched. If another process has already added a different
extensionProviders section, the script stops rather than risk rewriting it.
"""

import json
import re
import sys
from pathlib import Path


PROVIDER_NAME = "oauth2-proxy"
PROVIDER_BLOCK = """extensionProviders:
- name: oauth2-proxy
  envoyExtAuthzHttp:
    service: oauth2-proxy.gateway.svc.cluster.local
    port: \"4180\"
    includeRequestHeadersInCheck:
    - authorization
    - cookie
    - x-forwarded-for
    - x-forwarded-host
    - x-forwarded-method
    - x-forwarded-proto
    - x-forwarded-uri
    headersToUpstreamOnAllow:
    - path
    - authorization
    - x-auth-request-user
    - x-auth-request-email
    - x-auth-request-access-token
    headersToDownstreamOnAllow:
    - set-cookie
    headersToDownstreamOnDeny:
    - content-type
    - location
    - set-cookie
"""


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(
            "usage: config_oke_sso_merge_istio.py INPUT_CONFIGMAP_JSON OUTPUT_PATCH_JSON"
        )

    input_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2])
    config_map = json.loads(input_path.read_text())

    try:
        mesh = config_map["data"]["mesh"]
    except KeyError as error:
        raise SystemExit(f"Istio ConfigMap does not contain data.mesh: {error}") from error

    has_providers = re.search(r"^extensionProviders:\s*$", mesh, re.MULTILINE)
    has_oauth2_proxy = re.search(
        rf"^\s*-\s+name:\s*{re.escape(PROVIDER_NAME)}\s*$", mesh, re.MULTILINE
    )

    if has_oauth2_proxy:
        # Reconcile this known provider while preserving all other mesh settings.
        # `path` is required so the original request is forwarded to its app
        # backend after oauth2-proxy authorizes it.
        provider_match = re.search(
            r"(?ms)^- name: oauth2-proxy\n.*?(?=^- name:|\Z)", mesh
        )
        assert provider_match is not None
        provider = provider_match.group(0)
        if re.search(r"(?m)^\s*- path\s*$", provider):
            updated_mesh = mesh
        else:
            def add_path(match: re.Match[str]) -> str:
                return f"{match.group(0)}{match.group(1)}- path\n"

            updated_provider = re.sub(
                r"(?m)^(\s*)headersToUpstreamOnAllow:\s*\n",
                add_path,
                provider,
                count=1,
            )
            if updated_provider == provider:
                raise SystemExit(
                    "The oauth2-proxy extension provider is missing "
                    "headersToUpstreamOnAllow; refusing to rewrite it."
                )
            updated_mesh = (
                mesh[:provider_match.start()]
                + updated_provider
                + mesh[provider_match.end():]
            )
    elif has_providers:
        raise SystemExit(
            "Istio mesh already has extensionProviders but no oauth2-proxy entry; "
            "refusing to rewrite that section automatically."
        )
    else:
        updated_mesh = mesh.rstrip() + "\n" + PROVIDER_BLOCK

    patch = {"data": {"mesh": updated_mesh}}
    output_path.write_text(json.dumps(patch))


if __name__ == "__main__":
    main()
