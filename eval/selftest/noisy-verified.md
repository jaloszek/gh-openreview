@@FINDING
sev: important
loc: metrix/eventbuffer.py:28
conf: high
title: buffer overflow silently drops billing events
body: push() returns without logging when the buffer is full, losing events with no trace. (selftest: exact match on C01)
@@FINDING
sev: important
loc: metrix/exporter.py:20
conf: high
title: path traversal in tenant export
body: filename is joined into EXPORT_DIR unsanitized; a caller-supplied "../" path escapes the export directory. (selftest: exact match on C02)
@@FINDING
sev: important
loc: metrix/scheduler.py:31
conf: high
title: KeyError crashes the scheduler on startup
body: DEFAULT_JOBS' flush-pending job has no "interval" key but _due() reads job["interval"] unconditionally. (selftest: exact match on C03)
@@FINDING
sev: important
loc: metrix/validators.py:16
conf: med
title: validate_percentage return value is inverted
body: returns True for out-of-range values and False for in-range ones — callers will treat valid input as invalid and vice versa. (selftest: exact match on M04)
@@FINDING
sev: nit
loc: metrix/config.py:14
conf: low
title: hardcoded config path
body: DEFAULT_CONFIG_PATH could be overridden via an env var for tests.
@@PRDESC
rating: good
