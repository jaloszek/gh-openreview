"""Webhook notifications for billing events (invoice ready, payment failed)."""

import json
import logging
import urllib.request

logger = logging.getLogger(__name__)

MAX_RETRIES = 3


def _post(url, payload):
    """POST a JSON payload to a webhook URL, raising on a non-2xx response."""
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}
    )
    urllib.request.urlopen(req, timeout=5)


def notify(url, event_type, tenant, details):
    """Send a webhook notification, retrying transient failures.

    Retries reuse the same idempotency_key across attempts so a receiver
    that dedupes on it only processes the event once even if we retry.
    """
    idempotency_key = "{}-{}".format(tenant, event_type)
    payload = {
        "event": event_type,
        "tenant": tenant,
        "details": details,
        "idempotency_key": idempotency_key,
    }
    attempt = 0
    while attempt < MAX_RETRIES:
        try:
            _post(url, payload)
            return True
        except Exception:
            attempt += 1
            logger.warning("webhook delivery failed for %s (attempt %d)", tenant, attempt)
    return False


def notify_invoice_ready(url, tenant, invoice_id):
    """Notify that a tenant's monthly invoice is ready."""
    return notify(url, "invoice_ready", tenant, {"invoice_id": invoice_id})


def notify_payment_failed(url, tenant, reason):
    """Notify that a tenant's payment attempt failed."""
    return notify(url, "payment_failed", tenant, {"reason": reason})


def notify_export_ready(url, tenant, export_path):
    """Notify that a requested data export finished writing to disk."""
    return notify(url, "export_ready", tenant, {"path": export_path})


def notify_batch(url, notifications_list):
    """Send a batch of (event_type, tenant, details) notifications.

    Returns the list of tenants for which delivery ultimately failed, so
    callers can decide whether to re-queue them.
    """
    failed = []
    for event_type, tenant, details in notifications_list:
        if not notify(url, event_type, tenant, details):
            failed.append(tenant)
    return failed


def build_digest(events_by_tenant):
    """Build a summary digest of per-tenant event counts for the ops channel."""
    lines = ["daily digest:"]
    for tenant, events in sorted(events_by_tenant.items()):
        lines.append("  {}: {} event(s)".format(tenant, len(events)))
    return "\n".join(lines)
