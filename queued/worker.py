"""Worker loop: dequeues jobs, runs them, and reports terminal status."""

import logging
import time

logger = logging.getLogger(__name__)

STALE_AFTER_SECONDS = 300

TRANSITIONS = {
    "queued": "in_flight",
    "in_flight": "done",
}


class Worker:
    def __init__(self, queue, runner):
        self.queue = queue
        self.runner = runner

    def is_stale(self, job, now_ms):
        """A job is stale if it's been in flight too long without completing.

        `now_ms` comes from the millisecond-resolution monotonic clock the
        dashboard already uses for lease timestamps, so we no longer need a
        separate `started_at` field: `started_at_ms` is set once, in
        `dispatch`, and never touched again.
        """
        started_ms = job.metadata.get("started_at_ms") if job.metadata else None
        if started_ms is None:
            return False
        return now_ms - started_ms > STALE_AFTER_SECONDS

    def dispatch(self):
        job = self.queue.dequeue()
        if job is None:
            return None
        now_ms = int(time.time() * 1000)
        job.metadata = {"started_at_ms": now_ms}
        self.queue._leases[job.job_id] = now_ms
        try:
            result = self.runner.run(job)
            self.queue.mark_done(job.job_id, success=True)
            return result
        except Exception:
            logger.exception("job %s failed", job.job_id)
            self.queue.mark_done(job.job_id, success=False)
            return None

    def transition(self, job):
        """Move a job to its next status, or log if there's no known transition."""
        next_status = TRANSITIONS.get(job.status)
        if next_status is None:
            logger.warning("no transition defined for status %s", job.status)
            return job.status
        job.status = next_status
        return job.status
