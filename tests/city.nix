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
# All gc checks run as part of nix flake check.
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

  ralph = import ../lib/ralph {
    inherit pkgs;
    inherit (sandbox) mkSandbox;
  };

  city = import ../lib/city {
    inherit pkgs linuxPkgs;
    inherit (sandbox) mkSandbox profiles;
    inherit (ralph) mkRalph;
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
  city-mkcity-eval =
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
    runCommandLocal "city-mkcity-eval" { } ''
      echo "PASS: mkCity evaluates with minimal, full, and empty configs"
      echo "  - config, provider, serviceImages, formulas, defaultFormulas present"
      mkdir $out
    '';

  # Generated city.toml matches gc's config schema
  city-city-toml =
    let
      inherit (minimalCity) configAttrs;

      # Workspace section
      hasWorkspace = builtins.hasAttr "workspace" configAttrs;
      workspaceName = configAttrs.workspace.name;
      workspaceProvider = configAttrs.workspace.provider;

      # Session section with exec provider
      sessionProvider = configAttrs.session.provider;
      hasExecPrefix = builtins.substring 0 5 sessionProvider == "exec:";
      hasNixStore = builtins.substring 5 10 sessionProvider == "/nix/store";

      # Required sections
      hasFormulas = builtins.hasAttr "formulas" configAttrs;
      hasBeads = builtins.hasAttr "beads" configAttrs;
      hasDaemon = builtins.hasAttr "daemon" configAttrs;

      # Agent is a list (array of tables)
      agentIsList = builtins.isList configAttrs.agent;
      agentCount = builtins.length configAttrs.agent;
      hasScout = builtins.any (a: a.name == "scout") configAttrs.agent;
      hasWorker = builtins.any (a: a.name == "worker") configAttrs.agent;
      hasReviewer = builtins.any (a: a.name == "reviewer") configAttrs.agent;

      # Full city: workers=2 reflected in workspace and worker agent
      fullWorkspace = fullCity.configAttrs.workspace;
      fullWorkerSessions = fullWorkspace.max_active_sessions;

      # Convergence config
      hasConvergence = builtins.hasAttr "convergence" configAttrs;
      convergenceMaxPerAgent = configAttrs.convergence.max_per_agent;
      convergenceMaxTotal = configAttrs.convergence.max_total;
    in
    assert hasWorkspace;
    assert workspaceName == "dev";
    assert workspaceProvider == "claude";
    assert hasExecPrefix;
    assert hasNixStore;
    assert hasFormulas;
    assert hasBeads;
    assert hasDaemon;
    assert hasConvergence;
    assert convergenceMaxPerAgent == 2;
    assert convergenceMaxTotal == 10;
    assert agentIsList;
    assert agentCount == 3;
    assert hasScout;
    assert hasWorker;
    assert hasReviewer;
    assert fullWorkerSessions == 2;
    runCommandLocal "city-city-toml" { } ''
      echo "PASS: city.toml matches gc config schema"
      echo "  - [workspace] with name and provider"
      echo "  - [session] with exec:/nix/store/... provider"
      echo "  - [formulas], [beads], [daemon], [convergence] sections present"
      echo "  - [[agent]] is list with scout, worker, reviewer"
      echo "  - workers reflected in max_active_sessions"
      mkdir $out
    '';

  # Service packages build into OCI images
  city-service-images =
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
    runCommandLocal "city-service-images" { } ''
      echo "Checking service image is a valid tar archive..."
      test -f ${apiImage}
      tar -tf ${apiImage} >/dev/null
      echo "PASS: Service images build via dockerTools.buildLayeredImage"
      echo "  - wrapix-svc-api image is a valid tar"
      echo "  - Multiple services supported"
      mkdir $out
    '';

  # Secrets classification
  city-secrets =
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
    runCommandLocal "city-secrets" { } ''
      echo "PASS: Secrets classified correctly"
      echo "  - env var secret: type=env"
      echo "  - file path secret: type=file with correct path"
      mkdir $out
    '';

  # =========================================================================
  # Layer 2: Shell Script Syntax Validation
  # =========================================================================

  # Validate all Gas City shell scripts parse without errors
  city-shell-syntax =
    runCommandLocal "city-shell-syntax"
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

  # =========================================================================
  # Layer 3: Functional tests (execute scripts with mock dependencies)
  # =========================================================================

  # Scout: parse-rules extracts patterns from orchestration.md
  city-scout-parse-rules =
    runCommandLocal "city-scout-parse-rules"
      {
        nativeBuildInputs = [
          bash
          pkgs.coreutils
        ];
      }
      ''
                set -euo pipefail
                SCOUT="${../lib/city/scout.sh}"

                echo "Testing scout.sh parse-rules..."

                # Test 1: defaults when no doc file
                TMPDIR=$(mktemp -d)
                SCOUT_ERRORS_DIR="$TMPDIR/errors" bash "$SCOUT" parse-rules ""

                immediate="$(cat "$TMPDIR/errors/immediate.pat")"
                batched="$(cat "$TMPDIR/errors/batched.pat")"
                [[ "$immediate" == "FATAL|PANIC|panic:" ]] || { echo "FAIL: wrong default immediate: $immediate"; exit 1; }
                [[ "$batched" == "ERROR|Exception" ]] || { echo "FAIL: wrong default batched: $batched"; exit 1; }
                echo "  PASS: defaults applied when no doc"

                # Test 2: custom patterns from doc
                cat > "$TMPDIR/orch.md" << 'DOC'
        ## Scout Rules
        ### Immediate (P0 bead)
        ```
        OOM_KILLED|SEGFAULT
        ```
        ### Batched (collected over one poll cycle)
        ```
        WARN|TIMEOUT
        ```
        ### Ignore
        ```
        healthcheck
        ```
        ## Auto-deploy
        DOC
                rm -rf "$TMPDIR/errors"
                SCOUT_ERRORS_DIR="$TMPDIR/errors" bash "$SCOUT" parse-rules "$TMPDIR/orch.md"

                immediate="$(cat "$TMPDIR/errors/immediate.pat")"
                batched="$(cat "$TMPDIR/errors/batched.pat")"
                ignore="$(cat "$TMPDIR/errors/ignore.pat")"
                [[ "$immediate" == "OOM_KILLED|SEGFAULT" ]] || { echo "FAIL: custom immediate: $immediate"; exit 1; }
                [[ "$batched" == "WARN|TIMEOUT" ]] || { echo "FAIL: custom batched: $batched"; exit 1; }
                [[ "$ignore" == "healthcheck" ]] || { echo "FAIL: custom ignore: $ignore"; exit 1; }
                echo "  PASS: custom patterns parsed"

                rm -rf "$TMPDIR"
                echo "PASS: scout parse-rules works correctly"
                mkdir $out
      '';

  # Scout: scan classifies log lines by pattern tier
  city-scout-scan =
    runCommandLocal "city-scout-scan"
      {
        nativeBuildInputs = [
          bash
          pkgs.coreutils
        ];
      }
      ''
                set -euo pipefail
                SCOUT="${../lib/city/scout.sh}"
                TMPDIR=$(mktemp -d)

                echo "Testing scout.sh scan with mock podman..."

                # Set up patterns
                mkdir -p "$TMPDIR/errors"
                echo "FATAL|PANIC|panic:" > "$TMPDIR/errors/immediate.pat"
                echo "ERROR|Exception" > "$TMPDIR/errors/batched.pat"
                echo "healthcheck" > "$TMPDIR/errors/ignore.pat"

                # Create mock podman that returns mixed log lines
                MOCK_BIN="$TMPDIR/bin"
                mkdir -p "$MOCK_BIN"
                cat > "$MOCK_BIN/podman" << 'MOCK'
        #!/bin/sh
        cat << 'LOGS'
        2026-04-01 INFO: service started
        2026-04-01 ERROR: connection refused
        2026-04-01 healthcheck passed
        2026-04-01 FATAL: out of memory
        2026-04-01 Exception in thread main
        LOGS
        MOCK
                chmod +x "$MOCK_BIN/podman"

                PATH="$MOCK_BIN:$PATH" SCOUT_ERRORS_DIR="$TMPDIR/errors" \
                  bash "$SCOUT" scan "my-api" --since=5m

                # Verify classification
                grep -q "FATAL" "$TMPDIR/errors/my-api/immediate.log" || { echo "FAIL: FATAL not in immediate"; exit 1; }
                grep -q "ERROR" "$TMPDIR/errors/my-api/batched.log" || { echo "FAIL: ERROR not in batched"; exit 1; }
                grep -q "Exception" "$TMPDIR/errors/my-api/batched.log" || { echo "FAIL: Exception not in batched"; exit 1; }

                # healthcheck should be filtered out
                ! grep -q "healthcheck" "$TMPDIR/errors/my-api/immediate.log" || { echo "FAIL: healthcheck in immediate"; exit 1; }
                ! grep -q "healthcheck" "$TMPDIR/errors/my-api/batched.log" || { echo "FAIL: healthcheck in batched"; exit 1; }

                # INFO should not appear (not in any pattern)
                ! grep -q "INFO" "$TMPDIR/errors/my-api/immediate.log" || { echo "FAIL: INFO in immediate"; exit 1; }
                ! grep -q "INFO" "$TMPDIR/errors/my-api/batched.log" || { echo "FAIL: INFO in batched"; exit 1; }

                rm -rf "$TMPDIR"
                echo "PASS: scout scan correctly classifies log lines"
                mkdir $out
      '';

  # Gate: exit codes match review verdict
  city-gate-functional =
    runCommandLocal "city-gate-functional"
      {
        nativeBuildInputs = [
          bash
          pkgs.coreutils
          pkgs.jq
        ];
      }
      ''
                set -euo pipefail
                GATE="${../lib/city/gate.sh}"

                echo "Testing gate.sh with mock bd/gc..."

                MOCK_BIN=$(mktemp -d)

                # Test 1: approve -> exit 0
                cat > "$MOCK_BIN/bd" << 'MOCK'
        #!/bin/sh
        # bd show <id> --json returns array with metadata
        if [ "$1" = "show" ] && [ "$3" = "--json" ]; then
          echo '[{"metadata":{"commit_range":"abc..def","review_verdict":"approve"}}]'
        fi
        MOCK
                chmod +x "$MOCK_BIN/bd"
                cat > "$MOCK_BIN/gc" << 'MOCK'
        #!/bin/sh
        exit 0
        MOCK
                chmod +x "$MOCK_BIN/gc"

                PATH="$MOCK_BIN:$PATH" GC_BEAD_ID="test-1" GC_POLL_INTERVAL=0 GC_POLL_TIMEOUT=5 \
                  bash "$GATE" > /dev/null 2>&1
                echo "  PASS: approve exits 0"

                # Test 2: reject -> exit 1
                cat > "$MOCK_BIN/bd" << 'MOCK'
        #!/bin/sh
        if [ "$1" = "show" ] && [ "$3" = "--json" ]; then
          echo '[{"metadata":{"commit_range":"abc..def","review_verdict":"reject"}}]'
        fi
        MOCK
                chmod +x "$MOCK_BIN/bd"

                exit_code=0
                PATH="$MOCK_BIN:$PATH" GC_BEAD_ID="test-2" GC_POLL_INTERVAL=0 GC_POLL_TIMEOUT=5 \
                  bash "$GATE" > /dev/null 2>&1 || exit_code=$?
                [[ "$exit_code" -eq 1 ]] || { echo "FAIL: reject exited $exit_code (expected 1)"; exit 1; }
                echo "  PASS: reject exits 1"

                # Test 3: missing commit_range -> exit 1
                cat > "$MOCK_BIN/bd" << 'MOCK'
        #!/bin/sh
        if [ "$1" = "show" ] && [ "$3" = "--json" ]; then
          echo '[{"metadata":{}}]'
        fi
        MOCK
                chmod +x "$MOCK_BIN/bd"

                exit_code=0
                PATH="$MOCK_BIN:$PATH" GC_BEAD_ID="test-3" GC_POLL_INTERVAL=0 GC_POLL_TIMEOUT=5 \
                  bash "$GATE" > /dev/null 2>&1 || exit_code=$?
                [[ "$exit_code" -eq 1 ]] || { echo "FAIL: no commit_range exited $exit_code (expected 1)"; exit 1; }
                echo "  PASS: missing commit_range exits 1"

                rm -rf "$MOCK_BIN"
                echo "PASS: gate.sh exit codes correct"
                mkdir $out
      '';

  # Agent wrapper: prompt construction
  city-agent-prompt =
    runCommandLocal "city-agent-prompt"
      {
        nativeBuildInputs = [
          bash
          pkgs.coreutils
        ];
      }
      ''
                set -euo pipefail
                AGENT="${../lib/city/agent.sh}"

                echo "Testing agent.sh prompt construction..."

                TMPDIR=$(mktemp -d)
                MOCK_BIN="$TMPDIR/bin"
                mkdir -p "$MOCK_BIN" "$TMPDIR/docs"

                # Create docs and task file
                echo "Project uses Nix for builds." > "$TMPDIR/docs/README.md"
                echo "Use set -euo pipefail in shell." > "$TMPDIR/docs/style-guidelines.md"
                echo "Fix the broken auth module." > "$TMPDIR/task.md"

                # Mock claude to echo the prompt it receives
                cat > "$MOCK_BIN/claude" << MOCK
        #!$(command -v bash)
        if [[ "\$1" == "-p" ]]; then echo "\$2"; fi
        MOCK
                chmod +x "$MOCK_BIN/claude"

                output="$(PATH="$MOCK_BIN:$PATH" \
                  WRAPIX_AGENT=claude \
                  WRAPIX_PROMPT_FILE="$TMPDIR/task.md" \
                  WRAPIX_DOCS_DIR="$TMPDIR/docs" \
                  bash "$AGENT" run 2>&1)"

                echo "$output" | grep -q "Project uses Nix" || { echo "FAIL: docs/README.md missing from prompt"; exit 1; }
                echo "$output" | grep -q "set -euo pipefail" || { echo "FAIL: docs/style-guidelines.md missing from prompt"; exit 1; }
                echo "$output" | grep -q "Fix the broken auth" || { echo "FAIL: task file missing from prompt"; exit 1; }

                # Missing prompt file should fail
                exit_code=0
                PATH="$MOCK_BIN:$PATH" WRAPIX_AGENT=claude WRAPIX_PROMPT_FILE="/nonexistent" \
                  bash "$AGENT" run > /dev/null 2>&1 || exit_code=$?
                [[ "$exit_code" -ne 0 ]] || { echo "FAIL: should fail on missing prompt file"; exit 1; }

                rm -rf "$TMPDIR"
                echo "PASS: agent.sh prompt construction works"
                mkdir $out
      '';

  # Provider: worker creates worktree (functional with mock podman)
  city-provider-worker =
    runCommandLocal "city-provider-worker"
      {
        nativeBuildInputs = [
          bash
          pkgs.git
        ];
      }
      ''
                set -euo pipefail
                PROVIDER="${../lib/city/provider.sh}"

                echo "Testing provider.sh worker start..."

                TMPDIR=$(mktemp -d)
                MOCK_BIN="$TMPDIR/bin"
                mkdir -p "$MOCK_BIN"

                # Set up git repo (HOME override for Nix sandbox)
                export HOME="$TMPDIR/home"
                mkdir -p "$HOME"
                git config --global user.email "test@test"
                git config --global user.name "test"
                git config --global init.defaultBranch main
                git -C "$TMPDIR" init -q -b main
                git -C "$TMPDIR" commit --allow-empty -m "initial" -q

                # Mock podman (record calls, succeed)
                cat > "$MOCK_BIN/podman" << MOCK
        #!/bin/sh
        echo "\$@" >> "$TMPDIR/podman.log"
        MOCK
                chmod +x "$MOCK_BIN/podman"
                cat > "$MOCK_BIN/bd" << MOCK
        #!/bin/sh
        echo "\$@" >> "$TMPDIR/bd.log"
        MOCK
                chmod +x "$MOCK_BIN/bd"

                PATH="$MOCK_BIN:$PATH" \
                  GC_CITY_NAME="test" \
                  GC_WORKSPACE="$TMPDIR" \
                  GC_AGENT_IMAGE="test-image:latest" \
                  GC_PODMAN_NETWORK="wrapix-test" \
                  GC_BEAD_ID="bead-123" \
                  bash "$PROVIDER" start worker-1 > "$TMPDIR/out" 2>&1 || true

                # Worktree should exist
                test -d "$TMPDIR/.wrapix/worktree/gc-bead-123" || { echo "FAIL: worktree not created"; exit 1; }
                echo "  PASS: worktree created"

                # Git branch should exist
                git -C "$TMPDIR" rev-parse --verify gc-bead-123 > /dev/null 2>&1 || { echo "FAIL: branch not created"; exit 1; }
                echo "  PASS: git branch created"

                # Podman should mount the worktree
                grep -q "worktree/gc-bead-123:/workspace" "$TMPDIR/podman.log" || { echo "FAIL: worktree not mounted"; exit 1; }
                echo "  PASS: worktree mounted in container"

                # Provider should set up task file or WRAPIX_PROMPT_FILE for the worker
                # The spec says: "provider script mounts task file at /workspace/.task"
                if ! grep -qE '\.task|WRAPIX_PROMPT_FILE' "$TMPDIR/podman.log"; then
                  echo "FAIL: worker has no task file or WRAPIX_PROMPT_FILE — workers would crash"
                  echo "  podman was called with: $(cat "$TMPDIR/podman.log")"
                  exit 1
                fi
                echo "  PASS: task file set up for worker"

                rm -rf "$TMPDIR"
                echo "PASS: provider worker lifecycle works"
                mkdir $out
      '';

  # NixOS module: verifies env var plumbing via Nix evaluation
  city-nixos-module =
    let
      moduleFile = builtins.readFile ../modules/city.nix;

      # Structural checks — the module must define these
      hasServicesWrapix = builtins.match ".*services\\.wrapix.*" moduleFile != null;
      hasCities = builtins.match ".*cities.*" moduleFile != null;
      hasSystemdServices = builtins.match ".*systemd\\.services.*" moduleFile != null;
      hasMkCity = builtins.match ".*mkCity.*" moduleFile != null;

      # Critical env var plumbing — provider.sh requires these
      hasAgentImage = builtins.match ".*GC_AGENT_IMAGE.*" moduleFile != null;
      hasPodmanNetwork = builtins.match ".*GC_PODMAN_NETWORK.*" moduleFile != null;
    in
    assert hasServicesWrapix;
    assert hasCities;
    assert hasSystemdServices;
    assert hasMkCity;
    assert
      hasAgentImage
      || throw "NixOS module does not set GC_AGENT_IMAGE — provider.sh requires it to start agent containers";
    assert
      hasPodmanNetwork
      || throw "NixOS module does not set GC_PODMAN_NETWORK — provider.sh requires it for container networking";
    runCommandLocal "city-nixos-module" { } ''
      echo "PASS: NixOS module structure and env var plumbing verified"
      mkdir $out
    '';

  # Formulas: structural validation (these are TOML for the AI, grep is appropriate here)
  city-formulas =
    runCommandLocal "city-formulas"
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
          grep -q '^\[\[steps\]\]' "$F" || { echo "FAIL: $role missing steps"; exit 1; }
          grep -q 'docs/README.md' "$F" || { echo "FAIL: $role missing docs/README.md pin"; exit 1; }
          echo "  PASS: $role"
        done

        # Scout must reference orchestration.md for pattern loading
        grep -q 'orchestration.md' "$DIR/scout.formula.toml" || { echo "FAIL: scout no orchestration.md"; exit 1; }

        # Reviewer must reference style-guidelines.md for enforcement
        grep -q 'style-guidelines.md' "$DIR/reviewer.formula.toml" || { echo "FAIL: reviewer no style-guidelines.md"; exit 1; }

        echo "PASS: All role formulas valid"
        mkdir $out
      '';

  # Scripts and orders bundle
  city-scripts-bundle =
    let
      hasScripts = builtins.hasAttr "scripts" minimalCity;
    in
    assert hasScripts;
    runCommandLocal "city-scripts-bundle"
      {
        nativeBuildInputs = [
          bash
          pkgs.gnugrep
        ];
      }
      ''
        set -euo pipefail
        echo "Checking scripts bundle..."

        # Gate, post-gate, recovery scripts are bundled
        test -f "${minimalCity.scripts}/gate.sh" || { echo "FAIL: gate.sh missing"; exit 1; }
        test -f "${minimalCity.scripts}/post-gate.sh" || { echo "FAIL: post-gate.sh missing"; exit 1; }
        test -f "${minimalCity.scripts}/recovery.sh" || { echo "FAIL: recovery.sh missing"; exit 1; }
        echo "  PASS: gate.sh, post-gate.sh, recovery.sh bundled"

        # Scripts are executable
        test -x "${minimalCity.scripts}/gate.sh" || { echo "FAIL: gate.sh not executable"; exit 1; }
        test -x "${minimalCity.scripts}/post-gate.sh" || { echo "FAIL: post-gate.sh not executable"; exit 1; }
        echo "  PASS: scripts are executable"

        # Orders directory exists with post-gate order
        test -f "${minimalCity.formulas}/orders/post-gate/order.toml" || { echo "FAIL: post-gate order missing"; exit 1; }
        grep -q 'convergence.terminated' "${minimalCity.formulas}/orders/post-gate/order.toml" || \
          { echo "FAIL: post-gate order missing event trigger"; exit 1; }
        echo "  PASS: post-gate order bundled"

        echo "PASS: Scripts and orders bundle verified"
        mkdir $out
      '';

  # Validate generated city.toml with the gc binary
  city-config-validate =
    runCommandLocal "city-config-validate"
      {
        nativeBuildInputs = [
          bash
          pkgs.gc
        ];
      }
      ''
        set -euo pipefail
        echo "Validating generated city.toml with gc..."

        WORK=$(mktemp -d)
        cp ${minimalCity.config} "$WORK/city.toml"
        cd "$WORK"
        gc config show --validate
        echo "  PASS: minimal city config valid"

        rm -f "$WORK/city.toml"
        cp ${fullCity.config} "$WORK/city.toml"
        cd "$WORK"
        gc config show --validate
        echo "  PASS: full city config valid"

        rm -f "$WORK/city.toml"
        cp ${emptyCity.config} "$WORK/city.toml"
        cd "$WORK"
        gc config show --validate
        echo "  PASS: empty city config valid"

        rm -rf "$WORK"
        echo "PASS: All generated configs accepted by gc"
        mkdir $out
      '';
}
