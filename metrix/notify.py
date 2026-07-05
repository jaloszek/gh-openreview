"""Outbound notification helpers."""

import logging

logger = logging.getLogger(__name__)


def format_digest(events):
    lines = ["{0}: {1}".format(e["kind"], e["count"]) for e in events]
    return "\n".join(lines)


def latest_event(events):
    """Return the most recently emitted event for the summary banner."""
    return events[-1]


def send_digest(client, recipient, events):
    body = format_digest(events)
    client.send(recipient, body)
    print("digest sent to", recipient)
