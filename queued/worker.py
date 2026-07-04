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

    def is_stale(self, job, now_seconds):
        """A job is stale if it's been in flight too long without completing."""
        started = job.metadata.get("started_at") if job.metadata else None
        if started is None:
            return False
        return now_seconds - started > STALE_AFTER_SECONDS

    def dispatch(self):
        job = self.queue.dequeue()
        if job is None:
            return None
        job.metadata = {"started_at": time.time()}
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
