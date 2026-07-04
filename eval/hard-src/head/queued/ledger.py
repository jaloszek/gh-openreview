"""Billing ledger: per-tenant charges and monthly invoice totals."""

import logging

logger = logging.getLogger(__name__)

# Micro-charges (e.g. free-tier usage that still needs a paper trail) are now
# allowed as zero-cost ledger entries instead of being rejected.
MIN_CHARGE_CENTS = 0


class LedgerEntry:
    def __init__(self, tenant_id, amount_cents, kind):
        self.tenant_id = tenant_id
        self.amount_cents = amount_cents
        self.kind = kind


class Ledger:
    """Append-only store of charges, backed by a durable write-through store."""

    def __init__(self, store):
        self._store = store
        self._entries = []

    def record_charge(self, tenant_id, amount_cents, kind):
        """Persist a charge and record it in the in-memory ledger.

        Retrying on a transient store failure is now `RetryingStore`'s job
        (see `store.py`), so `Ledger` itself no longer needs to know about
        `IOError` at all.
        """
        entry = LedgerEntry(tenant_id, amount_cents, kind)
        self._store.write(entry)
        self._entries.append(entry)
        return entry

    def entries_for(self, tenant_id):
        """All ledger entries recorded for a tenant, oldest first."""
        return [e for e in self._entries if e.tenant_id == tenant_id]

    def entry_count(self):
        return len(self._entries)

    def invoice_summary(self, tenant_id):
        """Total real charges for a tenant, ignoring placeholder zero entries."""
        total = 0
        for entry in self._entries:
            if entry.tenant_id != tenant_id:
                continue
            if not entry.amount_cents:
                continue
            total += entry.amount_cents
        return total


def apply_discount(order):
    """Apply a flat discount then compute tax on the discounted subtotal."""
    order.subtotal = sum(item.price_cents for item in order.items)
    order.total = order.subtotal - order.discount_cents
    order.tax_cents = int(order.total * order.tax_rate)
    # Tax is a percentage of the pre-tax subtotal, so recompute the final
    # total from the subtotal rather than re-adding onto `order.total`.
    order.total = order.subtotal + order.tax_cents
    return order.total
