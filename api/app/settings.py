from os import environ


OPENSEARCH_URL: str = environ.get("OPENSEARCH_URL", "http://hybrid-search-single:9200")
OLLAMA_URL: str = environ.get("OLLAMA_URL", "http://host.docker.internal:11434")
LLM_MODEL: str = environ.get("LLM_MODEL", "llama3.2")
