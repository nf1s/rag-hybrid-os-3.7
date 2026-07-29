from os import environ


OPENSEARCH_URL: str = environ.get("OPENSEARCH_URL", "http://hybrid-search-single:9200")
LLM_URL: str = environ.get("LLM_URL", "http://127.0.0.1:8001/v1")
LLM_MODEL: str = environ.get("LLM_MODEL", "qwen2.5-1.5b-instruct")
