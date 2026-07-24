{
  pkgs,
  src,
  system,
}:

let
  inherit (builtins) concatStringsSep filter map;
  inherit (pkgs.lib) assertMsg hasAttrByPath;

  exportedLib = src.legacyPackages.${system}.lib;
  requiredPaths = [
    [ "mkSandbox" ]
    [
      "profiles"
      "rust"
    ]
    [ "rustProfile" ]
  ];
  missingPaths = filter (path: !(hasAttrByPath path exportedLib)) requiredPaths;
  renderedMissingPaths = map (concatStringsSep ".") missingPaths;
in
assert assertMsg (
  missingPaths == [ ]
) "README flake API is missing: ${concatStringsSep ", " renderedMissingPaths}";
pkgs.writeText "test-readme-flake-export" "legacyPackages.${system}.lib"
