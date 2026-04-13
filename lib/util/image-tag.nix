_: {
  mkImageTag =
    storePath:
    let
      hash = builtins.hashString "sha256" (builtins.unsafeDiscardStringContext (toString storePath));
    in
    builtins.substring 0 8 hash;
}
