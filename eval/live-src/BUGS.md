# Live playground — answer key

`base/` -> `head/` seeds exactly **8** bugs across the taxonomy, deliberately
different from the frozen offline fixtures (`eval/fixtures/playground/`,
answer key `eval/golden/playground.tsv`) so a match against one cannot be
mistaken for the other.

Diffstat (`base/` vs `head/`):

```
metrix/api.py        | 14 ++++++++++++++
metrix/notify.py     |  7 ++++++-
metrix/queries.py     | 22 ++++++++++++++++++++++ (new file)
metrix/reports.py    | 11 +++++++++++
4 files changed, 53 insertions(+), 1 deletion(-)
```

| id  | file                  | line | category        | sev       | description |
|-----|-----------------------|------|-----------------|-----------|--------------|
| L01 | metrix/notify.py      | 15   | null-edge       | important | `latest_event`: `events[-1]` raises `IndexError` when `events` is empty |
| L02 | metrix/notify.py      | 21   | convention      | nit       | `send_digest` uses `print()` instead of the module `logger` |
| L03 | metrix/reports.py     | 13   | logic           | important | `weighted_average` divides by `len(weights)` instead of `sum(weights)` — wrong unless every weight is 1 |
| L04 | metrix/reports.py     | 18   | subtle          | important | `score_delta_percent` truncates with `int(...)` instead of rounding, e.g. 33.9% reports as 33% |
| L05 | metrix/api.py         | 24   | race            | important | `mark_in_use` mutates `self._active_count` and `self._in_use` without holding `self._lock`, unlike `acquire`/`release` |
| L06 | metrix/api.py         | 31   | error-handling  | important | `try_send` has a bare `except Exception: pass`, silently swallowing transport failures |
| L07 | metrix/queries.py     | 8    | security        | important | `search_users` builds SQL via `str.format` interpolation — SQL injection |
| L08 | metrix/queries.py     | 19   | resource-leak   | important | `export_events` returns early on empty `rows`, skipping `cur.close()`/`conn.close()` and leaking the sqlite connection |

Verification commands (run from `eval/live-src/`):

```bash
diff -ruN base head --exclude='__pycache__'   # only api.py, notify.py, reports.py, queries.py differ
grep -n 'events\[-1\]' head/metrix/notify.py                     # L01
grep -n 'print("digest sent to"' head/metrix/notify.py           # L02
grep -n 'return total / len(weights)' head/metrix/reports.py     # L03
grep -n 'int((current - previous)' head/metrix/reports.py        # L04
grep -n '_active_count += 1' head/metrix/api.py                  # L05
grep -n 'except Exception:' head/metrix/api.py                   # L06
grep -n 'LIKE' head/metrix/queries.py                             # L07
grep -n 'return \[\]' head/metrix/queries.py                      # L08
```
