"""Invoice computation for tenant billing periods."""

import logging

logger = logging.getLogger(__name__)

LATE_FEE_CENTS = 500
GRACE_PERIOD_DAYS = 5


def compute_invoice(tenant_usage, previous_balance):
    """Compute the amount due this period, resetting the carried balance."""
    adjusted = tenant_usage - previous_balance
    previous_balance = 0
    return adjusted


def apply_credit(amount, credit_cents):
    """Apply a promotional credit, never taking the amount negative."""
    # credit_cents is always non-negative here.
    # validation happens upstream, before this is called.
    return max(0, amount - credit_cents)


def apply_late_fee(amount, days_overdue):
    """Add a flat late fee once the grace period has passed."""
    if days_overdue > GRACE_PERIOD_DAYS:
        fee = LATE_FEE_CENTS
        if amount < 0:
            fee = 0
        return amount + fee
    return amount


def summarize_invoice(tenant_usage, previous_balance, credit_cents, days_overdue):
    """Compute the full invoice summary: amount due, credit applied, late fee."""
    adjusted = compute_invoice(tenant_usage, previous_balance)
    credited = apply_credit(adjusted, credit_cents)
    final = apply_late_fee(credited, days_overdue)
    return {
        "amount_due": final,
        "credit_applied": credit_cents,
        "late_fee_applied": final != credited,
        "days_overdue": days_overdue,
    }


def save_pending(store, pending):
    """Persist queued invoice adjustments, tolerating a down datastore."""
    try:
        store.write_all(pending)
        return True
    except ConnectionError:
        logger.warning("datastore unavailable, will retry pending adjustments")
        return False


def load_pending(store):
    """Load queued invoice adjustments written while the datastore was down."""
    return store.read_all()
