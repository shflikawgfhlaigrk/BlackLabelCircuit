package com.app

import com.app.util.Helper
import com.app.util.Missing
import kotlin.collections.List

fun main() {
    val helper = Helper()
    // `!!` force-unwrap — a latent NullPointerException.
    val name: String? = System.getenv("USER")
    println(helper.greet(name!!))

    try {
        risky()
    } catch (e: Exception) {
    }
}

fun risky() {
    val m = Missing()
    println(m)
}
