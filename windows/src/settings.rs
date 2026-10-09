//! What survives a restart: the line itself, the sound choice, and whether
//! the first-run hint has been shown. Stored as plain text in %APPDATA%.

use std::fs;
use std::path::PathBuf;

#[derive(Default)]
pub struct Settings {
    pub welcomed: bool,
    pub sound: bool,
    pub pegged: Vec<PathBuf>,
}

impl Settings {
    fn file() -> Option<PathBuf> {
        let base = std::env::var_os("APPDATA")?;
        Some(PathBuf::from(base).join("Tendedero").join("state.txt"))
    }

    pub fn load() -> Self {
        let mut s = Settings { sound: true, ..Default::default() };
        let Some(file) = Self::file() else { return s };
        let Ok(text) = fs::read_to_string(file) else { return s };
        for line in text.lines() {
            if let Some(v) = line.strip_prefix("welcomed=") {
                s.welcomed = v == "1";
            } else if let Some(v) = line.strip_prefix("sound=") {
                s.sound = v == "1";
            } else if let Some(v) = line.strip_prefix("peg=") {
                s.pegged.push(PathBuf::from(v));
            }
        }
        s
    }

    pub fn save(&self) {
        let Some(file) = Self::file() else { return };
        if let Some(dir) = file.parent() {
            let _ = fs::create_dir_all(dir);
        }
        let mut text = format!("welcomed={}\nsound={}\n", u8::from(self.welcomed), u8::from(self.sound));
        for p in &self.pegged {
            text.push_str("peg=");
            text.push_str(&p.to_string_lossy());
            text.push('\n');
        }
        let _ = fs::write(file, text);
    }
}

/// Where the app is started from, for the "open at login" entry.
pub fn exe_path() -> Option<PathBuf> {
    std::env::current_exe().ok()
}
