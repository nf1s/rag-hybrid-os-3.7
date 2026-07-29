from pydantic import BaseModel


class QueryRequest(BaseModel):
    question: str
    top_k: int = 5


class ChatRequest(BaseModel):
    message: str
    conversation_id: str | None = None


class Source(BaseModel):
    id: str
    title: str
    excerpt: str
    score: float


class RAGResponse(BaseModel):
    answer: str
    sources: list[Source]


class ChatResponse(BaseModel):
    reply: str
    sources: list[Source]
    conversation_id: str
