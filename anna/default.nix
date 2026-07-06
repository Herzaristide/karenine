{
  pkgs,
  lib ? pkgs.lib,
  ...
}:

pkgs.rustPlatform.buildRustPackage {
  pname = "anna";
  version = "0.1.0";

  # Exclude the Cargo build dir so it doesn't bloat the store copy.
  src = lib.cleanSourceWith {
    src = ./.;
    filter = path: _type: baseNameOf path != "target";
  };

  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [ pkgs.makeWrapper ];

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
    # nvidia-smi and sudo(dmidecode) are intentionally left to the ambient PATH:
    # they are host-specific and, for sudo, must be the setuid system binary.
    wrapProgram "$out/bin/anna" \
      --prefix PATH : ${
        lib.makeBinPath (
          with pkgs;
          [
            hyprland
            dbus
            gtk3
            pciutils
            coreutils
          ]
        )
      }
  '';

  meta = {
    description = "Unified engine daemon for karenine (accent/palette theming + hardware stats)";
    mainProgram = "anna";
  };
}
