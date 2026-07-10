from __future__ import annotations

import asyncio
import json
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.llm import (
    LLMEmptyResponseError,
    LLMTimeoutError,
    LocalLLMClient,
    wisdom_to_temperature,
)
from app.main import create_app


def settings(**overrides) -> Settings:
    values = {
        "llm_base_url": "http://llm.test/v1",
        "llm_model": "test-model",
        "llm_api_key": "",
        "llm_timeout_seconds": 2.0,
        "max_question_length": 20,
        "max_body_bytes": 8192,
    }
    values.update(overrides)
    return Settings(**values)


class StubLLM:
    def __init__(self, answer: str = "Береги рощу.", error: Exception | None = None) -> None:
        self.answer = answer
        self.error = error
        self.calls: list[tuple[str, float]] = []

    async def complete(self, question: str, wisdom_level: float) -> str:
        self.calls.append((question, wisdom_level))
        if self.error:
            raise self.error
        return self.answer

    async def is_available(self) -> bool:
        return self.error is None


@pytest.mark.parametrize(
    ("wisdom", "temperature"),
    [(index / 10, round(1 - index / 10, 1)) for index in range(11)],
)
def test_all_wisdom_temperature_pairs(wisdom: float, temperature: float) -> None:
    assert wisdom_to_temperature(wisdom) == temperature


def test_wisdom_endpoint_calls_local_llm() -> None:
    llm = StubLLM("Сначала защити стаю.")
    client = TestClient(create_app(settings(), llm_client=llm))

    response = client.post("/api/wisdom", json={"question": "Что делать?", "wisdomLevel": 0.7})

    assert response.status_code == 200
    assert response.json() == {"wisdom": "Сначала защити стаю."}
    assert llm.calls == [("Что делать?", 0.7)]


@pytest.mark.parametrize(
    "body",
    [
        {"question": "", "wisdomLevel": 0.5},
        {"question": 42, "wisdomLevel": 0.5},
        {"question": "Вопрос", "wisdomLevel": -0.1},
        {"question": "Вопрос", "wisdomLevel": 1.1},
        {"question": "Вопрос", "wisdomLevel": 0.55},
    ],
)
def test_invalid_requests_are_rejected(body: dict) -> None:
    client = TestClient(create_app(settings(), llm_client=StubLLM()))
    assert client.post("/api/wisdom", json=body).status_code == 422


def test_too_long_question_is_rejected() -> None:
    client = TestClient(create_app(settings(max_question_length=5), llm_client=StubLLM()))
    response = client.post("/api/wisdom", json={"question": "123456", "wisdomLevel": 0.5})
    assert response.status_code == 422


def test_llm_error_is_safe_for_user() -> None:
    llm = StubLLM(error=LLMTimeoutError("Локальная модель слишком долго размышляет. Попробуй ещё раз."))
    client = TestClient(create_app(settings(), llm_client=llm))
    response = client.post("/api/wisdom", json={"question": "Что делать?", "wisdomLevel": 0.5})
    assert response.status_code == 503
    assert "traceback" not in response.text.lower()
    assert "http://llm.test" not in response.text


def test_system_message_precedes_user_message_and_temperature_is_computed() -> None:
    captured: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured.update(json.loads(request.content))
        return httpx.Response(200, json={"choices": [{"message": {"content": "Мудрый ответ"}}]})

    client = LocalLLMClient(settings(), "IMMUTABLE SYSTEM TEXT", httpx.MockTransport(handler))
    answer = asyncio.run(client.complete("Пользовательский вопрос", 0.8))

    assert answer == "Мудрый ответ"
    assert captured["messages"] == [
        {"role": "system", "content": "IMMUTABLE SYSTEM TEXT"},
        {"role": "user", "content": "Пользовательский вопрос"},
    ]
    assert captured["temperature"] == 0.2


def test_empty_llm_response_is_rejected() -> None:
    transport = httpx.MockTransport(
        lambda _: httpx.Response(200, json={"choices": [{"message": {"content": "  "}}]})
    )
    client = LocalLLMClient(settings(), "system", transport)
    with pytest.raises(LLMEmptyResponseError):
        asyncio.run(client.complete("Вопрос", 0.5))


def test_frontend_contains_all_interaction_states() -> None:
    script = (Path(__file__).parents[1] / "static" / "app.js").read_text(encoding="utf-8")
    for state in ("loading", "success", "error"):
        assert f'showState("{state}"' in script
    assert "event.ctrlKey || event.metaKey" in script

