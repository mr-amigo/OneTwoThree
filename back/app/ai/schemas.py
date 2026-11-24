from datetime import date, datetime

from pydantic import BaseModel, Field, field_validator


class AgendaItem(BaseModel):
    topic: str = Field(min_length=1)
    owner: str | None = None
    minutes: int | None = Field(default=None, ge=1, le=480)


class ActionItem(BaseModel):
    task: str = Field(min_length=1)
    owner: str | None = None
    due: date | None = None


class ParsedAgenda(BaseModel):
    title: str | None = None
    starts_at: str | None = None
    duration_minutes: int | None = Field(default=None, ge=1, le=600)
    items: list[AgendaItem] = Field(default_factory=list)
    action_items: list[ActionItem] = Field(default_factory=list)
    language: str

    @field_validator("starts_at")
    @classmethod
    def _iso_with_offset(cls, value: str | None) -> str | None:
        if value is None:
            return None
        parsed = datetime.fromisoformat(value)  # raises ValueError -> ValidationError
        if parsed.tzinfo is None:
            raise ValueError("starts_at must include a UTC offset")
        return value
