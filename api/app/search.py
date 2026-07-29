from opensearchpy import OpenSearch

from . import settings

_client: OpenSearch | None = None


def _get_client() -> OpenSearch:
    global _client
    if _client is None:
        _client = OpenSearch(
            hosts=[settings.OPENSEARCH_URL],
            http_compress=True,
            use_ssl=False,
            verify_certs=False,
            ssl_assert_hostname=False,
            ssl_show_warn=False,
        )
    return _client


def search_hybrid(query_text: str, top_k: int = 5) -> list[dict]:
    client = _get_client()
    body = {
        "size": top_k,
        "_source": {"exclude": ["body_semantic_info", "body_chunks"]},
        "query": {
            "hybrid": {
                "queries": [
                    {"neural": {"body": {"query_text": query_text}}},
                    {
                        "multi_match": {
                            "query": query_text,
                            "fields": ["title^2", "body"],
                        }
                    },
                ]
            }
        },
    }
    response = client.search(
        index="article",
        body=body,
        params={"search_pipeline": "hybrid-search-pipeline"},
    )

    hits = response.get("hits", {}).get("hits", [])
    results = []
    for hit in hits:
        src = hit["_source"]
        results.append(
            {
                "id": src.get("id", ""),
                "title": src.get("title", ""),
                "body": src.get("body", ""),
                "score": hit.get("_score", 0),
            }
        )
    return results
