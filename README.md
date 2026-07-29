# RAG on OpenSearch Hybrid Search

Retrieval-Augmented Generation on top of **OpenSearch 3.7** hybrid search (semantic + full-text). Uses a **Pydantic AI** agent with a **llama-cpp-python** inference server (running in-container, no external LLM) to generate answers from retrieved article chunks.

## Architecture

```
                    ┌──────────────────┐
                    │   UI (Nginx)     │  single-page chat app
                    │  :80             │  SSE streaming
                    └────────┬─────────┘
                             │ /api/rag/ → RAG API
                    ┌────────▼──────────────────────────┐
                    │  RAG API (Pydantic AI agent)      │
                    │  FastAPI  :8000                    │
                    │  ┌─────────────────────────────┐  │
                    │  │ llama-cpp-python (bg proc)   │  │
                    │  │ Qwen2.5-1.5B GGUF :8001     │  │
                    │  └─────────────────────────────┘  │
                    └────────┬──────────────────────────┘
                             │ hybrid search
                    ┌────────▼──────────────────────────┐
                    │  OpenSearch 3.7                    │
                    │  hybrid-search  security: off     │
                    │  all-MiniLM-L12 embeddings         │
                    └────────┬──────────────────────────┘
                             │
           ┌─────────────────┼─────────────────────────────┐
           ▼                 ▼                             ▼
    ┌────────────┐   ┌────────────┐               ┌──────────────────┐
    │ template-  │   │  model-    │               │    seed-job      │
    │ job        │   │  job       │               │  30 articles     │
    │ index      │   │  ML model  │               │                  │
    │ template   │   │  pipelines │               │                  │
    └────────────┘   └────────────┘               └──────────────────┘
```

Four init Jobs run in sequence:

| Job | What it does |
|-----|-------------|
| `template-job` | Applies the `article` index template (basic text mapping) |
| `model-job` | Registers + deploys `all-MiniLM-L12-v2`, updates template to `semantic` field, creates chunking ingest pipeline, creates hybrid search pipeline |
| `seed-job` | Indexes 30 sample articles via `_bulk` with the chunking pipeline |
| `rag-api` | FastAPI service with Pydantic AI agent (Deployment, not a Job) |

## Search Modes

| Mode | Query | Backend |
|------|-------|---------|
| **Full Text** | `multi_match` on `title` + `body` | OpenSearch |
| **Semantic** | `neural` on `body` (semantic field) | OpenSearch |
| **Hybrid** | `hybrid` query (neural + multi_match) | OpenSearch + z-score pipeline |
| **RAG** | Hybrid search + LLM generation | OpenSearch + Pydantic AI + llama-cpp-python |

### RAG Flow

1. User enters a question in the chat UI
2. Frontend sends `POST /api/rag/chat/stream { message }` (SSE)
3. API runs hybrid search on OpenSearch (`neural` + `multi_match`)
4. Top-5 article chunks are injected into the prompt as context
5. Prompt is sent to the in-container **llama-cpp-python** server (Qwen2.5-1.5B GGUF)
6. Model generates an answer token-by-token, streamed back as SSE `delta` events
7. Frontend renders text incrementally, appends source cards on completion

### Hybrid Scoring

OpenSearch's `hybrid` query runs both sub-queries independently, then the **`hybrid-search-pipeline`** search pipeline applies:

- **Normalization:** `z_score` (standardizes each result set to mean 0, stddev 1)
- **Combination:** `arithmetic_mean` with weights `[0.59, 0.41]`
- Result: a single, deduplicated set of hits with combined scores

## Project Structure

```
├── api/                        # Python RAG API service
│   ├── Dockerfile
│   ├── requirements.txt
│   └── app/
│       ├── __init__.py
│       ├── main.py             # FastAPI + Pydantic AI agent
│       ├── models.py           # QueryRequest, RAGResponse, Source
│       ├── search.py           # OpenSearch hybrid search client
│       └── settings.py         # Environment variables
├── skaffold.yaml               # Build & deploy config
├── justfile                    # Task runner shortcuts
├── charts/
│   ├── hybrid-search/          # Parent Helm chart (OpenSearch + Dashboards)
│   ├── ui/                     # Nginx serving the search UI
│   ├── rag-api/                # RAG API Deployment + Service (NEW)
│   ├── template-job/           # Index template job
│   ├── model-job/              # ML model registration + pipelines
│   └── seed-job/               # Seed data job
├── frontend/
│   ├── Dockerfile
│   ├── nginx.conf              # Proxies /api/os/ → OS, /api/rag/ → rag-api
│   └── index.html              # Single-page search app (4 modes)
├── template-job/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   └── mappings.json
├── model-job/
│   ├── Dockerfile
│   └── entrypoint.sh
└── seed-job/
    ├── Dockerfile
    ├── entrypoint.sh
    └── seed.json               # 30 sample articles
```

## Prerequisites

- Kubernetes cluster (e.g., Colima, kind, minikube)
- [Skaffold](https://skaffold.dev)
- [Helm](https://helm.sh)
- [just](https://github.com/casey/just) (optional)
- No external LLM required — the GGUF model (~1 GB) is downloaded at Docker build time

### Helm Dependencies

```sh
just rebuild
```

Downloads the `opensearch` and `opensearch-dashboards` chart dependencies.

### Configure Model

The GGUF model is baked into the Docker image. To switch models, update `api/Dockerfile` with a new download URL and update `LLM_MODEL` in `charts/rag-api/values.yaml`:

```yaml
env:
  LLM_URL: http://127.0.0.1:8001/v1
  LLM_MODEL: qwen2.5-1.5b-instruct
```

## Deploy

```sh
skaffold run
```

This builds all 5 Docker images, deploys 6 Helm releases, and runs the 3 init Jobs in sequence.

### First Deploy (slow)

Expect **2–5 minutes** for `model-job` — it downloads `all-MiniLM-L12-v2` (~90 MB) on first run. Subsequent redeploys are fast.

### Verify

```sh
just ps              # all pods should be Running or Completed
just model-logs      # check model deployment
just seed-logs       # check data seeding
just rag-logs        # check RAG API startup
```

## Use

### Port-Forward

```sh
just port-forward-ui     # → http://localhost:8080  (search UI)
just port-forward-rag    # → http://localhost:8000  (RAG API direct)
just port-forward        # → OpenSearch API at :9200
```

### Search

Open http://localhost:8080, select **RAG** mode, and ask a question like:
- "What is quantum computing?"
- "How do neural networks work?"
- "What are the health benefits of the Mediterranean diet?"

### Direct API

```sh
# Stream (SSE)
curl -s http://localhost:8000/api/rag/chat/stream \
  -H 'Content-Type: application/json' \
  -d '{"message": "What is quantum computing?"}'

# Non-streaming
curl -s http://localhost:8000/api/rag/chat \
  -H 'Content-Type: application/json' \
  -d '{"message": "What is quantum computing?"}' | jq .
```

## Key OpenSearch Features Used

- [`semantic` field type](https://opensearch.org/docs/latest/field-types/semantic/) — OpenSearch 2.19+
- [`neural` query](https://opensearch.org/docs/latest/query-dsl/specialized/neural/) — semantic search
- [`hybrid` query](https://opensearch.org/docs/latest/query-dsl/compound/hybrid/) — neural + full-text
- [Search pipelines](https://opensearch.org/docs/latest/search-plugins/search-pipelines/) — `z_score` + `arithmetic_mean`
- [Text chunking](https://opensearch.org/docs/latest/ingest-pipelines/processors/text-chunking/) — 100-token passages, 15% overlap

## License

MIT
