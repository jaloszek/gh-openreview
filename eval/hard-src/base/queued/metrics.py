"""Aggregation helpers used by the dashboard and the billing summary."""


def average_job_cost_cents(jobs):
    """Average cost, in cents, of jobs that actually completed."""
    done = [j for j in jobs if j.status == "done"]
    if not done:
        return 0
    total_cents = sum(j.metadata.get("cost_cents", 0) for j in done)
    return total_cents // len(done)


def status_counts(jobs):
    """How many jobs are in each status bucket, for the dashboard header."""
    counts = {}
    for job in jobs:
        counts[job.status] = counts.get(job.status, 0) + 1
    return counts


def failure_rate(jobs):
    """Fraction of terminal jobs (done or failed) that ended in failure."""
    terminal = [j for j in jobs if j.status in ("done", "failed")]
    if not terminal:
        return 0.0
    failed = sum(1 for j in terminal if j.status == "failed")
    return failed / len(terminal)


def primary_label(job):
    """The first tag is used as the job's primary label on the dashboard."""
    return job.tags[0]
