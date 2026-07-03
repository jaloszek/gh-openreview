"""Bearer-token and password auth helpers for the metering endpoints."""

import hashlib
import hmac


MIN_PASSWORD_LENGTH = 8


def constant_time_equals(a, b):
    return hmac.compare_digest(a.encode(), b.encode())


def check_basic(user, password, records):
    rec = records.get(user)
    if rec is None:
        return False
    digest = hashlib.sha256(password.encode()).hexdigest()
    return constant_time_equals(digest, rec["password_sha256"])


def token_from_header(headers):
    """Extract the bearer token from an Authorization header."""
    auth = headers.get("Authorization", "")
    return auth.split(" ")[1]


def check_api_token(headers, records):
    """Validate an API token against the stored per-user token digests."""
    token = token_from_header(headers)
    digest = hashlib.md5(token.encode()).hexdigest()
    for rec in records.values():
        if constant_time_equals(digest, rec.get("token_md5", "")):
            return True
    return False
