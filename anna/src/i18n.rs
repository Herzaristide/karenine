//! The two languages, and anna's own messages.
//!
//! Both are picked in the shell's settings and kept in
//! `~/.config/karenine/locale.json` (`{"lang": "en", "voice": "fr"}`):
//! - `lang`, the interface's: the messages anna shows on screen (errors,
//!   alerts). English without one; `KARENINE_LANG` overrides it.
//! - `voice`, the one spoken to the pilot: the one it answers in (the
//!   transcription, Parakeet, detects what is said by itself). Empty: the
//!   interface's; `auto`: the pilot answers in whatever was said.
//!
//! The messages live in the shell's dictionaries, `i18n/<lang>.json` under
//! `anna.*` keys: the same files the QML reads, so a language added there
//! translates anna too, without rebuilding it. They are read from
//! `KARENINE_I18N`, else `~/.config/quickshell/i18n`, where the layout is
//! installed. A key missing from the language falls back to English, then to
//! the key itself.

use serde_json::Value;
use std::path::{Path, PathBuf};

pub const FALLBACK: &str = "en";
pub const AUTO: &str = "auto";

fn prefs() -> Value {
    std::fs::read_to_string(crate::paths::home_dir().join(".config/karenine/locale.json"))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or(Value::Null)
}

fn pref(key: &str) -> Option<String> {
    prefs()
        .get(key)?
        .as_str()
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

/// The interface language: `en`, `fr`…
pub fn lang() -> String {
    std::env::var("KARENINE_LANG")
        .ok()
        .filter(|l| !l.is_empty())
        .or_else(|| pref("lang"))
        .unwrap_or_else(|| FALLBACK.into())
}

/// The spoken language, as ISO 639-1: `en`, `fr`… or `auto`.
pub fn voice_lang() -> String {
    pref("voice").unwrap_or_else(lang)
}

/// What the pilot is told about the language to answer in.
pub fn pilot_language_line() -> String {
    pilot_line(&dir(), &voice_lang())
}

fn pilot_line(dir: &Path, voice: &str) -> String {
    if voice == AUTO {
        return "langue : réponds dans la langue de la demande".into();
    }
    let name = dict(dir, voice)
        .and_then(|d| d.get("_meta")?.get("name")?.as_str().map(str::to_string))
        .unwrap_or_else(|| voice.to_string());
    format!("langue : réponds en {name} ({voice}), quelle que soit la langue de ces consignes")
}

/// The message `anna.<key>` in the interface language.
pub fn tr(key: &str) -> String {
    tr_args(key, &[])
}

/// `tr`, its `{name}` placeholders replaced from `args`.
pub fn tr_args(key: &str, args: &[(&str, &str)]) -> String {
    translate(&dir(), &lang(), key, args)
}

fn dir() -> PathBuf {
    std::env::var("KARENINE_I18N")
        .ok()
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| crate::paths::home_dir().join(".config/quickshell/i18n"))
}

fn dict(dir: &Path, lang: &str) -> Option<Value> {
    let text = std::fs::read_to_string(dir.join(format!("{lang}.json"))).ok()?;
    serde_json::from_str(&text).ok()
}

fn translate(dir: &Path, lang: &str, key: &str, args: &[(&str, &str)]) -> String {
    let key = format!("anna.{key}");
    let text = [lang, FALLBACK]
        .iter()
        .find_map(|l| dict(dir, l)?.get(&key)?.as_str().map(str::to_string))
        .unwrap_or(key);
    args.iter().fold(text, |t, (name, value)| {
        t.replace(&format!("{{{name}}}"), value)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A folder of its own per call: the tests run in parallel, and one
    /// rewriting the files while another reads them made it read them empty.
    fn dicts() -> PathBuf {
        use std::sync::atomic::{AtomicUsize, Ordering};
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let d = std::env::temp_dir().join(format!(
            "anna-i18n-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(
            d.join("en.json"),
            r#"{"_meta": {"name": "English"}, "anna.hello": "Hello {name}", "anna.only_en": "English"}"#,
        )
        .unwrap();
        std::fs::write(
            d.join("fr.json"),
            r#"{"_meta": {"name": "Français"}, "anna.hello": "Bonjour {name}"}"#,
        )
        .unwrap();
        d
    }

    #[test]
    fn the_language_wins_then_english_then_the_key() {
        let d = dicts();
        assert_eq!(
            translate(&d, "fr", "hello", &[("name", "Anna")]),
            "Bonjour Anna"
        );
        assert_eq!(translate(&d, "fr", "only_en", &[]), "English");
        assert_eq!(
            translate(&d, "de", "hello", &[("name", "Anna")]),
            "Hello Anna"
        );
        assert_eq!(translate(&d, "fr", "missing", &[]), "anna.missing");
    }

    #[test]
    fn the_pilot_is_told_the_spoken_language_by_name() {
        let d = dicts();
        assert!(pilot_line(&d, "fr").contains("Français (fr)"));
        assert!(pilot_line(&d, "de").contains("de (de)"));
        assert!(pilot_line(&d, AUTO).contains("langue de la demande"));
    }
}
