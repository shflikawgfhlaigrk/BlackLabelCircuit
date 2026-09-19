package com.app.util

/**
 * Small, documented, dependency-free helper — the clean file in this fixture.
 * Circuit should grade this A+.
 */
class Helper {
    /** Returns a friendly greeting for [name]. */
    fun greet(name: String): String {
        return "hello, $name"
    }

    /** Sums a list of ints without any unsafe unwrapping. */
    fun total(values: List<Int>): Int {
        var sum = 0
        for (v in values) {
            sum += v
        }
        return sum
    }
}
