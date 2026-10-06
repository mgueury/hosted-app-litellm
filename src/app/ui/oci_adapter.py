"""Adapt OCI probes and stripped invocation paths for LiteLLM."""

import os
from html import escape
from pathlib import Path
from urllib.parse import urlsplit

from litellm.proxy.proxy_server import app as litellm_app


class OCIProbeAdapter:
    def __init__(self, delegate):
        self.delegate = delegate
        self.root_path = os.getenv("SERVER_ROOT_PATH", "").rstrip("/")
        self.public_origin = self._configured_public_origin()

    @staticmethod
    def _configured_public_origin():
        base_url = os.getenv("PROXY_BASE_URL", "").strip()
        if not base_url:
            return None
        try:
            parsed = urlsplit(base_url)
            hostname = parsed.hostname
            if (
                parsed.scheme not in ("http", "https")
                or not hostname
                or parsed.username is not None
                or parsed.password is not None
                or parsed.query
                or parsed.fragment
                or any(char.isspace() for char in parsed.netloc)
            ):
                raise ValueError
            port = parsed.port
            host = hostname.encode("idna").decode("ascii")
            authority = "[" + host + "]" if ":" in host else host
            if port is not None:
                authority += ":" + str(port)
            server = (hostname, port if port is not None else
                      443 if parsed.scheme == "https" else 80)
            return parsed.scheme, authority.encode("ascii"), server
        except (ValueError, UnicodeError):
            raise ValueError(
                "PROXY_BASE_URL must be an absolute HTTP(S) URL without "
                "credentials, a query, or a fragment"
            ) from None

    def prepare_browser_headers(self):
        if not self.root_path:
            return
        ui = Path(os.environ["LITELLM_UI_PATH"])
        if not (ui / "index.html").is_file() or not (ui / "_next").is_dir():
            raise RuntimeError("LiteLLM UI assets are missing; cannot install OCI header setup")
        script_name = "oci-client.js"
        (ui / script_name).write_text(
            Path(__file__).with_name(script_name).read_text()
        )
        script = '<script src="' + escape(
            self.root_path + "/ui/" + script_name, quote=True
        ) + '"></script>'
        for page in ui.rglob("*.html"):
            content = page.read_text()
            if script not in content:
                if "<head>" not in content:
                    raise RuntimeError("LiteLLM UI HTML changed; review OCI header setup")
                page.write_text(content.replace("<head>", "<head>" + script, 1))

    async def __call__(self, scope, receive, send):
        if scope["type"] == "lifespan":
            async def startup_send(message):
                if message["type"] == "lifespan.startup.complete":
                    self.prepare_browser_headers()
                await send(message)

            return await self.delegate(scope, receive, startup_send)
        if scope["type"] != "http":
            return await self.delegate(scope, receive, send)

        checks = {"/health": "/health/liveliness", "/ready": "/health/readiness"}
        path = scope.get("path", "")
        has_prefix = self.root_path and (
            path == self.root_path or path.startswith(self.root_path + "/")
        )
        local_path = path[len(self.root_path):] if has_prefix else path
        mapped = dict(scope)
        # LiteLLM's configured custom-header parser requires a Bearer prefix.
        # Its browser clients and external clients may supply a raw key.
        mapped["headers"] = []
        for name, value in scope.get("headers", []):
            if self.public_origin and name.lower() == b"host":
                continue
            if name.lower() == b"x-litellm-api-key" and value:
                value = b"Bearer " + (
                    value[7:] if value.lower().startswith(b"bearer ") else value
                )
            mapped["headers"].append((name, value))

        # OCI forwards its internal service Host. Starlette uses Host/scheme
        # when redirecting directory URLs to a trailing slash, so expose the
        # operator-configured public origin to the inner application. Keep the
        # invocation prefix in path/root_path, rather than adding it here.
        if self.public_origin:
            scheme, host, server = self.public_origin
            mapped["scheme"] = scheme
            mapped["server"] = server
            mapped["headers"].append((b"host", host))

        # OCI strips /actions/invoke before forwarding. Starlette's mounted
        # static-file apps need path and root_path to contain the same prefix.
        if self.root_path and not has_prefix:
            mapped["path"] = self.root_path + path
            mapped["raw_path"] = self.root_path.encode() + scope.get(
                "raw_path", path.encode()
            )

        if local_path not in checks:
            return await self.delegate(mapped, receive, send)

        mapped["path"] = self.root_path + checks[local_path]
        mapped["raw_path"] = mapped["path"].encode()
        mapped["query_string"] = b""

        async def probe_send(message):
            if message["type"] == "http.response.start":
                await send({
                    "type": "http.response.start",
                    "status": message["status"],
                    "headers": [(b"content-type", b"application/json"),
                                (b"content-length", b"0")],
                })
            elif message["type"] == "http.response.body":
                await send({"type": "http.response.body", "body": b"",
                            "more_body": message.get("more_body", False)})

        await self.delegate(mapped, receive, probe_send)


app = OCIProbeAdapter(litellm_app)
