from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent


def _load_dotenv(path: Path) -> None:
    """Load a small, dependency-free subset of .env syntax."""
    if not path.is_file():
        return
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        os.environ.setdefault(key, value)


@dataclass(frozen=True)
class Settings:
    llm_base_url: str
    llm_model: str
    llm_api_key: str
    llm_timeout_seconds: float
    max_question_length: int
    max_body_bytes: int

    @classmethod
    def from_env(cls) -> "Settings":
        _load_dotenv(ROOT_DIR / ".env")
        max_question_length = max(1, int(os.getenv("MAX_QUESTION_LENGTH", "4000")))
        return cls(
            llm_base_url=os.getenv("LLM_BASE_URL", "http://127.0.0.1:8001/v1").rstrip("/"),
            llm_model=os.getenv("LLM_MODEL", "local-model"),
            llm_api_key=os.getenv("LLM_API_KEY", ""),
            llm_timeout_seconds=max(1.0, float(os.getenv("LLM_TIMEOUT_SECONDS", "120"))),
            max_question_length=max_question_length,
            max_body_bytes=max(8192, max_question_length * 4 + 2048),
        )

