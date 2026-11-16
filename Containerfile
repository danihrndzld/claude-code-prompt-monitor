# Receptor del hook UserPromptSubmit. Build: podman build -t prompt-guard:0.1 -f Containerfile .
FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim
WORKDIR /app
COPY hook_receiver.py .
# OpenShift arranca el contenedor con un UID aleatorio del grupo root: la caché de uv va a /tmp.
ENV UV_CACHE_DIR=/tmp/uv-cache UV_NO_PROGRESS=1
USER 1001
EXPOSE 8080
CMD ["uv", "run", "--no-project", "hook_receiver.py", "8080"]
