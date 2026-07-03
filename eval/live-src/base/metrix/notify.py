"""Outbound notification helpers."""

import logging

logger = logging.getLogger(__name__)


def format_digest(events):
    lines = ["{0}: {1}".format(e["kind"], e["count"]) for e in events]
    return "\n".join(lines)


def send_digest(client, recipient, events):
    body = format_digest(events)
    client.send(recipient, body)
    logger.info("digest sent to %s", recipient)
