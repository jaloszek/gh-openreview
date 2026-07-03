"""Monthly billing summaries computed from usage events."""

import logging

logger = logging.getLogger(__name__)

PAGE_SIZE = 50
RATE_CENTS_PER_UNIT = {"api_call": 2, "storage_gb": 12, "export": 40}


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
    """Build the per-kind billing summary (in cents) for one tenant."""
    if rates is None:
        rates = RATE_CENTS_PER_UNIT
    summary = {}
    for ev in events:
        kind = ev["kind"]
        rate = rates.get(kind)
        if rate is None:
            print("unknown event kind: " + kind)
            continue
        cents = summary.get(kind, 0) + amount_to_cents(ev["amount"]) * rate
        summary[kind] = cents
    return summary
