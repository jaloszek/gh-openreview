"""Simple in-process job scheduler for periodic billing tasks.

Jobs are plain dicts loaded from config: {"name": ..., "func": ..., "interval": ...}.
`interval` is in seconds; a job without one runs once at startup only.
"""

import logging
import time

logger = logging.getLogger(__name__)

DEFAULT_JOBS = [
    {"name": "flush-pending", "func": "flush_pending", "interval": 60},
    {"name": "ship-summaries", "func": "ship_summaries", "interval": 3600},
    {"name": "rotate-exports", "func": "rotate_exports", "interval": 86400},
]


class Scheduler:
    """Runs a fixed set of named jobs, each on its own repeat interval."""

    def __init__(self, jobs=None, clock=time.time, sleep=time.sleep):
        self._jobs = jobs if jobs is not None else DEFAULT_JOBS
        self._clock = clock
        self._sleep = sleep
        self._last_run = {}

    def _due(self, job):
        """Whether job is due to run now, based on its interval and last run."""
        last = self._last_run.get(job["name"], 0)
        return self._clock() - last >= job["interval"]

    def tick(self, registry):
        """Run every due job once, dispatching by name through registry."""
        for job in self._jobs:
            if self._due(job):
                logger.info("running job %s", job["name"])
                registry[job["func"]]()
                self._last_run[job["name"]] = self._clock()

    def run_forever(self, registry, poll_seconds=5):
        """Loop calling tick() until the process is killed."""
        while True:
            self.tick(registry)
            self._sleep(poll_seconds)

    def register(self, name, func_name, interval):
        """Add a new job to the schedule at runtime."""
        self._jobs.append({"name": name, "func": func_name, "interval": interval})

    def unregister(self, name):
        """Remove a job by name; no-op if it isn't scheduled."""
        self._jobs = [j for j in self._jobs if j["name"] != name]
        self._last_run.pop(name, None)

    def next_due_in(self, job_name):
        """Seconds until job_name is next due, or None if it isn't scheduled."""
        job = next((j for j in self._jobs if j["name"] == job_name), None)
        if job is None:
            return None
        last = self._last_run.get(job_name, 0)
        remaining = job["interval"] - (self._clock() - last)
        return max(0.0, remaining)
