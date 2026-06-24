from __future__ import annotations

import re
from decimal import Decimal
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


USER_ID_PATTERN = re.compile(r"^[A-Za-z0-9_-]{3,40}$")
REQUEST_ID_PATTERN = re.compile(r"^[A-Za-z0-9:_-]{8,80}$")


class TransactionRequest(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True)

    request_id: str = Field(
        ...,
        min_length=8,
        max_length=80,
        description="Client-generated idempotency key for this transaction.",
    )
    user_id: str = Field(..., min_length=3, max_length=40)
    amount: Decimal = Field(..., gt=0, le=Decimal("100000"))
    transaction_type: Literal["purchase", "refund"] = "purchase"

    @field_validator("request_id")
    @classmethod
    def validate_request_id(cls, value: str) -> str:
        if not REQUEST_ID_PATTERN.fullmatch(value):
            raise ValueError("request_id may contain only letters, numbers, ':', '_' and '-'")
        return value

    @field_validator("user_id")
    @classmethod
    def validate_user_id(cls, value: str) -> str:
        if not USER_ID_PATTERN.fullmatch(value):
            raise ValueError("user_id may contain only letters, numbers, '_' and '-'")
        return value

    @field_validator("amount")
    @classmethod
    def validate_amount_precision(cls, value: Decimal) -> Decimal:
        if value.as_tuple().exponent < -2:
            raise ValueError("amount supports up to 2 decimal places")
        return value


class TransactionResponse(BaseModel):
    status: Literal["created", "duplicate"]
    duplicate: bool
    transaction: dict
    summary: dict


class SummaryResponse(BaseModel):
    user_id: str
    total_amount: Decimal
    transaction_count: int
    points: int
    last_transaction_at: str | None


class RankingResponse(BaseModel):
    formula: str
    items: list[dict]

