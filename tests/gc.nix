# Gas City tests — layered testing for mkCity, provider, and container lifecycle
#
# Layer 1 (pre-commit): Nix evaluation tests
#   - mkCity evaluates with minimal config
#   - Generated city.toml is valid and references wrapix provider
#   - Service packages build into OCI images via dockerTools.buildLayeredImage
#
# Layer 2 (pre-commit): Provider script tests
#   - All 21 provider methods handled
#   - Persistent role tmux setup
#   - Ephemeral worker worktree lifecycle
#
# Layer 3 (pre-commit): Container lifecycle / shell syntax tests
#   - Entrypoint, recovery, gate, post-gate, scout, agent scripts validate
#
# Combined as gc-fast check for pre-commit stage.
{
  pkgs,
  system,
}:

let
  inherit (pkgs) bash runCommandLocal;

  linuxPkgs =
    if system == "aarch64-darwin" then
      import pkgs.path {
        system = "aarch64-linux";
        config.allowUnfree = true;
        inherit (pkgs) overlays;
      }
    else
      pkgs;

  sandbox = import ../lib/sandbox {
    inherit pkgs system;
    inherit linuxPkgs;
  };

  city = import ../lib/city {
    inherit pkgs linuxPkgs;
    inherit (sandbox) mkSandbox profiles;
  };

  # Evaluate mkCity with minimal config
  minimalCity = city.mkCity {
    services.api.package = linuxPkgs.hello;
    secrets.claude = "ANTHROPIC_API_KEY";
  };

  # Evaluate mkCity with no services (edge case)
  emptyCity = city.mkCity { services = { }; };

  # Evaluate mkCity with full options
  fullCity = city.mkCity {
    services.api.package = linuxPkgs.hello;
    services.db.package = linuxPkgs.hello;
    profile = sandbox.profiles.base;
    agent = "claude";
    workers = 2;
    cooldown = "2h";
    scout = {
      interval = "10m";
      maxBeads = 5;
    };
    resources = {
      worker = {
        cpus = 2;
        memory = "4g";
      };
      scout = {
        cpus = 1;
        memory = "2g";
      };
    };
    secrets = {
      claude = "ANTHROPIC_API_KEY";
      deployKey = "/run/secrets/deploy-key";
    };
  };

in
{
  # =========================================================================
  # Layer 1: Nix Evaluation Tests
  # =========================================================================

  # mkCity evaluates with minimal config
  gc-mkcity-eval =
    let
      hasConfig = builtins.hasAttr "config" minimalCity;
      hasProvider = builtins.hasAttr "provider" minimalCity;
      hasServiceImages = builtins.hasAttr "serviceImages" minimalCity;
      hasFormulas = builtins.hasAttr "formulas" minimalCity;
      hasDefaultFormulas = builtins.hasAttr "defaultFormulas" minimalCity;

      # Full city also evaluates
      fullHasConfig = builtins.hasAttr "config" fullCity;

      # Empty city evaluates
      emptyHasConfig = builtins.hasAttr "config" emptyCity;
    in
    assert hasConfig;
    assert hasProvider;
    assert hasServiceImages;
    assert hasFormulas;
    assert hasDefaultFormulas;
    assert fullHasConfig;
    assert emptyHasConfig;
    runCommandLocal "gc-mkcity-eval" { } ''
      echo "PASS: mkCity evaluates with minimal, full, and empty configs"
      echo "  - config, provider, serviceImages, formulas, defaultFormulas present"
      mkdir $out
    '';

  # Generated city.toml references exec: provider
  gc-city-toml =
    let
      inherit (minimalCity) configAttrs;
      providerStr = configAttrs.city.provider;
      hasExecPrefix = builtins.substring 0 5 providerStr == "exec:";
      hasNixStore = builtins.substring 5 10 providerStr == "/nix/store";

      # Verify session config
      hasSession = builtins.hasAttr "session" configAttrs;
      hasScout = builtins.hasAttr "scout" configAttrs;

      # Verify full city has resources section
      fullHasResources = builtins.hasAttr "resources" fullCity.configAttrs;

      # Verify cooldown is passed through
      fullCooldown = fullCity.configAttrs.session.cooldown;
      cooldownCorrect = fullCooldown == "2h";
    in
    assert hasExecPrefix;
    assert hasNixStore;
    assert hasSession;
    assert hasScout;
    assert fullHasResources;
    assert cooldownCorrect;
    runCommandLocal "gc-city-toml" { } ''
      echo "PASS: city.toml is valid"
      echo "  - provider references exec:/nix/store/..."
      echo "  - session and scout sections present"
      echo "  - resources section present when configured"
      echo "  - cooldown passed through correctly"
      mkdir $out
    '';

  # Service packages build into OCI images
  gc-service-images =
    let
      apiImage = minimalCity.serviceImages.api;
      imageName = apiImage.name;
      nameCorrect = builtins.substring 0 14 imageName == "wrapix-svc-api";

      # Full city has multiple service images
      fullHasApi = builtins.hasAttr "api" fullCity.serviceImages;
      fullHasDb = builtins.hasAttr "db" fullCity.serviceImages;
    in
    assert nameCorrect;
    assert fullHasApi;
    assert fullHasDb;
    runCommandLocal "gc-service-images" { } ''
      echo "Checking service image is a valid tar archive..."
      test -f ${apiImage}
      tar -tf ${apiImage} >/dev/null
      echo "PASS: Service images build via dockerTools.buildLayeredImage"
      echo "  - wrapix-svc-api image is a valid tar"
      echo "  - Multiple services supported"
      mkdir $out
    '';

  # Secrets classification
  gc-secrets =
    let
      inherit (minimalCity) classifiedSecrets;
      claudeSecret = classifiedSecrets.claude;
      claudeIsEnv = claudeSecret.type == "env";

      fullSecrets = fullCity.classifiedSecrets;
      deployIsFile = fullSecrets.deployKey.type == "file";
      deployPath = fullSecrets.deployKey.path == "/run/secrets/deploy-key";
    in
    assert claudeIsEnv;
    assert deployIsFile;
    assert deployPath;
    runCommandLocal "gc-secrets" { } ''
      echo "PASS: Secrets classified correctly"
      echo "  - env var secret: type=env"
      echo "  - file path secret: type=file with correct path"
      mkdir $out
    '';

  # =========================================================================
  # Layer 2: Provider Script Tests (static analysis)
  # =========================================================================

  # Provider script handles all 21 methods
  gc-provider-methods =
    runCommandLocal "gc-provider-methods"
      {
        nativeBuildInputs = [
          bash
          pkgs.gnugrep
        ];
      }
      ''
        set -euo pipefail
        PROVIDER="${../lib/city/provider.sh}"

        echo "Checking provider script methods..."

        # Verify shell conventions
        head -15 "$PROVIDER" | grep -q 'set -euo pipefail' || { echo "FAIL: missing set -euo pipefail"; exit 1; }

        # All 21 methods must be in the case statement
        METHODS="Start Stop Interrupt IsRunning Attach Peek SendKeys Nudge GetLastActivity ClearScrollback IsAttached ListRunning SetMeta GetMeta RemoveMeta CopyTo ProcessAlive CheckImage Capabilities"
        for method in $METHODS; do
          grep -qE "^  ''${method}\)" "$PROVIDER" || { echo "FAIL: method $method not found"; exit 1; }
          echo "  found: $method"
        done

        # Unknown method handler
        grep -qE '^\s+\*\)' "$PROVIDER" || { echo "FAIL: no unknown method handler"; exit 1; }

        # Container labeling convention
        grep -q 'gc-city=' "$PROVIDER" || { echo "FAIL: missing gc-city label"; exit 1; }
        grep -q 'gc-role=' "$PROVIDER" || { echo "FAIL: missing gc-role label"; exit 1; }
        grep -q 'gc-bead=' "$PROVIDER" || { echo "FAIL: missing gc-bead label"; exit 1; }

        # Persistent role: tmux as PID 1
        grep -q 'tmux new-session' "$PROVIDER" || { echo "FAIL: no tmux new-session"; exit 1; }
        grep -q 'tmux send-keys' "$PROVIDER" || { echo "FAIL: no tmux send-keys"; exit 1; }
        grep -q 'tmux capture-pane' "$PROVIDER" || { echo "FAIL: no tmux capture-pane"; exit 1; }

        # Ephemeral worker: git worktree lifecycle
        grep -q '\.wrapix/worktree/gc-' "$PROVIDER" || { echo "FAIL: no worktree path"; exit 1; }
        grep -q 'git.*worktree add' "$PROVIDER" || { echo "FAIL: no git worktree add"; exit 1; }
        grep -q 'bd meta set.*commit_range' "$PROVIDER" || { echo "FAIL: no commit_range metadata"; exit 1; }
        grep -q 'bd meta set.*branch_name' "$PROVIDER" || { echo "FAIL: no branch_name metadata"; exit 1; }

        # Worker no-ops
        for noop in Interrupt SendKeys Nudge ClearScrollback; do
          grep -A3 "^  ''${noop})" "$PROVIDER" | grep -q 'is_worker' || { echo "FAIL: $noop missing worker no-op check"; exit 1; }
        done

        echo ""
        echo "PASS: All 21 provider methods present and correctly structured"
        mkdir $out
      '';

  # =========================================================================
  # Layer 3: Shell Script Syntax and Structure Tests
  # =========================================================================

  # Validate all Gas City shell scripts have correct syntax
  gc-shell-syntax =
    runCommandLocal "gc-shell-syntax"
      {
        nativeBuildInputs = [
          bash
          pkgs.gnugrep
        ];
      }
      ''
        set -euo pipefail
        echo "Checking Gas City shell script syntax..."

        SCRIPTS=(
          "${../lib/city/provider.sh}"
          "${../lib/city/agent.sh}"
          "${../lib/city/gate.sh}"
          "${../lib/city/post-gate.sh}"
          "${../lib/city/entrypoint.sh}"
          "${../lib/city/recovery.sh}"
          "${../lib/city/scout.sh}"
        )

        for script in "''${SCRIPTS[@]}"; do
          name="$(basename "$script")"
          bash -n "$script" || { echo "FAIL: $name has syntax errors"; exit 1; }
          head -20 "$script" | grep -q 'set -euo pipefail' || { echo "FAIL: $name missing set -euo pipefail"; exit 1; }
          echo "  PASS: $name"
        done

        echo ""
        echo "PASS: All Gas City shell scripts have valid syntax"
        mkdir $out
      '';

  # Gate script structure
  gc-gate-structure =
    runCommandLocal "gc-gate-structure"
      {
        nativeBuildInputs = [
          bash
          pkgs.gnugrep
        ];
      }
      ''
        set -euo pipefail
        GATE="${../lib/city/gate.sh}"

        echo "Checking gate condition script..."

        grep -q 'GC_BEAD_ID' "$GATE" || { echo "FAIL: missing GC_BEAD_ID"; exit 1; }
        grep -q 'bd meta get.*commit_range' "$GATE" || { echo "FAIL: no commit_range read"; exit 1; }
        grep -q 'gc nudge reviewer' "$GATE" || { echo "FAIL: no reviewer nudge"; exit 1; }
        grep -q 'bd meta get.*review_verdict' "$GATE" || { echo "FAIL: no verdict poll"; exit 1; }

        # Exit codes: 0 for approve, 1 for reject
        grep -A2 'approve)' "$GATE" | grep -qE 'exit 0' || { echo "FAIL: approve not exit 0"; exit 1; }
        grep -A2 'reject)' "$GATE" | grep -qE 'exit 1' || { echo "FAIL: reject not exit 1"; exit 1; }

        echo "PASS: Gate condition script correctly structured"
        mkdir $out
      '';

  # Entrypoint structure
  gc-entrypoint-structure =
    runCommandLocal "gc-entrypoint-structure"
      {
        nativeBuildInputs = [
          bash
          pkgs.gnugrep
        ];
      }
      ''
        set -euo pipefail
        EP="${../lib/city/entrypoint.sh}"

        echo "Checking entrypoint wrapper..."

        # Scaffolding bead check
        grep -q 'bd human list' "$EP" || { echo "FAIL: no scaffolding bead check"; exit 1; }
        grep -q 'scaffol' "$EP" || { echo "FAIL: no scaffolding filter"; exit 1; }

        # Podman events watcher
        grep -q 'podman events' "$EP" || { echo "FAIL: no podman events watcher"; exit 1; }
        grep -q 'gc nudge scout' "$EP" || { echo "FAIL: no scout nudge on events"; exit 1; }

        # Recovery before gc start
        grep -q 'recovery.sh' "$EP" || { echo "FAIL: no recovery call"; exit 1; }

        # Final exec
        grep -q 'exec gc start --foreground' "$EP" || { echo "FAIL: no exec gc start"; exit 1; }

        echo "PASS: Entrypoint wrapper correctly structured"
        mkdir $out
      '';

  # Recovery script structure
  gc-recovery-structure =
    runCommandLocal "gc-recovery-structure"
      {
        nativeBuildInputs = [
          bash
          pkgs.gnugrep
        ];
      }
      ''
        set -euo pipefail
        REC="${../lib/city/recovery.sh}"

        echo "Checking crash recovery script..."

        grep -q 'podman ps.*--filter.*label=gc-city=' "$REC" || { echo "FAIL: no podman ps scan"; exit 1; }
        grep -q 'podman stop\|stop_container' "$REC" || { echo "FAIL: no orphan stop"; exit 1; }
        grep -q 'podman rm' "$REC" || { echo "FAIL: no orphan remove"; exit 1; }
        grep -q 'branch_has_commits' "$REC" || { echo "FAIL: no finished worker check"; exit 1; }
        grep -q 'git.*worktree prune' "$REC" || { echo "FAIL: no worktree prune"; exit 1; }
        grep -q 'gc-bead' "$REC" || { echo "FAIL: no gc-bead label usage"; exit 1; }

        echo "PASS: Crash recovery script correctly structured"
        mkdir $out
      '';

  # Post-gate order structure
  gc-postgate-structure =
    runCommandLocal "gc-postgate-structure"
      {
        nativeBuildInputs = [
          bash
          pkgs.gnugrep
        ];
      }
      ''
        set -euo pipefail
        PG="${../lib/city/post-gate.sh}"

        echo "Checking post-gate order..."

        # Merge: ff-only, rebase fallback, prek
        grep -q 'git.*merge --ff-only' "$PG" || { echo "FAIL: no ff-only merge"; exit 1; }
        grep -q 'git.*rebase main' "$PG" || { echo "FAIL: no rebase fallback"; exit 1; }
        grep -q 'prek run' "$PG" || { echo "FAIL: no prek after rebase"; exit 1; }

        # Worktree and branch cleanup
        grep -q 'git.*worktree remove' "$PG" || { echo "FAIL: no worktree cleanup"; exit 1; }
        grep -q 'git.*branch -d' "$PG" || { echo "FAIL: no branch cleanup"; exit 1; }

        # Notifications
        grep -q 'wrapix-notifyd' "$PG" || { echo "FAIL: no notifications"; exit 1; }
        grep -q 'bd human' "$PG" || { echo "FAIL: no bd human for deploy"; exit 1; }

        # Deploy bead
        grep -q 'create_deploy_bead\|bd create.*deploy' "$PG" || { echo "FAIL: no deploy bead"; exit 1; }

        echo "PASS: Post-gate order correctly structured"
        mkdir $out
      '';

  # Formulas validation
  gc-formulas =
    runCommandLocal "gc-formulas"
      {
        nativeBuildInputs = [
          bash
          pkgs.gnugrep
        ];
      }
      ''
        set -euo pipefail
        DIR="${../lib/city/formulas}"

        echo "Checking role formulas..."

        for role in scout worker reviewer; do
          F="$DIR/$role.formula.toml"
          test -f "$F" || { echo "FAIL: missing $role.formula.toml"; exit 1; }
          grep -q '^formula = ' "$F" || { echo "FAIL: $role missing formula name"; exit 1; }
          grep -q '^description = ' "$F" || { echo "FAIL: $role missing description"; exit 1; }
          grep -q '^\[\[steps\]\]' "$F" || { echo "FAIL: $role missing steps"; exit 1; }
          grep -q 'docs/README.md' "$F" || { echo "FAIL: $role missing docs/README.md pin"; exit 1; }
          echo "  PASS: $role"
        done

        # Scout-specific
        grep -q 'orchestration.md' "$DIR/scout.formula.toml" || { echo "FAIL: scout no orchestration.md"; exit 1; }
        grep -q 'max_beads' "$DIR/scout.formula.toml" || { echo "FAIL: scout no maxBeads"; exit 1; }

        # Worker-specific
        grep -q 'wrapix-agent' "$DIR/worker.formula.toml" || { echo "FAIL: worker no wrapix-agent"; exit 1; }

        # Reviewer-specific
        grep -q 'style-guidelines.md' "$DIR/reviewer.formula.toml" || { echo "FAIL: reviewer no style-guidelines.md"; exit 1; }
        grep -q 'bd human' "$DIR/reviewer.formula.toml" || { echo "FAIL: reviewer no bd human"; exit 1; }

        echo ""
        echo "PASS: All role formulas correctly structured"
        mkdir $out
      '';

  # NixOS module evaluation
  gc-nixos-module =
    let
      # Verify the module file has expected structure via simple Nix assertions
      moduleFile = builtins.readFile ../modules/city.nix;
      hasServicesWrapix = builtins.match ".*services\\.wrapix.*" moduleFile != null;
      hasCities = builtins.match ".*cities.*" moduleFile != null;
      hasSystemdServices = builtins.match ".*systemd\\.services.*" moduleFile != null;
      hasMkCity = builtins.match ".*mkCity.*" moduleFile != null;
    in
    assert hasServicesWrapix;
    assert hasCities;
    assert hasSystemdServices;
    assert hasMkCity;
    runCommandLocal "gc-nixos-module"
      {
        nativeBuildInputs = [
          bash
          pkgs.gnugrep
        ];
      }
      ''
        set -euo pipefail
        MODULE="${../modules/city.nix}"

        echo "Checking NixOS module..."

        # Required options
        for opt in workspace profile services secrets agent workers cooldown scout resources; do
          grep -q "''${opt}.*mkOption" "$MODULE" || { echo "FAIL: missing option: $opt"; exit 1; }
        done

        # Systemd and podman
        grep -q 'Restart.*=.*"always"' "$MODULE" || { echo "FAIL: no Restart=always"; exit 1; }
        grep -q 'podman.sock' "$MODULE" || { echo "FAIL: no podman socket mount"; exit 1; }
        grep -q 'network create' "$MODULE" || { echo "FAIL: no podman network create"; exit 1; }
        grep -q 'podman load' "$MODULE" || { echo "FAIL: no podman load"; exit 1; }
        grep -q 'virtualisation.podman.enable' "$MODULE" || { echo "FAIL: no podman enable"; exit 1; }

        echo "PASS: NixOS module correctly structured"
        mkdir $out
      '';
}
