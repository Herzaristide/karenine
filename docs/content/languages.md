---
title: Languages
group: Features
summary: The interface language and the voice language, the dictionaries in i18n/, and how to add a language.
links: [configuration, widgets, ai, backend, development]
---

# Languages

karenine has **two separate language settings**, both in the settings
window:

| Setting | Where | What it changes |
| --- | --- | --- |
| **Interface language** | its own section, one row per language | Every text of the shell, the lock screen, and the messages anna shows (errors, notices). Dates follow it. |
| **Voice language** | under “Voice”, ‹ › to change | Whisper's language and the one the pilot answers in. “Same as interface” by default, or “Automatic detection”, or a given language. |

They are separate because they often differ: you can speak French to an
interface in English. The interface is in **English** by default.

Both choices are kept in `~/.config/karenine/locale.json`, read by the shell,
the lock screen and anna:

```json
{ "lang": "en", "voice": "fr" }
```

`voice` empty means the interface language; `auto` lets whisper detect it.
The interface language can also be typed in the bar's search
(“language”): Enter moves to the next one.

## The dictionaries (`i18n/`)

One JSON file per language, named after its code:

```
i18n/
  en.json      reference and fallback language
  fr.json
```

```json
{
  "_meta": { "name": "Français", "locale": "fr_FR" },
  "settings.title": "Paramètres",
  "review.files.one": "{n} fichier",
  "review.files.other": "{n} fichiers",
  "anna.phone.plug_usb": "Branche le téléphone en USB, avec le débogage USB activé."
}
```

- `_meta.name` is the language's name **in that language**, as shown in the
  settings; `_meta.locale` is the Qt locale used for dates.
- Keys describe the role of the text (`settings.screen`), not the text
  itself, so a translation can be fixed without touching the code.
- `{name}` placeholders are filled by the caller; `.one` / `.other` keys are
  the singular and plural of a count (`I18n.trn`).
- `anna.*` keys are anna's messages: anna reads the same files at run time.
- A key missing from a language falls back to English, then to the key
  itself: a partial translation never leaves a hole.

## In the code

QML, through the `I18n` singleton (`services/I18n.qml`):

```qml
text: I18n.tr("settings.title")
text: I18n.tr("explorer.connecting", { name: root.connecting })
text: I18n.trn("review.files", count)
text: I18n.locale.toString(date, I18n.tr("date.long"))
```

Bindings that call `I18n.tr` are re-evaluated when the language changes:
the whole interface switches live, without a restart.

anna, through `anna/src/i18n.rs`:

```rust
Err(crate::i18n::tr("phone.plug_usb"))
crate::i18n::tr_args("voice.no_model", &[("path", &path)])
```

anna finds the dictionaries in `KARENINE_I18N`, otherwise in
`~/.config/quickshell/i18n`, where the layout is installed.

What is **not** translated: the identifiers shared with the pilot and the
FIFO (`lecteur`, `reglages`, `ouvrir`…), the pilot's tools and system prompt
(the model reads them, not the user) and code comments.

## Adding a language

1. Copy `i18n/en.json` to `i18n/<code>.json` (`de.json`, `es.json`…), using
   the language's ISO 639-1 code: it is also whisper's code for it.
2. Set `_meta.name` (“Deutsch”) and `_meta.locale` (`de_DE`).
3. Translate the values, keeping keys and `{placeholders}` as they are.
4. Run `tests/i18n-check.sh`: it lists what is still missing in each
   language (missing keys fall back to English, so this does not fail).

Nothing else: the language shows up by itself in both settings, the shell
loads it live (the files are watched), and anna and whisper use it too —
no rebuild.

## The greeter

The login screen runs as the greeter user, before any session: it has no
`~/.config/karenine`. It takes its language from the `KARENINE_LANG`
environment variable, set by the NixOS configuration, and is in English
without it.
