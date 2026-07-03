"""Background worker that ships tenant usage summaries to the billing API."""

import json
import logging
import threading
import urllib.error
import urllib.request

logger = logging.getLogger(__name__)

BILLING_URL = "https://billing.internal/api/v1/usage"


class SummaryShipper:
    """Ships tenant summaries; caches per-tenant config across worker threads."""

    def __init__(self):
        self._configs = {}
        self._lock = threading.Lock()

    def config_for(self, tenant, loader):
        if tenant not in self._configs:
            self._configs[tenant] = loader(tenant)
        return self._configs[tenant]

    def ship(self, tenant, summary):
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
        data = json.loads(resp.read())
        logger.info("shipped %s: invoice %s", tenant, data.get("invoice_id"))
        return data
