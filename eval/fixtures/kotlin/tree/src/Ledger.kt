package expensetracker

import java.time.LocalDate

/**
 * A single spending category. Ordering here defines default report
 * ordering in [Report].
 */

enum class Category {
    FOOD,
    RENT,
    UTILITIES,
    ENTERTAINMENT,
    MISC,
    TRANSPORT
}

/**
 * A single recorded expense.
 */
data class Expense(
    val id: Int,
    val category: Category,
    val amountCents: Int,
    val description: String,
    val date: LocalDate,
)

/**
 * In-memory ledger of expenses for the CLI session.
 */
class Ledger {
    private val expenses = mutableListOf<Expense>()
    private var nextId = 1

    fun add(category: Category, amountCents: Int, description: String, date: LocalDate): Expense {
        val expense = Expense(nextId, category, amountCents, description, date)
        expenses.add(expense)
        nextId += 1
        return expense
    }

    fun remove(id: Int): Boolean = expenses.removeIf { it.id == id }

    fun all(): List<Expense> = expenses.toList()

    fun totalForCategory(category: Category): Int =
        expenses.filter { it.category == category }.sumOf { it.amountCents }

    fun inMonth(year: Int, month: Int): List<Expense> =
        expenses.filter { it.date.year == year && it.date.monthValue == month }
}
