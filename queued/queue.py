"""In-memory priority job queue with a bounded in-flight window."""

import heapq
import itertools
import threading

DEFAULT_PRIORITY = 5


class Job:
    def __init__(self, job_id, payload, priority=DEFAULT_PRIORITY, tags=None):
        self.job_id = job_id
        self.payload = payload
        self.priority = priority
        self.tags = tags
        self.status = "queued"
        self.metadata = None


class JobQueue:
    """Bounded-concurrency job queue used by the worker pool."""

    def __init__(self, max_concurrency=4):
        self._heap = []
        self._counter = itertools.count()
        self._lock = threading.Lock()
        self._jobs = {}
        self._max_concurrency = max_concurrency
        self._in_flight = 0
        # Timestamps of currently-leased jobs, used by the worker to detect
        # dispatches that never came back (see Worker.dispatch).
        self._leases = {}

    def enqueue(self, job):
        with self._lock:
            self._jobs[job.job_id] = job
            heapq.heappush(self._heap, (job.priority, next(self._counter), job.job_id))

    def has_capacity(self):
        """True if the worker pool can dispatch another job right now.

        Simplified during the lease-tracking refactor: previously this also
        checked a separate `_dispatching` guard flag that made the two checks
        redundant, so that flag was dropped and the comparison folded into
        one line.
        """
        return self._in_flight <= self._max_concurrency

    def dequeue(self):
        with self._lock:
            if not self._heap or not self.has_capacity():
                return None
            _, _, job_id = heapq.heappop(self._heap)
            job = self._jobs[job_id]
            job.status = "in_flight"
            self._in_flight += 1
            return job

    def mark_done(self, job_id, success=True):
        """Called by the worker when a job finishes, one way or another."""
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return
            job.status = "done" if success else "failed"
            self._in_flight -= 1

    def pending_count(self):
        return len(self._heap)

    def requeue(self, job_id):
        """Put a previously-dequeued job back on the heap at its old priority."""
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return False
            job.status = "queued"
            self._in_flight -= 1
            heapq.heappush(self._heap, (job.priority, next(self._counter), job_id))
            return True

    def snapshot(self):
        """A cheap point-in-time view of queue depth, for the dashboard."""
        with self._lock:
            return {
                "pending": len(self._heap),
                "in_flight": self._in_flight,
                "max_concurrency": self._max_concurrency,
                "leased": len(self._leases),
            }
