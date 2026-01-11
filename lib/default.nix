{
  pkgs,
  system,
  linuxPkgs ? pkgs,
}:

let
  sandbox = import ./sandbox { inherit pkgs system linuxPkgs; };
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

  # Profiles use Linux packages internally - access via sandbox.profiles
  inherit (sandbox) profiles;
}
