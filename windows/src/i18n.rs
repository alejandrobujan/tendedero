//! Text for the app. The macOS translations are reused as they are, then the
//! Windows overrides in `strings/` are applied on top. Keys are the English
//! text, exactly as the macOS app uses them.

use std::collections::HashMap;
use std::sync::OnceLock;

const MAC_EN: &str = include_str!("../../Sources/Tendedero/Resources/en.lproj/Localizable.strings");
const MAC_ES: &str = include_str!("../../Sources/Tendedero/Resources/es.lproj/Localizable.strings");
const MAC_ZH: &str = include_str!("../../Sources/Tendedero/Resources/zh-Hans.lproj/Localizable.strings");
const WIN_EN: &str = include_str!("../strings/en.strings");
const WIN_ES: &str = include_str!("../strings/es.strings");
const WIN_ZH: &str = include_str!("../strings/zh-Hans.strings");

static TABLE: OnceLock<HashMap<String, String>> = OnceLock::new();

/// Looks up a string for the user's language. Anything missing shows in
/// English, which is the key itself.
pub fn t(key: &str) -> String {
    let table = TABLE.get_or_init(load);
    table.get(key).cloned().unwrap_or_else(|| key.to_string())
}

/// Whether the user's Windows language is Spanish or Chinese, to pick the
/// matching translation. The locale name looks like "es-ES" or "zh-CN".
fn load() -> HashMap<String, String> {
    let locale = user_locale();
    let (mac, win) = if locale.starts_with("es") {
        (MAC_ES, WIN_ES)
    } else if locale.starts_with("zh") {
        (MAC_ZH, WIN_ZH)
    } else {
        (MAC_EN, WIN_EN)
    };
    let mut table = parse(mac);
    table.extend(parse(win));
    table
}

/// Whether the Windows language is Chinese, which decides the font too.
pub fn is_chinese() -> bool {
    user_locale().starts_with("zh")
}

fn user_locale() -> String {
    let mut buf = [0u16; 85];
    let len = unsafe { windows::Win32::Globalization::GetUserDefaultLocaleName(&mut buf) };
    if len <= 1 {
        return String::new();
    }
    String::from_utf16_lossy(&buf[..(len as usize - 1)])
}

/// Reads the `"key" = "value";` lines of a .strings file, skipping comments.
fn parse(text: &str) -> HashMap<String, String> {
    let mut table = HashMap::new();
    let mut chars = text.chars().peekable();
    let mut strings: Vec<String> = Vec::new();
    while let Some(c) = chars.next() {
        match c {
            '/' if chars.peek() == Some(&'*') => {
                chars.next();
                let mut prev = ' ';
                for d in chars.by_ref() {
                    if prev == '*' && d == '/' { break; }
                    prev = d;
                }
            }
            '"' => {
                let mut s = String::new();
                while let Some(d) = chars.next() {
                    match d {
                        '"' => break,
                        '\\' => match chars.next() {
                            Some('n') => s.push('\n'),
                            Some('t') => s.push('\t'),
                            Some(e) => s.push(e),
                            None => break,
                        },
                        _ => s.push(d),
                    }
                }
                strings.push(s);
                if strings.len() == 2 {
                    let value = strings.pop().unwrap();
                    let key = strings.pop().unwrap();
                    table.insert(key, value);
                }
            }
            _ => {}
        }
    }
    table
}
