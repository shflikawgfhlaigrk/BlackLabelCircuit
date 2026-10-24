/// Returns the trimmed, upper-cased greeting for `name`.
pub fn shout(name: &str) -> String {
    format!("HELLO, {}", name.trim().to_uppercase())
}
