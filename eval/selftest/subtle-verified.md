@@FINDING
sev: important
loc: metrix/invoice.py:18
conf: high
title: previous_balance reset before it is used
body: compute_invoice resets previous_balance to 0 before subtracting it, so the carried balance is never actually applied. (selftest: exact match on S01)
@@FINDING
sev: important
loc: metrix/pager.py:15
conf: med
title: off-by-one in _has_more
body: end <= total reports a phantom next page when the chunk exactly fills the last page; should be end < total. (selftest: exact match on S02)
@@PRDESC
rating: good
