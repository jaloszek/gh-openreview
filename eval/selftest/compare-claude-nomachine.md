## 🔍 Code Review

**PR #canned — selftest fixture for compare.sh's missing-TSV-block path**

<!-- claude-review -->

This canned comment predates the machine-readable TSV requirement: it has
prose findings but no fenced ```tsv block, exactly like the real Claude
comments on PR #19/#22 at the time TASK-40 was written. `compare.sh` must
detect the absence of the block and skip scoring this reviewer with a
warning, rather than crashing or silently reporting zero findings as a real
score.

### Critical

**1. `metrix/notify.py:15` — latest_event crashes on empty events list**
Canned prose-only finding, no machine-readable block anywhere in this file.
