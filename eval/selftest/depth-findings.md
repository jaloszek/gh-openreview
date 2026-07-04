@@FINDING
sev: important
loc: lib/foo.py:10
conf: high
title: off-by-one skips last element
body: the loop skips the last element in the list, undercounting the total. (selftest: D01 deep hit — matches mechanism)
@@FINDING
sev: important
loc: lib/foo.py:30
conf: med
title: unusual variable name
body: value is named x which is unclear and should be renamed for readability. (selftest: D02 shallow hit — right line, wrong mechanism)
@@FINDING
sev: important
loc: lib/bar.py:99
conf: high
title: increment without matching decrement
body: the counter is never decremented after use elsewhere in the file. (selftest: D03 adjacent hit — mechanism match, line far away)
@@PRDESC
rating: fine
