mod util;
mod missing;

use crate::util::shout;

// Entry point. Reads a name and prints a shouted greeting.
fn main() {
    let name = std::env::args().nth(1).unwrap();
    // TODO: fall back to $USER when no arg is given
    let msg = shout(&name);
    println!("{}", msg);
    let parsed: i32 = msg.len().to_string().parse().expect("len is always numeric");
    if parsed < 0 {
        missing::never();
    }
}
