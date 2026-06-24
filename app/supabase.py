from __future__ import annotations

from decimal import Decimal
from typing import Any

import httpx

from app.config import Settings
from app.models import TransactionRequest


class SupabaseAPIError(Exception):
    def __init__(self, status_code: int, detail: str) -> None:
        self.status_code = status_code
        self.detail = detail
        super().__init__(detail)


class SupabaseRepository:
    def __init__(self, settings: Settings) -> None:
        self._client = httpx.AsyncClient(
            base_url=settings.supabase_url,
            timeout=httpx.Timeout(10.0),
            headers={
                "apikey": settings.supabase_key,
                "Authorization": f"Bearer {settings.supabase_key}",
                "Content-Type": "application/json",
            },
        )

    async def close(self) -> None:
        await self._client.aclose()

    async def record_transaction(self, payload: TransactionRequest) -> dict[str, Any]:
        data = {
            "p_request_id": payload.request_id,
            "p_user_id": payload.user_id,
            "p_amount": str(payload.amount),
            "p_transaction_type": payload.transaction_type,
        }
        return await self._rpc("record_transaction", data)

    async def get_summary(self, user_id: str) -> dict[str, Any]:
        return await self._rpc("get_summary", {"p_user_id": user_id})

    async def get_ranking(self, limit: int) -> dict[str, Any]:
        return await self._rpc("get_ranking", {"p_limit": limit})

    async def _rpc(self, function_name: str, payload: dict[str, Any]) -> dict[str, Any]:
        try:
            response = await self._client.post(f"/rest/v1/rpc/{function_name}", json=payload)
        except httpx.TimeoutException as exc:
            raise SupabaseAPIError(504, "database request timed out") from exc
        except httpx.HTTPError as exc:
            raise SupabaseAPIError(502, "database connection failed") from exc

        if response.is_success:
            result = response.json()
            if isinstance(result, dict):
                return _normalize_numbers(result)
            return {"data": result}

        raise _to_api_error(response)


def _to_api_error(response: httpx.Response) -> SupabaseAPIError:
    status_code = response.status_code
    detail = response.text

    try:
        error = response.json()
        detail = error.get("message") or error.get("hint") or response.text
    except ValueError:
        pass

    lowered = detail.lower()
    if "duplicate_request_conflict" in lowered:
        return SupabaseAPIError(409, "request_id has already been used with different data")
    if "rate_limited" in lowered:
        return SupabaseAPIError(429, "too many transactions for this user; try again shortly")
    if "validation_failed" in lowered:
        clean = detail.split("validation_failed:", 1)[-1].strip()
        return SupabaseAPIError(422, clean or "invalid request")
    if status_code == 404 and "record_transaction" in lowered:
        return SupabaseAPIError(503, "Supabase schema/RPC functions are not installed")
    if status_code >= 500:
        return SupabaseAPIError(502, "database request failed")

    return SupabaseAPIError(status_code, detail)


def _normalize_numbers(value: Any) -> Any:
    if isinstance(value, list):
        return [_normalize_numbers(item) for item in value]
    if isinstance(value, dict):
        return {key: _normalize_numbers(item) for key, item in value.items()}
    if isinstance(value, Decimal):
        return str(value)
    return value
