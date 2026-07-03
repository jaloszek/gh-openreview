"""Weekly usage report generation."""


def average_score(scores):
    if not scores:
        return 0.0
    return sum(scores) / len(scores)


def top_n(records, n):
    return sorted(records, key=lambda r: r["score"], reverse=True)[:n]
