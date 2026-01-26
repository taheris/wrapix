{
  pkgs,
  system,
  linuxPkgs ? pkgs,
}:

let
  sandbox = import ./sandbox { inherit pkgs system linuxPkgs; };
  ralph = import ./ralph {
    inherit pkgs;
    inherit (sandbox) mkSandbox;
  };

in
{
  inherit (sandbox) profiles mkSandbox;
  inherit (ralph) mkRalph;

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
}
