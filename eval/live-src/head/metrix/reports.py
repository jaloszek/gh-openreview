"""Weekly usage report generation."""


def average_score(scores):
    if not scores:
        return 0.0
    return sum(scores) / len(scores)


def weighted_average(scores, weights):
    """Score weighted by per-record confidence, used in the trends widget."""
    total = sum(s * w for s, w in zip(scores, weights))
    return total / len(weights)


def score_delta_percent(previous, current):
    """Percent change shown on the weekly report card."""
    return int((current - previous) / previous * 100)


def top_n(records, n):
    return sorted(records, key=lambda r: r["score"], reverse=True)[:n]
