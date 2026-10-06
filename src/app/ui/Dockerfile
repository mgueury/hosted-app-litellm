FROM ghcr.io/berriai/litellm@sha256:f63fb81b831b170ec16851e23c36ac5bf52ef106b271406429524a2ed730bbfd

ENV PYTHONPATH=/opt/oci-litellm \
    PYTHONDONTWRITEBYTECODE=1 \
    HOME=/tmp/home \
    XDG_CACHE_HOME=/tmp/cache \
    LITELLM_MODE=PRODUCTION \
    LITELLM_UI_PATH=/tmp/litellm/ui \
    LITELLM_ASSETS_PATH=/tmp/litellm/assets \
    LITELLM_MIGRATION_DIR=/tmp/litellm/migrations \
    PRISMA_BINARY_CACHE_DIR=/tmp/prisma

COPY launch.py oci_adapter.py oci-client.js config.yaml /opt/oci-litellm/
RUN chmod -R a+rX /opt/oci-litellm

EXPOSE 8080
ENTRYPOINT ["python", "/opt/oci-litellm/launch.py"]
CMD ["--host", "0.0.0.0", "--port", "8080", "--config", "/opt/oci-litellm/config.yaml", "--num_workers", "1"]
