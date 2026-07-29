# k8s-hybrid-search-os-3.7-semantic-field

Hybrid semantic + full-text search on **OpenSearch 3.7** using the `semantic` field type and a `z_score` normalization search pipeline. Deployed to Kubernetes via **Skaffold** + **Helm** with a single `skaffold run` command.

## Architecture

```
                  ┌──────────────────┐
                  │   UI (Nginx)     │  single-page search app
                  │  :80             │  3 modes: FT / Semantic / Hybrid
                  └────────┬─────────┘
                           │ /api/os/ → upstream
                  ┌────────▼─────────┐
                  │  OpenSearch 3.7  │  hybrid-search-single:9200
                  │  security: off   │
                  └────────┬─────────┘
                           │
         ┌─────────────────┼─────────────────┐
         ▼                 ▼                  ▼
  ┌────────────┐   ┌────────────┐   ┌──────────────────┐
  │ template-  │   │  model-    │   │    seed-job      │
  │ job        │   │  job       │   │  30 articles     │
  │ index      │   │  ML model  │   │                  │
  │ template   │   │  pipeline  │   │                  │
  └────────────┘   └────────────┘   └──────────────────┘
```

Three init Jobs run in sequence (waited by `just` commands, not by Helm hooks):

| Job | What it does |
|-----|-------------|
| `template-job` | Applies the `article` index template (basic text mapping) |
| `model-job` | Registers + deploys `all-MiniLM-L12-v2`, updates template to `semantic` field, creates chunking ingest pipeline, creates hybrid search pipeline |
| `seed-job` | Indexes 30 sample articles via `_bulk` with the chunking pipeline |

## Features

### Search Modes

| Mode | Query | Pipeline |
|------|-------|----------|
| **Full Text** | `multi_match` on `title` + `body` | none |
| **Semantic** | `neural` on `body` (semantic field) | none |
| **Hybrid** | `hybrid` query (neural + multi_match) | `hybrid-search-pipeline` |

### Hybrid Scoring

OpenSearch's `hybrid` query runs both sub-queries independently, then the **`hybrid-search-pipeline`** search pipeline applies:

- **Normalization:** `z_score` (standardizes each result set to mean 0, stddev 1)
- **Combination:** `arithmetic_mean` with weights `[0.59, 0.41]` (reflects a 0.65:0.45 ratio normalized to sum to 1.0)

The result is a single, deduplicated set of hits with combined scores.

### ML Model

- [sentence-transformers/all-MiniLM-L12-v2](https://huggingface.co/sentence-transformers/all-MiniLM-L12-v2)
- Registered via URL (`TORCH_SCRIPT` format)
- Automatically deployed on first run; reused across redeploys (persistent volume)
- When model already exists: article index is preserved
- When model is newly registered: article index is deleted and recreated

### Text Chunking

The `article-chunking` ingest pipeline splits the `body` field into 100-token passages with 15% overlap, enabling OpenSearch to generate embeddings per chunk for more precise neural search.

### Persistence

OpenSearch data is persisted on a **10Gi** PVC. Model + index survive pod restarts and redeploys.

## Project Structure

```
├── skaffold.yaml             # Build & deploy config
├── justfile                  # Task runner shortcuts
├── charts/
│   ├── hybrid-search/        # Parent Helm chart (OpenSearch + Dashboards)
│   ├── ui/                   # Nginx serving the search UI
│   ├── template-job/         # Index template job
│   ├── model-job/            # ML model registration + pipelines
│   └── seed-job/             # Seed data job
├── frontend/
│   ├── Dockerfile            # nginx:alpine
│   ├── nginx.conf            # Proxies /api/os/ → OpenSearch
│   └── index.html            # Single-page search UI (no framework)
├── template-job/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   └── mappings.json         # Initial text-only template
├── model-job/
│   ├── Dockerfile
│   └── entrypoint.sh         # End-to-end model lifecycle + pipelines
└── seed-job/
    ├── Dockerfile
    ├── entrypoint.sh
    └── seed.json             # 30 sample articles
```

## Prerequisites

- Kubernetes cluster (e.g., Colima, kind, minikube)
- [Skaffold](https://skaffold.dev)
- [Helm](https://helm.sh)
- [just](https://github.com/casey/just) (optional — for task runner shortcuts)

### Helm Dependencies

```sh
just rebuild
```

Downloads the `opensearch` and `opensearch-dashboards` chart dependencies.

## Deploy

```sh
skaffold run
```

This builds all 4 Docker images, deploys 5 Helm releases (OpenSearch, Dashboards, UI, and 3 Jobs), and waits for everything to stabilize. The init Jobs auto-execute in sequence.

### First Deploy (slow)

Expect **2–5 minutes** for `model-job` — it downloads and deploys `all-MiniLM-L12-v2` (~90 MB) on first run. Subsequent redeploys are fast since the model is cached on the PV.

### Verify Jobs

```sh
just model-logs
just seed-logs
```

Check that the model deployed and articles were seeded.

### Wait for Jobs

```sh
kubectl wait --for=condition=complete job/template-job -n opensearch --timeout=120s
kubectl wait --for=condition=complete job/model-job -n opensearch --timeout=300s
kubectl wait --for=condition=complete job/seed-job -n opensearch --timeout=120s
```

## Use

### Port-Forward the UI

```sh
just port-forward-ui
# → http://localhost:8080
```

### Direct OpenSearch Access

```sh
just port-forward
# → http://localhost:9200
```

### Example Queries

**Full-text:**
```sh
curl -s 'http://localhost:9200/article/_search' -H 'Content-Type: application/json' \
  -d '{"query":{"multi_match":{"query":"quantum computing","fields":["title","body"]}}}'
```

**Semantic (neural):**
```sh
curl -s 'http://localhost:9200/article/_search' -H 'Content-Type: application/json' \
  -d '{"_source":{"exclude":["body_semantic_info"]},"query":{"neural":{"body":{"query_text":"quantum computing"}}}}'
```

**Hybrid (with server-side z-score normalization):**
```sh
curl -s 'http://localhost:9200/article/_search?search_pipeline=hybrid-search-pipeline' \
  -H 'Content-Type: application/json' \
  -d '{"_source":{"exclude":["body_semantic_info"]},"query":{"hybrid":{"queries":[{"neural":{"body":{"query_text":"quantum computing"}}},{"multi_match":{"query":"quantum computing","fields":["title^2","body"]}}]}}}'
```

### Re-seed Data

```sh
just reseed
```

Deletes the `seed-job` pod and re-runs Skaffold to re-index the 30 articles.

## Cleanup

```sh
skaffold delete
```

Note: PVCs are **not** automatically deleted. To fully wipe:

```sh
kubectl delete pvc -n opensearch --all
```

## Key OpenSearch Features Used

- [`semantic` field type](https://opensearch.org/docs/latest/field-types/semantic/) — OpenSearch 2.19+
- [`neural` query](https://opensearch.org/docs/latest/query-dsl/specialized/neural/) — semantic search on semantic fields
- [`hybrid` query](https://opensearch.org/docs/latest/query-dsl/compound/hybrid/) — combines neural + full-text
- [Search pipelines](https://opensearch.org/docs/latest/search-plugins/search-pipelines/) — `normalization-processor` with `z_score` + `arithmetic_mean`
- [Text chunking](https://opensearch.org/docs/latest/ingest-pipelines/processors/text-chunking/) — `fixed_token_length` with 15% overlap
- [Model serving via URL](https://opensearch.org/docs/latest/ml-commons-plugin/pretrained-models/#upload-pretrained-model-to-opensesearch) — `TORCH_SCRIPT` format

## License

MIT
