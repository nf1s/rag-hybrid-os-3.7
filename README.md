# RAG on OpenSearch Hybrid Search

Retrieval-Augmented Generation on top of **OpenSearch 3.7** hybrid search (semantic + full-text). Uses a **Pydantic AI** agent with **Ollama** (local LLM) to generate answers from retrieved article chunks.

## Architecture

```
                   ┌──────────────────┐
                   │   UI (Nginx)     │  single-page search app
                   │  :80             │  4 modes: FT / Semantic / Hybrid / **RAG**
                   └────────┬─────────┘
                            │ /api/os/ → OpenSearch    /api/rag/ → RAG API
                   ┌────────▼─────────┐   ┌──────────────▼──────────────┐
                   │  OpenSearch 3.7  │   │  RAG API (Pydantic AI)     │
                   │  hybrid-search   │   │  FastAPI + Ollama          │
                   │  security: off   │   │  :8000                     │
                   └────────┬─────────┘   └──────────────┬──────────────┘
                            │                             │ Ollama (host)
                   ┌────────▼─────────┐           ┌───────▼────────┐
                   │  all-MiniLM-L12  │           │  llama3.2 /    │
                   │  embeddings      │           │  mistral, etc. │
                   └──────────────────┘           └────────────────┘
                                        │
          ┌─────────────────────────────┼─────────────────────────────┐
          ▼                             ▼                             ▼
   ┌────────────┐               ┌────────────┐               ┌──────────────────┐
   │ template-  │               │  model-    │               │    seed-job      │
   │ job        │               │  job       │               │  30 articles     │
   │ index      │               │  ML model  │               │                  │
   │ template   │               │  pipelines │               │                  │
   └────────────┘               └────────────┘               └──────────────────┘
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
| **RAG** | Hybrid search + LLM generation | OpenSearch + Pydantic AI + Ollama |

### RAG Flow

1. User enters a question in search bar (RAG mode)
2. Frontend sends `POST /api/rag/query { question, top_k: 5 }` to the RAG API
3. Pydantic AI agent calls the `opensearch_search` tool → hybrid search on OpenSearch
4. Top-5 article chunks are returned with scores
5. Agent sends chunks + question to Ollama (local LLM) for answer generation
6. Structured response: `{ answer, sources: [{ id, title, excerpt, score }] }`
7. Frontend renders the answer with cited source cards

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
- [Ollama](https://ollama.ai) running on the host with at least one model pulled
  ```sh
  ollama pull gemma4:12b-mlx
  ```

### Helm Dependencies

```sh
just rebuild
```

Downloads the `opensearch` and `opensearch-dashboards` chart dependencies.

### Configure Ollama URL

Set the correct `OLLAMA_URL` in `charts/rag-api/values.yaml` for your platform:

```yaml
env:
  OLLAMA_URL: http://host.docker.internal:11434  # Colima / Docker Desktop (default)
  LLM_MODEL: gemma4:12b-mlx                      # model pulled on your host
```

Check with: `just ollama-url`

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
curl -s http://localhost:8000/api/rag/query \
  -H 'Content-Type: application/json' \
  -d '{"question": "What is quantum computing?", "top_k": 3}' | jq .
```

## Key OpenSearch Features Used

- [`semantic` field type](https://opensearch.org/docs/latest/field-types/semantic/) — OpenSearch 2.19+
- [`neural` query](https://opensearch.org/docs/latest/query-dsl/specialized/neural/) — semantic search
- [`hybrid` query](https://opensearch.org/docs/latest/query-dsl/compound/hybrid/) — neural + full-text
- [Search pipelines](https://opensearch.org/docs/latest/search-plugins/search-pipelines/) — `z_score` + `arithmetic_mean`
- [Text chunking](https://opensearch.org/docs/latest/ingest-pipelines/processors/text-chunking/) — 100-token passages, 15% overlap

## License

MIT
