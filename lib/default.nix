{
  pkgs,
  system,
}:

let
  sandbox = import ./sandbox { inherit pkgs system; };
  profiles = import ./sandbox/profiles.nix { inherit pkgs; };
in
{
  mkSandbox = profile: sandbox.mkSandbox profile;

  deriveProfile =
    baseProfile: extensions:
    baseProfile
    // extensions
    // {
      packages = (baseProfile.packages or [ ]) ++ (extensions.packages or [ ]);
      mounts = (baseProfile.mounts or [ ]) ++ (extensions.mounts or [ ]);
      env = (baseProfile.env or { }) // (extensions.env or { });
    };

  mkDevShell =
    {
      packages ? [ ],
      shellHook ? "",
    }:
    pkgs.mkShell {
      inherit packages;
      shellHook = ''
        ${shellHook}
        echo "Wrapix development shell"
      '';
    };

  inherit profiles;
}
