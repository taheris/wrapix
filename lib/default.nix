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
  inherit (ralph) mkRalph scripts;

  deriveProfile =
    baseProfile: extensions:
    baseProfile
    // extensions
    // {
      packages = (baseProfile.packages or [ ]) ++ (extensions.packages or [ ]);
      mounts = (baseProfile.mounts or [ ]) ++ (extensions.mounts or [ ]);
      env = (baseProfile.env or { }) // (extensions.env or { });
      networkAllowlist = (baseProfile.networkAllowlist or [ ]) ++ (extensions.networkAllowlist or [ ]);
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
        # Ensure prek owns .git/hooks/ — bd hooks install can overwrite the shim
        if [ -d .git ] && ! grep -q 'prek' .git/hooks/pre-commit 2>/dev/null; then
          echo "Installing prek hooks (bd shim detected or hooks missing)..."
          prek install -f
          chmod 555 .git/hooks/
        fi
        echo "Wrapix development shell"
      '';
    };
}
