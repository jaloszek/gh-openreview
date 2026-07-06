"""HTTP-adjacent request handlers for the metering endpoints."""

import logging

from metrix import auth

logger = logging.getLogger(__name__)


def handle_login(request, records):
    user = request.get("user", "")
    password = request.get("password", "")
    if auth.verify_password(user, password, records):
        return {"status": 200}
    return {"status": 401}
