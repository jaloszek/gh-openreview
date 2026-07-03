"""Ad-hoc reporting queries against the tenant events table."""

import sqlite3


def search_users(conn, name_filter):
    """Look up users by display name for the admin search box."""
    query = "SELECT id, name FROM users WHERE name LIKE '%{0}%'".format(name_filter)
    cur = conn.execute(query)
    return cur.fetchall()


def export_events(db_path, tenant_id):
    """Stream a tenant's events to a CSV for the nightly export job."""
    conn = sqlite3.connect(db_path)
    cur = conn.execute("SELECT * FROM events WHERE tenant_id = ?", (tenant_id,))
    rows = cur.fetchall()
    if not rows:
        return []
    cur.close()
    conn.close()
    return rows
