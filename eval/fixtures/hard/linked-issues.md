### #42 Ad-hoc jobs, cancellation, and a duration widget

Three asks from the dashboard team, plus one from ops:

- Support submitting jobs without tags (automation scripts don't always have
  a meaningful tag to attach).
- Add a `cancel_job` endpoint so an operator can cancel a queued job.
- Add a duration widget to the "running jobs" panel.
- Ops wants zero-cost ledger entries allowed, for free-tier usage that still
  needs a paper trail for support purposes.

Also: the reaper (a separate upcoming PR) needs a lease timestamp per
in-flight job to detect dispatches that never came back. This PR just adds
the bookkeeping; the reaper itself is out of scope here.
