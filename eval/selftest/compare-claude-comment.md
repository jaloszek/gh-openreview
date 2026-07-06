## 🔍 Code Review

**PR #canned — selftest fixture for compare.sh's 6-column schema**

<!-- claude-review -->

### Critical

**1. `metrix/notify.py:15` — latest_event crashes on empty events list**
Canned selftest finding.

**2. `metrix/api.py:24` — mark_in_use mutates shared state without holding the lock**
Canned selftest finding.

**3. `metrix/reports.py:18` — score_delta_percent truncates instead of rounding, and has no zero-guard**
Canned selftest finding covering both the seeded truncation bug and the
unseeded ZeroDivisionError on the same line.

### Nit

**4. `metrix/notify.py:21` — send_digest uses print() instead of the module logger**
Canned selftest finding.

```tsv
sev	conf	path	line	title	body
important	high	metrix/notify.py	15	latest_event crashes on empty events list	events[-1] raises IndexError when events is empty.
important	high	metrix/api.py	24	mark_in_use mutates shared state without holding the lock	_active_count and _in_use are mutated without self._lock.
important	high	metrix/reports.py	18	score_delta_percent truncates instead of rounding, and has no zero-guard	int(...) truncates and previous == 0 raises ZeroDivisionError.
nit	low	metrix/notify.py	21	send_digest uses print() instead of the module logger	print() loses structured logging context.
```
