from __future__ import annotations

from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException, Path as ApiPath, Query, Request, Response
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from app.config import Settings
from app.models import (
    USER_ID_PATTERN,
    RankingResponse,
    SummaryResponse,
    TransactionRequest,
    TransactionResponse,
)
from app.supabase import SupabaseAPIError, SupabaseRepository


BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = Settings.from_env()
    app.state.repository = SupabaseRepository(settings)
    try:
        yield
    finally:
        await app.state.repository.close()


app = FastAPI(
    title="Simple Transaction Ranking API",
    version="1.0.0",
    lifespan=lifespan,
)
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


@app.get("/", include_in_schema=False)
async def index() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/transaction", response_model=TransactionResponse, status_code=201)
async def create_transaction(
    request: Request,
    response: Response,
    payload: TransactionRequest,
) -> dict:
    repository: SupabaseRepository = request.app.state.repository
    try:
        result = await repository.record_transaction(payload)
        if result.get("duplicate"):
            response.status_code = 200
        return result
    except SupabaseAPIError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.detail) from exc


@app.get("/summary/{user_id}", response_model=SummaryResponse)
async def get_summary(
    request: Request,
    user_id: str = ApiPath(..., min_length=3, max_length=40),
) -> dict:
    if not USER_ID_PATTERN.fullmatch(user_id):
        raise HTTPException(
            status_code=422,
            detail="user_id may contain only letters, numbers, '_' and '-'",
        )

    repository: SupabaseRepository = request.app.state.repository
    try:
        return await repository.get_summary(user_id)
    except SupabaseAPIError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.detail) from exc


@app.get("/ranking", response_model=RankingResponse)
async def get_ranking(
    request: Request,
    limit: int = Query(20, ge=1, le=100),
) -> dict:
    repository: SupabaseRepository = request.app.state.repository
    try:
        return await repository.get_ranking(limit)
    except SupabaseAPIError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.detail) from exc
