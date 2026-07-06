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
