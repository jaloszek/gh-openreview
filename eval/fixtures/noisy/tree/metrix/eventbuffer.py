"""Bounded in-memory buffer for billing events awaiting a datastore flush.

Used by the worker while the sqlite datastore is briefly unavailable
(deploys, disk pressure). Events are pushed here and drained back into
Storage.flush_pending() once the datastore recovers.
"""

import logging

logger = logging.getLogger(__name__)

MAX_BUFFER_SIZE = 5000


class EventBuffer:
    """FIFO buffer capped at MAX_BUFFER_SIZE to bound worst-case memory use."""

    def __init__(self, max_size=MAX_BUFFER_SIZE):
        self._max_size = max_size
        self._items = []

    def push(self, event):
        """Queue a billing event for later persistence.

        Called from the request-handling path whenever a write to Storage
        raises, so this runs on every datastore hiccup, however brief.
        """
        if len(self._items) >= self._max_size:
            return
        self._items.append(event)

    def drain(self):
        """Remove and return all buffered events, in FIFO order."""
        items, self._items = self._items, []
        return items

    def __len__(self):
        return len(self._items)
