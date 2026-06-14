"""Domain exceptions for the Platform API.

Raising typed exceptions instead of HTTPException ad-hoc in route handlers has
two concrete benefits:
1. Service-layer code stays free of FastAPI imports and is straightforwardly
   testable without an HTTP stack (just call the function, catch the exception).
2. The mapping from domain error → HTTP response lives in one place (main.py's
   exception handlers), making the contract easy to audit and change globally.
"""


class AppError(Exception):
    """Base class for all application-level errors."""

    status_code: int = 500
    code: str = "INTERNAL_ERROR"

    def __init__(self, message: str, field: str | None = None) -> None:
        super().__init__(message)
        self.message = message
        self.field = field


class NotFoundError(AppError):
    status_code = 404
    code = "NOT_FOUND"


class ConflictError(AppError):
    status_code = 409
    code = "CONFLICT"


class InvalidStateError(AppError):
    """Raised when a state-machine transition is not permitted."""

    status_code = 409
    code = "INVALID_STATE"


class ValidationError(AppError):
    """Raised by service-layer code for semantic validation failures (distinct
    from Pydantic/HTTP request validation, which is handled separately)."""

    status_code = 422
    code = "VALIDATION_ERROR"
