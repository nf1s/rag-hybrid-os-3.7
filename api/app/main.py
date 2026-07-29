import re
import uuid

from fastapi import FastAPI, HTTPException
from pydantic_ai import Agent
from pydantic_ai.messages import ModelRequest, ModelResponse, ToolCallPart, ToolReturnPart
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.providers.ollama import OllamaProvider

from . import settings
from .models import ChatRequest, ChatResponse, QueryRequest, RAGResponse, Source
from .search import search_hybrid

app = FastAPI(title="RAG API")

SYSTEM_PROMPT = """You are a helpful RAG (Retrieval-Augmented Generation) assistant engaging in conversation.

Always use the `opensearch_search` tool to find relevant articles before answering every user message — including follow-ups like "tell me more" or "elaborate". Search for the most relevant information each time.

When answering:
- Reference article titles as sources
- Be concise but thorough
- Maintain a conversational tone
- If search results don't contain enough information, say so clearly

You can reference previous parts of the conversation for context."""

model = OpenAIChatModel(
    settings.LLM_MODEL,
    provider=OllamaProvider(base_url=settings.OLLAMA_URL),
)

agent = Agent(
    model,
    system_prompt=SYSTEM_PROMPT,
)


@agent.tool_plain
def opensearch_search(query: str) -> str:
    """Search the knowledge base for articles relevant to the user's question. Use specific, targeted search terms. Returns article titles, scores, and body excerpts."""
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


def _extract_sources_from_history(messages: list) -> list[Source]:
    sources = []
    seen_ids = set()
    for msg in reversed(messages):
        if isinstance(msg, ModelRequest):
            for part in msg.parts:
                if isinstance(part, ToolReturnPart):
                    content = part.content if isinstance(part.content, str) else str(part.content)
                    for m in re.finditer(r'\[Article (\d+): ([^\]]+)\] \(score: ([\d.]+)\)', content):
                        if m.group(1) not in seen_ids:
                            seen_ids.add(m.group(1))
                            sources.append(Source(id=m.group(1), title=m.group(2), excerpt="", score=float(m.group(3))))
        if len(sources) >= 3:
            break
    return sources


_conversations: dict[str, list] = {}


@app.post("/api/rag/chat")
async def chat(body: ChatRequest) -> ChatResponse:
    conversation_id = body.conversation_id or str(uuid.uuid4())
    history = _conversations.get(conversation_id, [])
    try:
        result = await agent.run(body.message, message_history=history)
        _conversations[conversation_id] = result.all_messages()
        sources = _extract_sources_from_history(result.all_messages())
        return ChatResponse(
            reply=result.output,
            sources=sources,
            conversation_id=conversation_id,
        )
    except Exception as e:
        raise HTTPException(status_code=502, detail=str(e))


@app.post("/api/rag/query")
async def query(body: QueryRequest) -> RAGResponse:
    try:
        result = await agent.run(body.question)
        sources = _extract_sources_from_history(result.all_messages())
        return RAGResponse(
            answer=result.output,
            sources=sources,
        )
    except Exception as e:
        raise HTTPException(status_code=502, detail=str(e))


@app.get("/api/rag/health")
async def health():
    return {"status": "ok"}
