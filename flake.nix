{
  description = "karenine — interface Quickshell (QML, scripts, assets)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f {
            inherit system;
            pkgs = nixpkgs.legacyPackages.${system};
          }
        );
    in
    {
      # Layout prêt à l'emploi pour ~/.config/quickshell. La config NixOS qui
      # consomme ce flake fait pointer :
      #   home.file.".config/quickshell".source = karenine.packages.${system}.default;
      # (ou l'installe autrement). Plus de copie de fichiers bruts ni de wrappers
      # générés côté config : ce paquet est la seule source de vérité du layout.
      packages = forAllSystems (
        { pkgs, system }:
        {
          # anna — moteur Rust unifié (thème accent/palette + stats matérielles).
          # Fournit le binaire `anna` (daemon + client + init + msi-rgb-watch) et
          # installe les templates de thème sous $out/share/anna/templates/.
          anna = pkgs.callPackage ./anna/default.nix { };

          default = pkgs.stdenvNoCC.mkDerivation {
            pname = "karenine";
            version = "0.1.0";
            src = self;

            dontConfigure = true;
            dontBuild = true;

            installPhase = ''
              runHook preInstall
              mkdir -p "$out"
              cp -r shell.qml services panels widgets ai assets "$out"/
              runHook postInstall
            '';

            meta = {
              description = "Interface Quickshell (barre, panneaux, chat IA, accordeur, métronome)";
              platforms = systems;
            };
          };
        }
      );

      # `nix flake check` valide au minimum que le layout s'assemble.
      checks = forAllSystems (
        { system, ... }:
        {
          build = self.packages.${system}.default;
        }
      );

      devShells = forAllSystems (
        { pkgs, ... }:
        {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [
              qt6.full
              qmlls
            ];
          };
        }
      );

      formatter = forAllSystems ({ pkgs, ... }: pkgs.nixfmt-rfc-style);
    };
}
