{
  pkgs,
  lib ? pkgs.lib,
  ...
}:

let
  # openWakeWord's shared models (Apache-2.0), release v0.5.1.
  melspectrogram = pkgs.fetchurl {
    url = "https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/melspectrogram.onnx";
    hash = "sha256-uisOD4t7h1NposicsTNg/1O6xDbyiVzO2fR5+mXrF28=";
  };
  embedding = pkgs.fetchurl {
    url = "https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/embedding_model.onnx";
    hash = "sha256-cNFkKQwdCV0dTuFJvF4AVDJQpzFrWfMdBWz/e9MHXB8=";
  };
in
pkgs.rustPlatform.buildRustPackage {
  pname = "anna";
  version = "0.1.0";

  # Exclude the Cargo build dir so it doesn't bloat the store copy.
  src = lib.cleanSourceWith {
    src = ./.;
    filter = path: _type: baseNameOf path != "target";
  };

  cargoLock.lockFile = ./Cargo.lock;

  # pkg-config + alsa-lib are needed to build cpal's ALSA backend (mic capture
  # for the tuner/chroma services, click playback for the metronome). alsa-lib
  # is also a runtime dependency, so it is a buildInput (put on the RPATH).
  nativeBuildInputs = [
    pkgs.makeWrapper
    pkgs.pkg-config
  ];

  buildInputs = [ pkgs.alsa-lib ];

  postInstall = ''
    # Theme templates read at runtime by the renderer. The home-manager module
    # installs these into ~/.config/accent/templates/, but shipping them in the
    # package keeps anna the single source of truth for the template set.
    mkdir -p "$out/share/anna/templates"
    cp -r ${./templates}/. "$out/share/anna/templates/"

    # Wrap host-agnostic subprocess tools into PATH:
    #   hyprctl (hyprland), dbus-send (dbus), gtk-update-icon-cache (gtk3)
    #     → theme live-reload signals
    #   lspci (pciutils), df (coreutils)
    #     → hwstats collection
    #   git
    #     → reviewing / merging the worktrees of AI dock sessions
    #       (claude/worktree.rs)
    #   wpctl (wireplumber), brightnessctl, playerctl, wl-paste (wl-clipboard),
    #   xdg-open (xdg-utils), grimblast
    #     → the pilot's desk tools (claude/desk.rs)
    #   whisper-server, whisper-cli (whisper-cpp, Vulkan build), vulkaninfo
    #   (vulkan-tools)
    #     → transcribing what is said to the pilot, live (claude/voice.rs,
    #       claude/whisper.rs): Vulkan runs on the discrete GPU whatever its
    #       vendor (NVIDIA here, AMD on gary), and on the CPU without one. The
    #       model file is provided by the NixOS configuration.
    # The wake word « Karénine » (claude/wake.rs): openWakeWord's two shared
    # models, and the word's own model trained in lab/wakeword-karenine. ONNX
    # Runtime is loaded at run time (ort's load-dynamic).
    mkdir -p "$out/share/anna/wake"
    cp ${melspectrogram} "$out/share/anna/wake/melspectrogram.onnx"
    cp ${embedding} "$out/share/anna/wake/embedding_model.onnx"
    cp ${./models/wake/karenine.onnx} "$out/share/anna/wake/karenine.onnx"

    # nvidia-smi and sudo(dmidecode) are intentionally left to the ambient PATH:
    # they are host-specific and, for sudo, must be the setuid system binary.
    wrapProgram "$out/bin/anna" \
      --set-default ORT_DYLIB_PATH ${pkgs.onnxruntime}/lib/libonnxruntime.so \
      --set-default ANNA_WAKE_MODELS "$out/share/anna/wake" \
      --prefix PATH : ${
        lib.makeBinPath (
          with pkgs;
          [
            hyprland
            dbus
            gtk3
            pciutils
            coreutils
            git
            wireplumber
            brightnessctl
            playerctl
            wl-clipboard
            xdg-utils
            grimblast
            (whisper-cpp.override { vulkanSupport = true; })
            vulkan-tools
          ]
        )
      }
  '';

  meta = {
    description = "Unified engine daemon for karenine (accent/palette theming + hardware stats)";
    mainProgram = "anna";
  };
}
