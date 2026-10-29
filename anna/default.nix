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

  # The wake words trained in lab/wakeword-<word>: one per models/wake/<word>.onnx.
  # The NixOS configuration picks one per machine (ANNA_WAKE_WORD), and falls
  # back on « karenine » for a machine without its own.
  wakeWords = map (lib.removeSuffix ".onnx") (
    lib.filter (lib.hasSuffix ".onnx") (lib.attrNames (builtins.readDir ./models/wake))
  );
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
    #   hyprctl (hyprland), dbus-send (dbus), gtk-update-icon-cache (gtk3),
    #   dconf
    #     → theme live-reload signals
    #   lspci (pciutils), df (coreutils)
    #     → hwstats collection
    #   pw-record (pipewire)
    #     → the echo-cancelled mic of the wake word and dictation (audio.rs)
    #   ssh (openssh)
    #     → the stats of the tailnet devices (servers.rs); the tailscale CLI
    #       itself is left to the ambient PATH, to match its daemon
    #   busctl (systemd)
    #     → the KDE Connect phones, over kdeconnectd's D-Bus API (phone.rs);
    #       kdeconnectd itself comes from the NixOS configuration
    #   wpctl (wireplumber), brightnessctl, playerctl, wl-paste (wl-clipboard),
    #   xdg-open (xdg-utils), grimblast
    #     → the pilot's desk tools (claude/desk.rs)
    #   ffmpeg, slurp, libnotify (notify-send)
    #     → recording the microphone, picking a screen region, saying where
    #       the file went (recorder.rs); ffmpeg also reads the webcam
    #       (gesture/camera.rs). gpu-screen-recorder is left to the ambient
    #       PATH: it needs its gsr-kms-server wrapper, given a capability by
    #       the NixOS configuration (programs.gpu-screen-recorder).
    #   secret-tool (libsecret)
    #     → the Nextcloud account's app password, kept in the Secret
    #       Service (cloud/mod.rs); xdg-open opens its login page, date
    #       (coreutils) gives the pilot's agenda in local time
    #   whisper-server, whisper-cli (whisper-cpp, Vulkan build), vulkaninfo
    #   (vulkan-tools)
    #     → transcribing what is said to the pilot, live (claude/voice.rs,
    #       claude/whisper.rs): Vulkan runs on the discrete GPU whatever its
    #       vendor (NVIDIA here, AMD on gary), and on the CPU without one. The
    #       model file is provided by the NixOS configuration.
    # The icon theme recoloured to the accent (src/icons.rs): Reversal, read in
    # place from the store through ANNA_ICON_SOURCE.
    # The wake words (claude/wake.rs): openWakeWord's two shared models, and
    # each word's own model trained in lab/wakeword-<word>, with how it is
    # written and heard (<word>.json). ONNX
    # Runtime is loaded at run time (ort's load-dynamic).
    mkdir -p "$out/share/anna/wake"
    cp ${melspectrogram} "$out/share/anna/wake/melspectrogram.onnx"
    cp ${embedding} "$out/share/anna/wake/embedding_model.onnx"
    cp ${./models/wake}/*.onnx ${./models/wake}/*.json "$out/share/anna/wake/"

    # The pilot's answers read aloud (claude/speech.rs): Piper voices run with
    # ONNX Runtime, their phonemes from libespeak-ng (loaded at run time, its
    # data dir compiled in), played by pw-play (pipewire, already on PATH).
    # The voice files are provided by the NixOS configuration.
    # nvidia-smi and sudo(dmidecode) are intentionally left to the ambient PATH:
    # they are host-specific and, for sudo, must be the setuid system binary.
    wrapProgram "$out/bin/anna" \
      --set-default ORT_DYLIB_PATH ${pkgs.onnxruntime}/lib/libonnxruntime.so \
      --set-default ANNA_WAKE_MODELS "$out/share/anna/wake" \
      --set-default ESPEAK_DYLIB_PATH ${pkgs.espeak-ng}/lib/libespeak-ng.so.1 \
      --set-default ANNA_ICON_SOURCE ${pkgs.reversal-icon-theme}/share/icons \
      --prefix PATH : ${
        lib.makeBinPath (
          with pkgs;
          [
            hyprland
            dbus
            gtk3
            dconf
            pciutils
            coreutils
            wireplumber
            pipewire
            brightnessctl
            playerctl
            wl-clipboard
            xdg-utils
            grimblast
            ffmpeg
            slurp
            libnotify
            openssh
            systemd
            (whisper-cpp.override { vulkanSupport = true; })
            vulkan-tools
            libsecret
          ]
        )
      }
  '';

  passthru = { inherit wakeWords; };

  meta = {
    description = "Unified engine daemon for karenine (accent/palette theming + hardware stats)";
    mainProgram = "anna";
  };
}
