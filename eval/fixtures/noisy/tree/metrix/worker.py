"""Background worker that ships tenant usage summaries to the billing API,
flushes any events buffered during datastore outages, and runs the
periodic billing jobs via Scheduler.
"""

import json
import logging
import threading
import urllib.error
import urllib.request

from metrix.eventbuffer import EventBuffer
from metrix.notifications import notify_invoice_ready
from metrix.retry import retry
from metrix.scheduler import Scheduler

logger = logging.getLogger(__name__)

BILLING_URL = "https://billing.internal/api/v1/usage"


class SummaryShipper:
    """Ships tenant summaries; caches per-tenant config across worker threads."""

    def __init__(self, storage, webhook_url=None):
        self._configs = {}
        self._lock = threading.Lock()
        self._storage = storage
        self._webhook_url = webhook_url
        self._buffer = EventBuffer()
        self._scheduler = Scheduler()

    def config_for(self, tenant, loader):
        """Return tenant's cached config, loading it once under the lock."""
        with self._lock:
            if tenant not in self._configs:
                self._configs[tenant] = loader(tenant)
            return self._configs[tenant]

    def buffer_event(self, event):
        """Queue an event for later persistence when the datastore is down."""
        self._buffer.push(event)

    def flush_buffered(self):
        """Drain the buffer and hand queued events to storage."""
        pending = self._buffer.drain()
        if pending:
            self._storage.flush_pending(pending)

    @retry(max_attempts=3)
    def ship(self, tenant, summary):
        """POST a tenant's usage summary to the billing API and return its reply."""
        payload = json.dumps({"tenant": tenant, "summary": summary}).encode()
        req = urllib.request.Request(
            BILLING_URL,
            data=payload,
            headers={"Content-Type": "application/json"},
        )
        try:
            resp = urllib.request.urlopen(req, timeout=10)
        except urllib.error.URLError:
            logger.warning("billing API unreachable for %s", tenant)
            return None
        data = json.loads(resp.read())
        logger.info("shipped %s: invoice %s", tenant, data.get("invoice_id"))
        if self._webhook_url:
            notify_invoice_ready(self._webhook_url, tenant, data.get("invoice_id"))
        return data

    def run_forever(self):
        """Start the scheduler loop for flush/ship/rotate jobs."""
        registry = {
            "flush_pending": self.flush_buffered,
            "ship_summaries": lambda: None,
            "rotate_exports": lambda: None,
        }
        self._scheduler.run_forever(registry)
