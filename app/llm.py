from __future__ import annotations

from dataclasses import dataclass

import httpx

from .config import Settings


class LLMError(Exception):
    """Safe, user-facing failure from the local language model."""


class LLMUnavailableError(LLMError):
    pass


class LLMTimeoutError(LLMError):
    pass


class LLMEmptyResponseError(LLMError):
    pass


def wisdom_to_temperature(wisdom_level: float) -> float:
    return round(1 - wisdom_level, 1)


@dataclass
class LocalLLMClient:
    settings: Settings
    system_prompt: str
    transport: httpx.AsyncBaseTransport | None = None

    async def complete(self, question: str, wisdom_level: float) -> str:
        headers = {"Content-Type": "application/json"}
        if self.settings.llm_api_key:
            headers["Authorization"] = f"Bearer {self.settings.llm_api_key}"

        payload = {
            "model": self.settings.llm_model,
            "messages": [
                {"role": "system", "content": self.system_prompt},
                {"role": "user", "content": question},
            ],
            "temperature": wisdom_to_temperature(wisdom_level),
        }

        try:
            async with httpx.AsyncClient(
                timeout=self.settings.llm_timeout_seconds,
                transport=self.transport,
            ) as client:
                response = await client.post(
                    f"{self.settings.llm_base_url}/chat/completions",
                    headers=headers,
                    json=payload,
                )
                response.raise_for_status()
                data = response.json()
        except httpx.TimeoutException as exc:
            raise LLMTimeoutError("Локальная модель слишком долго размышляет. Попробуй ещё раз.") from exc
        except (httpx.HTTPError, ValueError) as exc:
            raise LLMUnavailableError("Не удалось связаться с локальной моделью. Проверь, что она запущена.") from exc

        try:
            content = data["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError) as exc:
            raise LLMEmptyResponseError("Сильвербек промолчал. Попробуй спросить иначе.") from exc

        if not isinstance(content, str) or not content.strip():
            raise LLMEmptyResponseError("Сильвербек промолчал. Попробуй спросить иначе.")
        return content.strip()

    async def is_available(self) -> bool:
        headers = {"Authorization": f"Bearer {self.settings.llm_api_key}"} if self.settings.llm_api_key else {}
        try:
            async with httpx.AsyncClient(timeout=min(3.0, self.settings.llm_timeout_seconds), transport=self.transport) as client:
                response = await client.get(f"{self.settings.llm_base_url}/models", headers=headers)
                return response.status_code < 500
        except httpx.HTTPError:
            return False

