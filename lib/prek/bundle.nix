{ pkgs }:

pkgs.runCommand "wrix-prek-hooks"
  {
    outputHash = "sha256-LfcoQVD0j8qLiSnPqNZl7MYkU2borT+2FcYI62bHcr4=";
    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
  }
  ''
    set -euo pipefail
    cp -a ${./hooks}/. "$out"
  ''
