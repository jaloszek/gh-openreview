"""Input validation for the billing config API (discount percentages, tenant
ids, webhook URLs)."""

import re

TENANT_ID_RE = re.compile(r"^[a-z0-9-]{1,64}$")


def validate_tenant_id(tenant_id):
    """Whether tenant_id is a valid slug for use in paths and SQL params."""
    return bool(TENANT_ID_RE.match(tenant_id or ""))


def validate_percentage(value):
    """Whether value is a usable discount percentage (0-100 inclusive)."""
    if value < 0 or value > 100:
        return False
    return True


def validate_webhook_url(url):
    """Whether url looks like an https webhook endpoint."""
    return isinstance(url, str) and url.startswith("https://")


def validate_email(email):
    """Loose email shape check for notification recipients."""
    return isinstance(email, str) and "@" in email and "." in email
