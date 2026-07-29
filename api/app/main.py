from fastapi import FastAPI, HTTPException
from pydantic_ai import Agent
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.providers.ollama import OllamaProvider

from . import settings
from .models import QueryRequest, RAGResponse, Source
from .search import search_hybrid

app = FastAPI(title="RAG API")

SYSTEM_PROMPT = """You are a helpful RAG (Retrieval-Augmented Generation) assistant.

Use the `opensearch_search` tool to find relevant articles before answering.
When answering, cite your sources by referencing the article titles.
If the search results don't contain enough information to answer the question,
say so clearly. Base your answer on the retrieved articles, not on general knowledge."""

model = OpenAIChatModel(
    settings.LLM_MODEL,
    provider=OllamaProvider(base_url=settings.OLLAMA_URL),
)

agent = Agent(
    model,
    system_prompt=SYSTEM_PROMPT,
    output_type=RAGResponse,
)


@agent.tool_plain
def opensearch_search(query: str) -> str:
    """Search the article database for relevant information. Returns article excerpts."""
    results = search_hybrid(query, top_k=5)
    if not results:
        return "No relevant articles found."

    lines = []
    for r in results:
        excerpt = r["body"][:500]
        lines.append(f"[Article {r['id']}: {r['title']}] (score: {r['score']:.3f})")
        lines.append(excerpt)
        lines.append("")
    return "\n".join(lines)


@app.post("/api/rag/query")
async def query(body: QueryRequest) -> RAGResponse:
    try:
        result = await agent.run(body.question, output_type=RAGResponse)
        return result.output
    except Exception as e:
        raise HTTPException(status_code=502, detail=str(e))


@app.get("/api/rag/health")
async def health():
    return {"status": "ok"}
