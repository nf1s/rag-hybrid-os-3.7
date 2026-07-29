import json
import uuid

from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse
from pydantic_ai import Agent
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.providers.openai import OpenAIProvider

from . import settings
from .models import ChatRequest, ChatResponse, QueryRequest, RAGResponse, Source
from .search import search_hybrid

app = FastAPI(title="RAG API")

SYSTEM_PROMPT = """You are a helpful RAG assistant. Answer the user's question conversationally based on the context provided in the user's message. Reference article titles as sources. Be concise but thorough. Maintain a conversational tone. If the context doesn't contain enough information, say so clearly."""

model = OpenAIChatModel(
    settings.LLM_MODEL,
    provider=OpenAIProvider(
        base_url=settings.LLM_URL,
        api_key="not-needed",
    ),
)

agent = Agent(
    model,
    system_prompt=SYSTEM_PROMPT,
)


def _search_and_format(query: str) -> tuple[str, list[Source]]:
    results = search_hybrid(query, top_k=5)
    sources = []
    if not results:
        return "No relevant articles found for this query.", sources

    lines = []
    for r in results:
        excerpt = r["body"][:500]
        lines.append(f"[Article {r['id']}: {r['title']}] (score: {r['score']:.3f})")
        lines.append(excerpt)
        lines.append("")
        sources.append(Source(
            id=r["id"],
            title=r["title"],
            excerpt=excerpt,
            score=r["score"],
        ))
    return "\n".join(lines), sources


def _build_enriched(history: list[tuple[str, str]], context: str, message: str) -> str:
    conversation = ""
    for q, a in history:
        conversation += f"User: {q}\nAssistant: {a}\n\n"
    return f"{conversation}Retrieved articles:\n{context}\n\nUser question: {message}"


_conversations: dict[str, list[tuple[str, str]]] = {}


@app.post("/api/rag/chat/stream")
async def chat_stream(body: ChatRequest):
    conversation_id = body.conversation_id or str(uuid.uuid4())
    history = _conversations.get(conversation_id, [])

    context, sources = _search_and_format(body.message)
    enriched = _build_enriched(history, context, body.message)

    async def event_stream():
        nonlocal conversation_id
        try:
            yield f"data: {json.dumps({'type': 'sources', 'sources': [s.model_dump() for s in sources]})}\n\n"

            full_text = ""
            async with agent.run_stream(enriched) as result:
                async for text in result.stream_text(delta=True):
                    full_text += text
                    yield f"data: {json.dumps({'type': 'delta', 'text': text})}\n\n"

            _conversations[conversation_id] = (history + [(body.message, full_text)])[-5:]
            yield f"data: {json.dumps({'type': 'done', 'conversation_id': conversation_id})}\n\n"
        except Exception as e:
            yield f"data: {json.dumps({'type': 'error', 'detail': str(e)})}\n\n"

    return StreamingResponse(event_stream(), media_type="text/event-stream")


@app.post("/api/rag/chat")
async def chat(body: ChatRequest) -> ChatResponse:
    conversation_id = body.conversation_id or str(uuid.uuid4())
    history = _conversations.get(conversation_id, [])
    try:
        context, sources = _search_and_format(body.message)
        enriched = _build_enriched(history, context, body.message)
        result = await agent.run(enriched)
        _conversations[conversation_id] = (history + [(body.message, result.output)])[-5:]

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
        context, sources = _search_and_format(body.question)
        enriched = f"Retrieved articles:\n{context}\n\nUser question: {body.question}"
        result = await agent.run(enriched)
        return RAGResponse(
            answer=result.output,
            sources=sources,
        )
    except Exception as e:
        raise HTTPException(status_code=502, detail=str(e))


@app.get("/api/rag/health")
async def health():
    return {"status": "ok"}
