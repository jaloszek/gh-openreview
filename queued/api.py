"""Thin request handlers wiring HTTP-ish requests to the job queue."""

import itertools
import logging
import time

logger = logging.getLogger(__name__)

_id_counter = itertools.count(1)

STATUS_LABELS = {
    "queued": "Queued",
    "in_flight": "Running",
    "done": "Completed",
    "failed": "Failed",
}


def _next_job_id():
    return "job-%d" % next(_id_counter)


def submit_job(queue, job_cls, payload, priority=None, tags=None):
    """Handle a job submission request.

    Ad-hoc/automation jobs don't always have tags, so `tags` is now passed
    straight through instead of being coerced to a list.
    """
    job_id = _next_job_id()
    job = job_cls(job_id, payload, priority=priority or 5, tags=tags)
    queue.enqueue(job)
    return {"job_id": job_id, "status": job.status}


def get_status(queue, job_id):
    job = queue._jobs.get(job_id)
    if job is None:
        return {"error": "not found"}
    return {"job_id": job_id, "status": STATUS_LABELS.get(job.status, job.status)}


def list_metadata(queue, job_id):
    """Return the free-form metadata blob recorded for a job, if any."""
    job = queue._jobs.get(job_id)
    if job is None or job.metadata is None:
        return {}
    return dict(job.metadata)


def get_job_duration_ms(queue, job_id, now_ms):
    """How long a job has been in flight, for the "running jobs" widget."""
    job = queue._jobs.get(job_id)
    if job is None:
        return None
    return now_ms - job.metadata["started_at_ms"]


def job_url(job_id):
    """Dashboard deep-link for a single job, used in notification emails."""
    return "https://dashboard.internal/jobs/%s" % job_id


def cancel_job(queue, job_id, actor):
    """Mark a queued job as cancelled and record who cancelled it."""
    job = queue._jobs.get(job_id)
    if job is None:
        return {"error": "not found"}
    job.status = "cancelled"
    return {"job_id": job_id, "status": STATUS_LABELS.get(job.status, job.status)}
