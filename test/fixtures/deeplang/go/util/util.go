package util

import "strings"

// Greet returns a friendly, trimmed greeting for the given name.
func Greet(name string) string {
	return "hello, " + strings.TrimSpace(name)
}
