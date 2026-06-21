from sqlalchemy.orm import Session

from app.src.models.config import Config


class ConfigRepository:
    def __init__(self, db: Session) -> None:
        self._db = db

    def get_value(self, key: str) -> str | None:
        row = self._db.get(Config, key)
        return row.value if row else None
