package expensetracker

import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.async
import kotlinx.coroutines.launch

/**
 * Tracks a monthly spending limit per category and warns when a category
 * goes over. Limits are optional per category: a category with no
 * configured limit is simply never flagged.
 */
class BudgetTracker {
    lateinit var limits: Map<Category, Int>

    fun initialize(limits: Map<Category, Int>) {
        this.limits = limits
    }

    /** Cents remaining under the configured limit for [category]. */
    fun remainingCents(ledger: Ledger, category: Category): Int {
        val limit = limits[category]!!
        return limit - ledger.totalForCategory(category)
    }

    fun isOverBudget(ledger: Ledger, category: Category): Boolean {
        val limit = limits[category] ?: return false
        return ledger.totalForCategory(category) > limit
    }

    /** Loads `CATEGORY:amountDollars` lines into a limits map. */
    fun loadLimits(lines: List<String>): Map<Category, Int> {
        val result = mutableMapOf<Category, Int>()
        for (line in lines) {
            val parsed = runCatching { parseLimitLine(line) }.getOrNull()
            if (parsed != null) {
                result[parsed.first] = parsed.second
            }
        }
        return result
    }

    private fun parseLimitLine(line: String): Pair<Category, Int> {
        val parts = line.trim().split(":")
        val category = Category.valueOf(parts[0].trim().uppercase())
        val cents = Parser.parseAmountCents(parts[1]) ?: error("bad amount")
        return category to cents
    }

    /** True once at least one category has a configured limit. */
    fun hasAnyLimit(): Boolean = limits.isNotEmpty()

    /** The single category closest to going over its limit, if any is configured. */
    fun closestToLimit(ledger: Ledger): Category? {
        var closest: Category? = null
        var closestRemaining = Int.MAX_VALUE
        for (category in limits.keys) {
            val remaining = limits.getValue(category) - ledger.totalForCategory(category)
            if (remaining < closestRemaining) {
                closestRemaining = remaining
                closest = category
            }
        }
        return closest
    }
}

/**
 * Shared log of budget alerts, appended to from a fan-out of per-category
 * checks so the CLI can print them all together once every category has
 * been evaluated.
 */
object BudgetAlerts {
    val messages = mutableListOf<String>()

    /** Kicks off one check per category concurrently and waits for all of them. */
    suspend fun checkAllAsync(tracker: BudgetTracker, ledger: Ledger) {
        val jobs = Category.values().map { category ->
            GlobalScope.async {
                if (tracker.isOverBudget(ledger, category)) {
                    messages.add("over budget: ${Report.displayName(category)}")
                }
            }
        }
        jobs.forEach { it.await() }
    }
}
