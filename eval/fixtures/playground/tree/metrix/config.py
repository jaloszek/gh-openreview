"""Loads and validates the metrix service config (billing rates, webhook
URLs, scheduler intervals) from a JSON file on disk.
"""

import json
import logging

from metrix.validators import validate_webhook_url

logger = logging.getLogger(__name__)

DEFAULT_CONFIG_PATH = "/etc/metrix/config.json"


class Config:
    """Thin wrapper around the parsed config dict with defaulted lookups."""

    def __init__(self, data):
        self._data = data

    @classmethod
    def load(cls, path=DEFAULT_CONFIG_PATH):
        """Read and parse the config file at path."""
        with open(path) as f:
            data = json.load(f)
        return cls(data)

    def rate_for(self, kind):
        """Billing rate in cents for a usage kind, falling back to 1 if unknown."""
        rates = self._data.get("rates", {})
        return rates.get(kind, 1)

    def webhook_url(self):
        """The configured webhook URL for billing notifications, or None."""
        d = self._data.get("webhook_url")
        if d and validate_webhook_url(d):
            return d
        return None

    def scheduler_poll_seconds(self):
        """How often the scheduler checks for due jobs."""
        return self._data.get("scheduler_poll_seconds", 5)

    def export_retention_days(self):
        """How many days generated exports are kept before rotation."""
        return self._data.get("export_retention_days", 30)

    def max_page_size(self):
        """Upper bound on the dashboard page size clients may request."""
        return self._data.get("max_page_size", 200)

    def notification_recipients(self):
        """Email addresses to CC on billing notification webhooks."""
        return self._data.get("notification_recipients", [])

    def validate(self):
        """Sanity-check required top-level keys; returns a list of problems (empty = OK)."""
        problems = []
        if "rates" not in self._data:
            problems.append("missing 'rates' section")
        if self.webhook_url() is None and self._data.get("webhook_url"):
            problems.append("webhook_url is set but not a valid https URL")
        if self.export_retention_days() <= 0:
            problems.append("export_retention_days must be positive")
        if self.max_page_size() <= 0:
            problems.append("max_page_size must be positive")
        return problems

    def as_dict(self):
        """Return a shallow copy of the underlying config data."""
        return dict(self._data)
