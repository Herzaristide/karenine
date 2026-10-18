---
title: Development
group: Usage
summary: Validate the layout, run the tests, format, and what the CI checks.
links: [installation, backend, architecture, languages]
---

# Development

## Validate the layout

```bash
nix build .#default     # assembles the package (~/.config/quickshell)
nix flake check         # layout + qmllint (zero warnings) + QML tests + dictionaries
```

## Tests

```bash
cd anna && cargo test   # daemon: theme, protocol, client, DSP, gestures, i18n
tests/run.sh            # QML (qmltestrunner, offscreen) — inside `nix develop`
tests/i18n-check.sh     # dictionaries: every key used exists in English
```

The QML tests only cover **pure** singletons (QtQuick only, like `Fuzzy`):
the Quickshell plugin does not load outside the `quickshell` binary.
`tests/run.sh` copies them into a separate folder so as not to import the
rest of `services/`.

`tests/i18n-check.sh` fails when a key called by the QML (`I18n.tr`) or by
anna (`i18n::tr`) is missing from `i18n/en.json`, and lists, without failing,
the keys each other language still has to translate.

## Format

```bash
nix fmt                 # formats flake.nix (nixfmt-rfc-style)
cd anna && cargo fmt    # formats the daemon
```

## What the CI checks

- **`cargo fmt --check`**, **`cargo clippy -D warnings`** and **`cargo test`**
  on the `anna` daemon
- **`nix flake check`**: layout, qmllint, QML tests, dictionaries

See the daemon in [Backend](#backend), and the QML conventions in
[Architecture](#architecture).
