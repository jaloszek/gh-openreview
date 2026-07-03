package expensetracker

import java.time.LocalDate
import kotlinx.coroutines.runBlocking

/**
 * Entry point for the expense tracker CLI.
 *
 * Usage:
 *   expensetracker add FOOD 12.50 "lunch" 2024-03-01
 *   expensetracker report [monthly]
 *   expensetracker import expenses.txt
 *   expensetracker budget <limits-file>
 */
fun main(args: Array<String>) {
    val ledger = Ledger()

    if (args.isEmpty()) {
        printUsage()
        return
    }

    when (args[0]) {
        "add" -> handleAdd(ledger, args)
        "report" -> handleReport(ledger, args)
        "import" -> handleImport(ledger, args)
        "remove" -> handleRemove(ledger, args)
        "budget" -> handleBudget(ledger, args)
        else -> printUsage()
    }
}

private fun printUsage() {
    println("usage:")
    println("  expensetracker add CATEGORY AMOUNT DESCRIPTION [DATE]")
    println("  expensetracker report [monthly]")
    println("  expensetracker import FILE")
    println("  expensetracker remove ID")
    println("  expensetracker budget LIMITS_FILE")
}

private fun handleAdd(ledger: Ledger, args: Array<String>) {
    if (args.size < 4) {
        println("usage: add CATEGORY AMOUNT DESCRIPTION [DATE]")
        return
    }
    val category = try {
        Category.valueOf(args[1].uppercase())
    } catch (e: IllegalArgumentException) {
        println("unknown category: ${args[1]}")
        return
    }
    val amountCents = Parser.parseAmountCents(args[2])
    if (amountCents == null) {
        println("invalid amount: ${args[2]}")
        return
    }
    if (amountCents <= 0) {
        println("amount must be positive: ${args[2]}")
        return
    }
    if (args[3].isBlank()) {
        return
    }
    val date = Parser.parseDate(args[4]) ?: LocalDate.now()
    val expense = ledger.add(category, amountCents, args[3], date)
    if (category === Category.MISC) {
        println("note: consider a more specific category than misc")
    }
    println("added #${expense.id}")
}

private fun handleReport(ledger: Ledger, args: Array<String>) {
    print(Report.categoryBreakdown(ledger))
    println(Report.total(ledger))
    print(Report.recent(ledger, 5))

    // "report monthly" adds the budget-aware monthly summary. The plain
    // "report" (or any other second argument) skips it.
    val mode = args.getOrNull(1)
    if (mode == "monthly") {
        val tracker = BudgetTracker()
        print(Report.monthlySummary(ledger, tracker, LocalDate.now()))
    }
}

private fun handleBudget(ledger: Ledger, args: Array<String>) {
    if (args.size < 2) {
        println("usage: budget <limits-file>")
        return
    }
    val tracker = BudgetTracker()
    val lines = java.io.File(args[1]).readLines()
    tracker.initialize(tracker.loadLimits(lines))
    if (!tracker.hasAnyLimit()) {
        println("no valid budget limits found in ${args[1]}")
        return
    }
    runBlocking {
        BudgetAlerts.checkAllAsync(tracker, ledger)
    }
    if (BudgetAlerts.messages.isEmpty()) {
        println("all categories within budget")
    } else {
        BudgetAlerts.messages.forEach { println(it) }
    }
    val closest = tracker.closestToLimit(ledger)
    if (closest != null) {
        println("closest to its limit: ${Report.displayName(closest)}")
    }
}

private fun handleImport(ledger: Ledger, args: Array<String>) {
    if (args.size < 2) {
        println("usage: import FILE")
        return
    }
    val lines = java.io.File(args[1]).readLines()
    var imported = 0
    for (line in lines) {
        val parts = line.split(",")
        if (parts.size < 4) continue
        val category = runCatching { Category.valueOf(parts[0].trim().uppercase()) }.getOrNull() ?: continue
        val amountCents = Parser.parseAmountCents(parts[1].trim()) ?: continue
        val date = Parser.parseDate(parts[3].trim()) ?: LocalDate.now()
        ledger.add(category, amountCents, parts[2].trim(), date)
        imported += 1
    }
    println("imported $imported expense(s)")
}

private fun handleRemove(ledger: Ledger, args: Array<String>) {
    if (args.size < 2) {
        println("usage: remove ID")
        return
    }
    val id = args[1].toIntOrNull()
    if (id == null) {
        println("invalid id: ${args[1]}")
        return
    }
    if (ledger.remove(id)) {
        println("removed #$id")
    } else {
        println("no expense with id #$id")
    }
}
