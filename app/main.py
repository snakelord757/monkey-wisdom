from __future__ import annotations

import math
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, ConfigDict, Field, field_validator

from .config import ROOT_DIR, Settings
from .llm import LLMEmptyResponseError, LLMError, LocalLLMClient
from .rate_limit import SlidingWindowLimiter


STATIC_DIR = ROOT_DIR / "static"
PROMPT_PATH = ROOT_DIR / "prompts" / "silverback-system.txt"


class WisdomRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    question: str
    wisdomLevel: float = Field(ge=0, le=1)

    @field_validator("question")
    @classmethod
    def question_must_have_text(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("question must not be empty")
        return value

    @field_validator("wisdomLevel")
    @classmethod
    def wisdom_must_match_step(cls, value: float) -> float:
        if not math.isclose(value * 10, round(value * 10), abs_tol=1e-9):
            raise ValueError("wisdomLevel must use a 0.1 step")
        return round(value, 1)


class WisdomResponse(BaseModel):
    wisdom: str


def create_app(
    settings: Settings | None = None,
    llm_client: LocalLLMClient | None = None,
    limiter: SlidingWindowLimiter | None = None,
) -> FastAPI:
    settings = settings or Settings.from_env()
    system_prompt = PROMPT_PATH.read_text(encoding="utf-8").strip()
    llm_client = llm_client or LocalLLMClient(settings, system_prompt)
    limiter = limiter or SlidingWindowLimiter()

    app = FastAPI(title="Мудрости гориллы", docs_url="/docs", redoc_url=None)
    app.state.settings = settings
    app.state.llm_client = llm_client

    @app.middleware("http")
    async def request_size_limit(request: Request, call_next):
        content_length = request.headers.get("content-length")
        if content_length:
            try:
                if int(content_length) > settings.max_body_bytes:
                    return JSONResponse(status_code=413, content={"detail": "Запрос слишком большой."})
            except ValueError:
                return JSONResponse(status_code=400, content={"detail": "Некорректный запрос."})
        return await call_next(request)

    @app.exception_handler(RequestValidationError)
    async def validation_error(_: Request, __: RequestValidationError) -> JSONResponse:
        return JSONResponse(status_code=422, content={"detail": "Проверь вопрос и выбранный уровень мудрости."})

    @app.get("/", include_in_schema=False)
    async def index() -> FileResponse:
        return FileResponse(STATIC_DIR / "index.html")

    @app.post("/api/wisdom", response_model=WisdomResponse)
    async def wisdom(payload: WisdomRequest, request: Request) -> WisdomResponse | JSONResponse:
        if len(payload.question) > settings.max_question_length:
            return JSONResponse(
                status_code=422,
                content={"detail": f"Вопрос должен быть не длиннее {settings.max_question_length} символов."},
            )
        client_key = request.client.host if request.client else "unknown"
        if not await limiter.allow(client_key):
            return JSONResponse(
                status_code=429,
                content={"detail": "Слишком много вопросов подряд. Дай Сильвербеку немного времени."},
                headers={"Retry-After": "60"},
            )
        try:
            answer = await llm_client.complete(payload.question, payload.wisdomLevel)
            return WisdomResponse(wisdom=answer)
        except LLMEmptyResponseError as exc:
            return JSONResponse(status_code=502, content={"detail": str(exc)})
        except LLMError as exc:
            return JSONResponse(status_code=503, content={"detail": str(exc)})

    @app.get("/api/health")
    async def health() -> JSONResponse:
        llm_available = await llm_client.is_available()
        status = 200 if llm_available else 503
        return JSONResponse(
            status_code=status,
            content={"app": "ok", "llm": "available" if llm_available else "unavailable"},
        )

    app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")
    return app


app = create_app()

