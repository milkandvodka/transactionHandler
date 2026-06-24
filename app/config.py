from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def load_dotenv(path: str = ".env") -> None:
    env_path = Path(path)
    if not env_path.exists():
        return

    for raw_line in env_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        os.environ.setdefault(key, value)


@dataclass(frozen=True)
class Settings:
    supabase_url: str
    supabase_key: str
    max_stored_transactions: int = 50

    @classmethod
    def from_env(cls) -> "Settings":
        load_dotenv()
        supabase_url = os.getenv("SUPABASE_URL", "").rstrip("/")
        supabase_key = os.getenv("SUPABASE_KEY", "")
        max_stored_transactions = _read_int(
            "MAX_STORED_TRANSACTIONS",
            default=50,
            minimum=1,
            maximum=100,
        )

        missing = [
            name
            for name, value in {
                "SUPABASE_URL": supabase_url,
                "SUPABASE_KEY": supabase_key,
            }.items()
            if not value
        ]
        if missing:
            joined = ", ".join(missing)
            raise RuntimeError(f"Missing required environment variable(s): {joined}")

        return cls(
            supabase_url=supabase_url,
            supabase_key=supabase_key,
            max_stored_transactions=max_stored_transactions,
        )


def _read_int(name: str, default: int, minimum: int, maximum: int) -> int:
    raw_value = os.getenv(name)
    if raw_value is None or raw_value.strip() == "":
        return default

    try:
        value = int(raw_value)
    except ValueError as exc:
        raise RuntimeError(f"{name} must be an integer") from exc

    if value < minimum or value > maximum:
        raise RuntimeError(f"{name} must be between {minimum} and {maximum}")

    return value
