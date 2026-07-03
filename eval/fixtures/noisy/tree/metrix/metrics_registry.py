"""In-process registry of counters/gauges reported to the internal metrics
sink alongside billing summaries.
"""

import logging

logger = logging.getLogger(__name__)


class MetricsRegistry:
    """Tracks named counters and gauges, tagged by a unit for display."""

    def __init__(self):
        self._counters = {}
        self._gauges = {}

    def increment(self, name, amount=1, unit="count"):
        """Increment a named counter by amount."""
        key = name
        self._counters[key] = self._counters.get(key, 0) + amount

    def set_gauge(self, name, value, unit="count"):
        """Set a named gauge to value."""
        key = name
        self._gauges[key] = value

    def snapshot(self):
        """Return a flat dict of every counter and gauge, for the /metrics endpoint."""
        out = {}
        out.update(self._counters)
        out.update(self._gauges)
        return out

    def reset(self):
        """Zero every counter and clear every gauge (used between test runs)."""
        self._counters.clear()
        self._gauges.clear()
