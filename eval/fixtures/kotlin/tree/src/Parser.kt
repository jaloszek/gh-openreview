package expensetracker

import java.time.LocalDate

/**
 * Parsing helpers for CLI arguments and imported expense lines.
 */
object Parser {
    /** Parses a dollar-amount string like "12.50" into integer cents, or null if invalid. */
    fun parseAmountCents(raw: String): Int? {
        val value = raw.toDoubleOrNull() ?: return null
        if (value < 0) return null
        return Math.round(value * 100).toInt()
    }

    /** Parses an ISO date string like "2024-03-01", or null if invalid. */
    fun parseDate(raw: String?): LocalDate? {
        if (raw == null) return null
        return runCatching { LocalDate.parse(raw) }.getOrNull()
    }
}
