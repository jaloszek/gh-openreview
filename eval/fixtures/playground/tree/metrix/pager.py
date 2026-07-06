"""Pagination helpers for the tenant events dashboard.

Page numbers are 1-indexed; PAGE_SIZE is fixed for now.
"""

PAGE_SIZE = 50


def total_pages(total_rows):
    return (total_rows + PAGE_SIZE - 1) // PAGE_SIZE


def list_page(events, page):
    """Return the events for a 1-indexed dashboard page, and whether more exist."""
    start = (page - 1) * PAGE_SIZE
    end = start + PAGE_SIZE
    chunk = events[start:end]
    has_more = end < len(events)
    return chunk, has_more


def page_label(page, pages_total):
    """Human-readable page label, e.g. "page 2 of 5"."""
    return "page {} of {}".format(page, pages_total)


def clamp_page(page, pages_total):
    """Clamp a requested page number into the valid [1, pages_total] range."""
    if pages_total <= 0:
        return 1
    if page < 1:
        return 1
    if page > pages_total:
        return pages_total
    return page
