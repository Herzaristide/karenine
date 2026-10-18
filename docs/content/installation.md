---
title: Installation
group: Usage
summary: Install karenine through the flake (recommended) or by hand outside NixOS.
links: [configuration, development, architecture]
---

# Installation

## Through the flake (recommended)

`packages.default` assembles the layout ready for `~/.config/quickshell`. In
the NixOS/Home-Manager configuration that consumes this flake:

```nix
home.file.".config/quickshell".source = karenine.packages.${system}.default;
```

The package copies `shell.qml`, `services`, `panels`, `widgets`, `auth`, `lock`, `greeter`,
`i18n`, `assets` into `$out`. It is the **single source of truth** for the
layout — no more raw file copies on the configuration side. The `anna` daemon
is a separate package (`packages.anna`), to run as a user service.

anna reads its messages from the dictionaries of the installed layout,
`~/.config/quickshell/i18n`; set `KARENINE_I18N` if the layout lives
elsewhere (see [Languages](#languages)).

## By hand (outside NixOS)

1. Copy/symlink the repository's content into `~/.config/quickshell/`
   (keeping the subfolders).
2. Build and run the `anna` daemon (`cargo build --release` in `anna/`,
   needs `alsa-lib` + `pkg-config`).
3. Run `quickshell`.

Thanks to relative paths and the `anna` socket (see
[Architecture](#architecture)), no prefix setting is needed.

## Next

- Adjust the [hard-coded settings](#configuration) (screen, accent).
- To contribute, see [Development](#development).
