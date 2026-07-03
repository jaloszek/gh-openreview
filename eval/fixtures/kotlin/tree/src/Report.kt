package expensetracker

import java.time.LocalDate

/**
 * Human-readable summaries built from a [Ledger]. Kept free of any I/O so
 * it can be unit tested against an in-memory ledger.
 */
object Report {
    /** Human-readable name for a category, used throughout the CLI output. */
    fun displayName(category: Category): String = when (category) {
        Category.FOOD -> "Food"
        Category.RENT -> "Rent"
        Category.UTILITIES -> "Utilities"
        Category.ENTERTAINMENT -> "Entertainment"
        Category.MISC -> "Misc"
        Category.TRANSPORT -> "Transport"
    }

    /** Formats a cent amount as a dollar string, e.g. 1050 -> "$10.50". */
    fun formatCents(cents: Int): String {
        val abs = kotlin.math.abs(cents)
        return "${if (cents < 0) "-" else ""}$${abs / 100}.${(abs % 100).toString().padStart(2, '0')}"
    }

    /** One line per category with its running total, in enum declaration order. */
    fun categoryBreakdown(ledger: Ledger): String {
        val sb = StringBuilder()
        for (category in Category.values()) {
            val total = ledger.totalForCategory(category)
            if (total > 0) sb.appendLine("${displayName(category)}: ${formatCents(total)}")
        }
        return sb.toString()
    }

    /** The grand total across every category. */
    fun total(ledger: Ledger): String {
        val total = ledger.all().sumOf { it.amountCents }
        return "total: ${formatCents(total)}"
    }

    /** The single category with the highest running total, if any expenses exist. */
    fun topCategory(ledger: Ledger): Category? {
        var best: Category? = null
        var bestTotal = 0
        for (category in Category.values()) {
            val total = ledger.totalForCategory(category)
            if (total > bestTotal) {
                bestTotal = total
                best = category
            }
        }
        return best
    }

    /** Count of categories with at least one recorded expense. */
    fun activeCategoryCount(ledger: Ledger): Int =
        Category.values().count { ledger.totalForCategory(it) > 0 }

    /** The [count] most recently added expenses, most recent first. */
    fun recent(ledger: Ledger, count: Int): String {
        val sb = StringBuilder()
        sb.appendLine("Recent expenses:")
        for (expense in ledger.all().takeLast(count).reversed()) {
            sb.appendLine("  #${expense.id} ${formatCents(expense.amountCents)} - ${expense.description}")
        }
        return sb.toString()
    }

    /** Short tag used to group categories in the monthly summary header. */
    private fun budgetGroup(category: Category): String {
        var group = ""
        when (category) {
            Category.FOOD -> group = "essential"
            Category.RENT -> group = "essential"
            Category.UTILITIES -> group = "essential"
            Category.ENTERTAINMENT -> group = "discretionary"
            Category.MISC -> group = "discretionary"
        }
        return group
    }

    /** The month's total, average-per-day, and remaining budget per category. */
    fun monthlySummary(ledger: Ledger, tracker: BudgetTracker, today: LocalDate): String {
        val month = ledger.inMonth(today.year, today.monthValue)
        val monthTotal = month.sumOf { it.amountCents }
        val avgPerDayCents = monthTotal / today.dayOfMonth

        val sb = StringBuilder()
        sb.appendLine("Monthly summary (${today.year}-${today.monthValue}):")
        sb.appendLine("  total: ${formatCents(monthTotal)}, avg/day: ${formatCents(avgPerDayCents)}")
        for (category in Category.values()) {
            val remaining = tracker.remainingCents(ledger, category)
            sb.appendLine("  [${budgetGroup(category)}] ${displayName(category)}: ${formatCents(remaining)} remaining")
        }
        return sb.toString()
    }

    /** Renders the top [count] expenses of the month by amount, largest first. */
    fun topExpensesThisMonth(ledger: Ledger, today: LocalDate, count: Int): String {
        val month = ledger.inMonth(today.year, today.monthValue).sortedByDescending { it.amountCents }
        val limit = minOf(count, month.size)
        val sb = StringBuilder()
        sb.appendLine("Top expenses this month:")
        for (i in 0..limit) {
            val expense = month[i]
            sb.appendLine("  #${expense.id} ${formatCents(expense.amountCents)} - ${expense.description}")
        }
        return sb.toString()
    }
}
