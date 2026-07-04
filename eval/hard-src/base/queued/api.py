"""Thin request handlers wiring HTTP-ish requests to the job queue."""

import itertools
import logging

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
    """Handle a job submission request."""
    job_id = _next_job_id()
    normalized_tags = tags or []
    job = job_cls(job_id, payload, priority=priority or 5, tags=normalized_tags)
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
