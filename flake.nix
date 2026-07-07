{
  description = "karenine — interface Quickshell (QML, scripts, assets)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
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
        { pkgs, ... }:
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

      # `nix flake check` valide que le layout s'assemble ET que le QML passe
      # qmllint sans warning.
      checks = forAllSystems (
        { pkgs, system }:
        {
          build = self.packages.${system}.default;

          # Lint QML. qmllint doit connaître les modules Qt6 (qtdeclarative :
          # QtQuick, QtQml, QtCore, QtQuick.Controls/Layouts/Effects) et le module
          # Quickshell — sans ces -I, aucun import ne se résout et il crache des
          # milliers de faux warnings. Les faux positifs résiduels (types C++ de
          # Quickshell mal décrits dans les .qmltypes) sont neutralisés par des
          # directives `// qmllint disable` dans les fichiers concernés.
          #
          # qmllint sort en code 0 même en présence de warnings, donc on échoue
          # nous-mêmes si la sortie contient une ligne Warning/Error.
          qmllint =
            let
              qt = pkgs.qt6.qtdeclarative;
              qs = pkgs.quickshell;
            in
            pkgs.runCommand "karenine-qmllint" { } ''
              log=$(${qt}/bin/qmllint \
                -I ${qt}/lib/qt-6/qml \
                -I ${qs}/lib/qt-6/qml \
                $(find ${self} -name '*.qml') 2>&1) || true
              if printf '%s\n' "$log" | grep -qE '^(Warning|Error)'; then
                printf '%s\n' "$log"
                echo "qmllint a signalé des problèmes (voir ci-dessus)" >&2
                exit 1
              fi
              touch $out
            '';
        }
      );

      devShells = forAllSystems (
        { pkgs, ... }:
        {
          default = pkgs.mkShell {
            # qtdeclarative fournit qmllint + qmlls + les modules QtQuick/QtQml.
            packages = [
              pkgs.qt6.qtdeclarative
              pkgs.quickshell
            ];
            # Pour `qmllint -E` / `qmlls -E` et le confort en ligne de commande.
            QML_IMPORT_PATH = "${pkgs.qt6.qtdeclarative}/lib/qt-6/qml:${pkgs.quickshell}/lib/qt-6/qml";
          };
        }
      );

      formatter = forAllSystems ({ pkgs, ... }: pkgs.nixfmt-rfc-style);
    };
}
