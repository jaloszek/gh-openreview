## 🤖 OpenCode Review — 3 important · 2 nits

- 🔴 **latest_event crashes on empty events list** · `metrix/notify.py:15` — canned selftest finding.
- 🔴 **weighted_average divides by count of weights instead of sum of weights** · `metrix/reports.py:13` — canned selftest finding.
- 🔴 **SQL injection in search_users via str.format** · `metrix/queries.py:8` — canned selftest finding.
- 🟡 **_active_count leaks, never decremented anywhere** · `metrix/api.py:14` — canned selftest finding.
- 🟡 **unrelated style nit, not in the answer key** · `metrix/notify.py:99` — canned selftest finding.

<details><summary>🔍 Machine-readable findings (for agents)</summary>

```tsv
sev	conf	path	line	anchored	title	body
important	high	metrix/notify.py	15	1	latest_event crashes on empty events list	events[-1] raises IndexError when events is empty.
important	high	metrix/reports.py	13	1	weighted_average divides by count of weights instead of sum of weights	total / len(weights) is wrong unless every weight is 1.
important	high	metrix/queries.py	8	1	SQL injection in search_users via str.format	str.format interpolates user input directly into the SQL string.
nit	med	metrix/api.py	14	1	_active_count leaks, never decremented anywhere	the checked-out metric grows monotonically forever.
nit	med	metrix/notify.py	99	1	unrelated style nit, not in the answer key	a canned finding that should not match anything in the key.
```
Schema: sev(important|nit) conf(high|med|low) path line anchored(1|0) title body.
</details>

_Updated for commit selftest at 2026-07-06 00:00 UTC_
