FROM python:3.12-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl build-essential cmake \
    && rm -rf /var/lib/apt/lists/*

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen

RUN curl -L -o /app/model.gguf \
    "https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf"

COPY app/ app/
COPY start.sh .
RUN chmod +x start.sh

ENV PATH="/app/.venv/bin:$PATH"

EXPOSE 8000
CMD ["/app/start.sh"]
