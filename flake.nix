{
  description = "karenine — interface Quickshell (QML, scripts, assets)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    {
      # Fichiers bruts de l'interface (QML/scripts/assets). La glue NixOS
      # (installation dans ~/.config/quickshell) vit dans la configuration qui
      # consomme cet input : elle lit `${inputs.karenine}/<fichier>` via le
      # chemin source du flake (outPath). Rien à builder ici.
    };
}
