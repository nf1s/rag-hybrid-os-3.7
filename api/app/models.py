from pydantic import BaseModel


class QueryRequest(BaseModel):
    question: str
    top_k: int = 5


class Source(BaseModel):
    id: str
    title: str
    excerpt: str
    score: float


class RAGResponse(BaseModel):
    answer: str
    sources: list[Source]
