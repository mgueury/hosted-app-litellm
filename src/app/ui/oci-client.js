// OCI's invocation gateway reserves Authorization. Keep LiteLLM's browser
// SDK requests on the same custom header used by its dashboard client.
(() => {
  const script = document.currentScript;
  if (!script || window.__ociLiteLLMFetchInstalled) return;
  const scriptUrl = new URL(script.src, window.location.href);
  const suffix = "/ui/oci-client.js";
  if (!scriptUrl.pathname.endsWith(suffix)) return;
  const root = scriptUrl.pathname.slice(0, -suffix.length);
  const originalFetch = window.fetch.bind(window);

  window.fetch = function (input, init) {
    let url;
    try {
      url = new URL(input instanceof Request ? input.url : input, window.location.href);
    } catch {
      return originalFetch(input, init);
    }
    if (url.origin !== window.location.origin ||
        !(url.pathname === root || url.pathname.startsWith(root + "/"))) {
      return originalFetch(input, init);
    }

    const headers = new Headers(init && init.headers !== undefined
      ? init.headers : input instanceof Request ? input.headers : undefined);
    const customKey = headers.get("x-litellm-api-key");
    const authorization = headers.get("authorization");
    const key = customKey !== null ? customKey
      : (/^Bearer\s+/i.test(authorization || "") ? authorization : null);
    if (key === null) return originalFetch(input, init);
    headers.set("x-litellm-api-key", /^Bearer\s+/i.test(key)
      ? "Bearer " + key.replace(/^Bearer\s+/i, "") : key ? "Bearer " + key : "");
    headers.delete("authorization");
    return originalFetch(input, { ...init, headers });
  };
  window.__ociLiteLLMFetchInstalled = true;
})();
