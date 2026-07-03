@@FINDING
sev: important
loc: metrix/billing.py:14
conf: high
title: off-by-one in total_usage
body: range(len(events) - 1) skips the last event; iterate over events directly. (selftest: exact match on B01)
@@FINDING
sev: important
loc: metrix/auth.py:24
conf: med
title: bearer parsing crashes on malformed header
body: auth.split(" ")[1] raises IndexError when the header has no space. (selftest: -1 off B03, within tolerance)
@@FINDING
sev: important
loc: metrix/worker.py:41
conf: med
title: resp used after swallowed URLError
body: on URLError the handler logs and falls through to resp.read(). (selftest: +4 off B06, within tolerance)
@@FINDING
sev: important
loc: metrix/storage.py:44
conf: high
title: SQL injection in events_for_tenant
body: tenant and since are interpolated into the SQL string; use ? placeholders. (selftest: exact B09, also within 5 of B07)
@@FINDING
sev: nit
loc: metrix/billing.py:50
conf: low
title: prefer logger over print
body: use the module logger for unknown event kinds. (selftest: 6 off B11 — expected MISS)
@@FINDING
sev: nit
loc: metrix/config.py:10
conf: low
title: hardcoded billing URL
body: consider making BILLING_URL configurable. (selftest: wrong file — expected MISS)
@@PRDESC
rating: good
