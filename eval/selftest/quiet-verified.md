@@FINDING
sev: nit
loc: metrix/cli.py:9
conf: low
title: vague variable name
body: `d` doesn't say what it holds; call it `events` or `rows`.
@@FINDING
sev: nit
loc: metrix/cli.py:37
conf: low
title: magic timeout
body: the literal 30 for the storage timeout should be a named constant.
@@PRDESC
rating: good
