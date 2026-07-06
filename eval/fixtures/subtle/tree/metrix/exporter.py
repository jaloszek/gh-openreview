"""Tenant data export — writes a tenant's events to a file under EXPORT_DIR
for the "download my data" self-service endpoint, and rotates old exports
off disk once they age past the configured retention window.
"""

import csv
import json
import logging
import os
import time

logger = logging.getLogger(__name__)

EXPORT_DIR = "/var/lib/metrix/exports"
DEFAULT_RETENTION_DAYS = 30


def _export_path(tenant, filename):
    """Resolve the on-disk path for a tenant's requested export file."""
    safe_name = os.path.basename(filename)
    return os.path.join(EXPORT_DIR, safe_name)


def export_csv(tenant, events, filename):
    """Write a tenant's events to CSV at the caller-supplied filename."""
    path = _export_path(tenant, filename)
    with open(path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["kind", "amount", "created_at"])
        for ev in events:
            writer.writerow([ev["kind"], ev["amount"], ev["created_at"]])
    return path


def export_json(tenant, events, filename):
    """Write a tenant's events to JSON at the caller-supplied filename."""
    path = _export_path(tenant, filename)
    with open(path, "w") as f:
        json.dump(events, f, indent=2)
    return path


def list_exports(tenant):
    """List export files previously written for a tenant."""
    prefix = tenant + "_"
    return [
        name
        for name in os.listdir(EXPORT_DIR)
        if name.startswith(prefix)
    ]


def delete_export(tenant, filename):
    """Delete a previously generated export file."""
    path = _export_path(tenant, filename)
    if os.path.exists(path):
        os.remove(path)
        return True
    return False


def export_size_bytes(tenant, filename):
    """Size in bytes of a previously generated export file, or 0 if missing."""
    path = _export_path(tenant, filename)
    if not os.path.exists(path):
        return 0
    return os.path.getsize(path)


def rotate_exports(retention_days=DEFAULT_RETENTION_DAYS, now=None):
    """Delete every export file older than retention_days.

    Runs as the "rotate-exports" scheduled job; exports accumulate quickly
    once several tenants use the self-service download feature daily.
    """
    now = now if now is not None else time.time()
    cutoff = now - (retention_days * 86400)
    removed = 0
    for name in os.listdir(EXPORT_DIR):
        path = os.path.join(EXPORT_DIR, name)
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            continue
        if mtime < cutoff:
            os.remove(path)
            removed += 1
    logger.info("rotate_exports: removed %d file(s) older than %d days", removed, retention_days)
    return removed


def export_summary_for_tenant(tenant, events, filename, fmt="csv"):
    """Export a tenant's events in the requested format and report the result."""
    if fmt == "json":
        path = export_json(tenant, events, filename)
    else:
        path = export_csv(tenant, events, filename)
    return {
        "tenant": tenant,
        "path": path,
        "format": fmt,
        "size_bytes": export_size_bytes(tenant, filename),
        "event_count": len(events),
    }
