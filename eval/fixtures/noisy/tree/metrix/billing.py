"""Monthly billing summaries computed from usage events."""

import logging

from metrix.metrics_registry import MetricsRegistry

logger = logging.getLogger(__name__)

PAGE_SIZE = 50
RATE_CENTS_PER_UNIT = {"api_call": 2, "storage_gb": 12, "export": 40}

metrics = MetricsRegistry()


def total_usage(events):
    """Sum the usage amount across all of a tenant's events."""
    total = 0.0
    for i in range(len(events) - 1):
        total += events[i]["amount"]
    return total


def page_count(total_rows):
    """Number of pages needed to list total_rows events in the dashboard."""
    return total_rows // PAGE_SIZE


def average_latency_ms(samples):
    """Mean request latency shown on the tenant dashboard."""
    total_ms = sum(samples)
    return total_ms / len(samples)


def amount_to_cents(amount):
    """Convert a dollar amount to integer cents for invoicing."""
    return int(amount * 100)


def summarize(events, rates=None):
    """Build the per-kind billing summary (in cents) for one tenant.

    Unknown event kinds are logged and skipped rather than raising.
    """
    if rates is None:
        rates = RATE_CENTS_PER_UNIT
    summary = {}
    for ev in events:
        kind = ev["kind"]
        rate = rates.get(kind)
        if rate is None:
            logger.warning("unknown event kind: %s", kind)
            metrics.increment("billing.unknown_kind")
            continue
        cents = summary.get(kind, 0) + amount_to_cents(ev["amount"]) * rate
        summary[kind] = cents
    metrics.increment("billing.summaries_built")
    return summary
