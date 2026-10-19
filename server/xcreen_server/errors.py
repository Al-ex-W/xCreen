"""Errors shared by the gateway adapter, session runtime and API."""
from __future__ import annotations


class GatewayError(Exception):
    code = "gateway_error"


class Unavailable(GatewayError):
    code = "unavailable"

    def __init__(self, message: str = "Hermes gateway is not connected."):
        super().__init__(message)


class DeadlineExceeded(GatewayError):
    code = "deadline_exceeded"

    def __init__(self, message: str = "Hermes gateway did not answer before the deadline."):
        super().__init__(message)


class ProtocolError(GatewayError):
    code = "protocol_failure"

    def __init__(self, message: str = "Hermes gateway returned an invalid response."):
        super().__init__(message)


class Cancelled(GatewayError):
    code = "cancelled"

    def __init__(self, message: str = "The xCreen turn was cancelled before completion."):
        super().__init__(message)


class RemoteFailure(GatewayError):
    code = "remote_failure"

    def __init__(self, message: str):
        super().__init__(f"Hermes gateway rejected the request: {message}")


class ProviderFailure(GatewayError):
    """The host closed the turn with a provider/model failure (status:error). This is not
    evidence of absent effects; only a host receipt can prove that."""
    code = "provider_failure"

    def __init__(self, rate_limited: bool):
        self.rate_limited = rate_limited
        super().__init__("The model provider rate-limited the xCreen turn." if rate_limited else "The model provider failed the xCreen turn.")

    def __eq__(self, other):
        return isinstance(other, ProviderFailure) and other.rate_limited == self.rate_limited

    __hash__ = Exception.__hash__
