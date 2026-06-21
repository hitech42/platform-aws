from sqlalchemy import text
from sqlalchemy.orm import Session


class HealthRepository:
    def __init__(self, db: Session) -> None:
        self._db = db

    def ping(self) -> None:
        """Execute a trivial query to verify DB connectivity. Raises on failure."""
        self._db.execute(text("SELECT 1"))
