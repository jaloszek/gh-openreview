## 🤖 OpenCode Review

Findings below (canned, for eval/compare.sh --selftest — TASK-46 mechanism scoring).

```tsv
sev	conf	path	line	anchored	title	body
important	high	pkg/worker.py	40	1	Lease never removed	dispatch adds leases but mark_done never removes them from the lease dict
important	high	pkg/deep.py	14	1	Wrong denominator	average uses done count vs all jobs as the denominator mismatch
important	high	pkg/deep2.py	32	1	Units mismatch	comparison looks fine, nothing unusual here
nit	low	pkg/unrelated.py	5	1	Nit	something trivial
```
