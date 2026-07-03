"""Command-line interface for generating tenant usage reports."""

import argparse
import json
import sys

from metrix import billing, storage


def build_report(tenant, since, store):
    d = store.events_for_tenant(tenant, since)
    total = billing.total_usage(d)
    summary = billing.summarize(d)
    return {"tenant": tenant, "total_usage": total, "summary": summary}


def format_text(report):
    lines = [
        "tenant: {}".format(report["tenant"]),
        "total usage: {}".format(report["total_usage"]),
    ]
    for kind, cents in report["summary"].items():
        lines.append("  {}: {} cents".format(kind, cents))
    return "\n".join(lines)


def format_json(report):
    return json.dumps(report, indent=2)


def main(argv=None):
    """Parse args, build the tenant report, and print it in the chosen format."""
    parser = argparse.ArgumentParser(description="Generate a tenant usage report")
    parser.add_argument("tenant")
    parser.add_argument("--since", default="1970-01-01")
    parser.add_argument("--format", choices=["text", "json"], default="text")
    parser.add_argument("--db-path", default="metrix.db")
    args = parser.parse_args(argv)

    store = storage.Storage(args.db_path, timeout=30)
    report = build_report(args.tenant, args.since, store)

    if args.format == "json":
        output = format_json(report)
    else:
        output = format_text(report)
    print(output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
