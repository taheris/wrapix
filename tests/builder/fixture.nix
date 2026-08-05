{
  pkgs,
  linuxPkgs ? pkgs,
}:

let
  builderImage = {
    digest = pkgs.writeText "wrix-builder-fixture-digest" ''
      sha256:0000000000000000000000000000000000000000000000000000000000000000
    '';
    ref = "wrix-builder:fixture";
    source = pkgs.writeText "wrix-builder-fixture-archive" "fixture\n";
    source_kind = "docker-archive";
  };
in
import ../../lib/builder {
  inherit pkgs linuxPkgs builderImage;
}
