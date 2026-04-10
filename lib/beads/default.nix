{
  pkgs,
  linuxPkgs ? pkgs,
}:

let
  inherit (pkgs) lib;

  # Runtime tools beads-dolt shells out to. Baked into the script's PATH so
  # consumers (devShell, tests, live gc daemon) don't have to know.
  # No dolt here — all dolt calls happen inside the container so host dolt
  # never touches the data dir (avoids host /tmp leaking into noms state).
  cliRuntimePath = lib.makeBinPath (
    with pkgs;
    [
      coreutils
      bashInteractive
    ]
  );

  # Minimal dolt-only container image used to serve a workspace's .beads/dolt.
  doltImageDrv =
    (
      if pkgs.stdenv.isDarwin then
        linuxPkgs.dockerTools.buildLayeredImage
      else
        linuxPkgs.dockerTools.streamLayeredImage
    )
      {
        name = "wrapix-beads-dolt";
        tag = "latest";
        maxLayers = 10;
        contents = with linuxPkgs; [
          dolt
          bashInteractive
          coreutils
          dockerTools.caCertificates
        ];
        config = {
          Env = [ "PATH=/bin:/usr/bin" ];
        };
      };

  imageName = "localhost/wrapix-beads-dolt:latest";

  loadImageCmd = if pkgs.stdenv.isDarwin then "cat ${doltImageDrv}" else "${doltImageDrv}";

  # Host CLI: manages the per-workspace dolt container.
  #
  # Container name and listening port are derived from sha256(workspace path)
  # so two checkouts of the same repo at different paths get separate
  # containers and ports, and repeated invocations from the same workspace
  # reuse the same container.
  beadsDolt = pkgs.writeShellScriptBin "beads-dolt" ''
    set -euo pipefail

    # Self-contained runtime: dolt (for user grant), bash for /dev/tcp,
    # coreutils for basic tools. Prepended so we don't rely on host PATH.
    export PATH="${cliRuntimePath}:''${PATH:-}"

    IMAGE="${imageName}"

    _hash() {
      printf '%s' "''${1:-$PWD}" | sha256sum | cut -c1-8
    }

    _name() {
      echo "beads-$(_hash "''${1:-$PWD}")"
    }

    # Port in [13306, 13805]. 500 slots is plenty for any realistic dev host.
    _port() {
      local h
      h=$(_hash "''${1:-$PWD}")
      printf '%d\n' $((13306 + 16#$h % 500))
    }

    _load_image() {
      if podman image exists "$IMAGE" 2>/dev/null; then
        return 0
      fi
      echo "Loading beads-dolt image..." >&2
      ${loadImageCmd} | podman load -q >/dev/null
    }

    cmd_name() { _name "''${1:-$PWD}"; }
    cmd_port() { _port "''${1:-$PWD}"; }

    cmd_status() {
      local ws="''${1:-$PWD}"
      local name port
      name=$(_name "$ws")
      port=$(_port "$ws")
      echo "workspace: $ws"
      echo "container: $name"
      echo "port:      $port"
      echo "state:     $(podman inspect --format '{{.State.Status}}' "$name" 2>/dev/null || echo 'not found')"
    }

    _ensure_network() {
      if podman network exists wrapix-dolt; then
        return 0
      fi
      # Tolerate a race: a concurrent caller may have created it between
      # our exists check and our own create.
      if podman network create wrapix-dolt >/dev/null 2>&1; then
        return 0
      fi
      podman network exists wrapix-dolt
    }

    cmd_start() {
      local ws="''${1:-$PWD}"
      local name port data_dir
      name=$(_name "$ws")
      port=$(_port "$ws")
      data_dir="$ws/.beads/dolt"

      if [ ! -d "$data_dir" ]; then
        echo "beads-dolt: no .beads/dolt directory at $ws — nothing to serve" >&2
        return 2
      fi

      if podman container exists "$name"; then
        if podman inspect --format '{{.State.Running}}' "$name" | grep -q true \
           && bash -c "echo > /dev/tcp/127.0.0.1/$port" 2>/dev/null; then
          return 0
        fi
        podman rm -f "$name" >/dev/null
      fi

      _load_image

      # Drop stale noms locks and dolt's stashed temp file references.
      # Absolute /tmp paths stashed by a previous dolt process will not
      # resolve inside the container's tmpfs, breaking sql-server startup.
      find "$data_dir" -name LOCK -delete
      find "$data_dir" -type d \( -name temptf -o -name tmp \) \
        -exec sh -c 'rm -rf "$1"/* "$1"/.[!.]* 2>/dev/null || true' _ {} \;

      # Drop privileges.db so dolt reinitializes root@% with DOLT_ROOT_HOST=%.
      # Dolt skips root-user creation when privileges.db already exists
      # (server.go:478). A prior run from gc's embedded dolt (or anything
      # that didn't set DOLT_ROOT_HOST) leaves root@localhost here, which
      # locks out TCP clients coming from 10.89.x.x on the podman network.
      # bd is single-user (root) so there's no privilege state worth keeping.
      rm -f "$data_dir/.doltcfg/privileges.db"

      # Named bridge network so `podman network connect` works later.
      # Rootless podman's default (pasta) rejects multi-network attach.
      _ensure_network

      # Inside the container, force dolt temp files under .dolt/temptf
      # (not /tmp), run the server, then grant root@% over the network.
      # Host dolt never touches the data dir — avoids host /tmp leaking
      # into noms state.
      # HOME points at a tmpfs path distinct from the data dir: dolt writes
      # its user config (eventsData/, config_global.json, tmp/) under
      # $HOME/.dolt. Co-locating that with the data dir made dolt observe a
      # spurious incomplete .dolt/ at the data-dir root and abort database
      # discovery. --data-dir makes the mount unambiguously the multi-db root.
      podman run -d \
        --name "$name" \
        --entrypoint "" \
        --network wrapix-dolt \
        --userns=keep-id \
        -e HOME=/tmp/dolthome \
        -e DOLT_FORCE_LOCAL_TEMP_FILES=1 \
        -e DOLT_ROOT_HOST="%" \
        --tmpfs /tmp:rw,mode=1777 \
        -p "127.0.0.1:$port:$port" \
        -v "$data_dir:/data:rw" \
        "$IMAGE" \
        bash -c '
          set -e
          mkdir -p /tmp/dolthome
          exec dolt sql-server --data-dir /data -H 0.0.0.0 -P "$1"
        ' -- "$port" \
        >/dev/null

      local retries=50
      while [ $retries -gt 0 ]; do
        if bash -c "echo > /dev/tcp/127.0.0.1/$port" 2>/dev/null; then
          return 0
        fi
        sleep 0.2
        retries=$((retries - 1))
      done

      echo "beads-dolt: container did not become ready" >&2
      podman logs "$name" 2>&1 | tail -10 >&2
      return 1
    }

    cmd_stop() {
      local ws="''${1:-$PWD}"
      local name
      name=$(_name "$ws")
      if podman container exists "$name"; then
        podman rm -f "$name" >/dev/null
      fi
    }

    cmd_attach() {
      local network="''${1:?beads-dolt attach requires a network name}"
      local ws="''${2:-$PWD}"
      local name
      name=$(_name "$ws")

      if ! podman container exists "$name"; then
        echo "beads-dolt attach: container $name does not exist — run 'beads-dolt start' first" >&2
        return 1
      fi

      if podman inspect "$name" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
         | grep -qw "$network"; then
        return 0
      fi
      podman network connect "$network" "$name"
    }

    case "''${1:-}" in
      start)  shift; cmd_start "$@" ;;
      stop)   shift; cmd_stop "$@" ;;
      status) shift; cmd_status "$@" ;;
      port)   shift; cmd_port "$@" ;;
      name)   shift; cmd_name "$@" ;;
      attach) shift; cmd_attach "$@" ;;
      *)
        echo "Usage: beads-dolt {start|stop|status|port|name|attach <network>} [workspace]" >&2
        exit 2
        ;;
    esac
  '';

  beadsPush = pkgs.writeShellScriptBin "beads-push" (builtins.readFile ../../scripts/beads-push);

  # Shell hook fragment: ensures per-workspace dolt is running and exports
  # the env that suppresses bd's embedded autostart. No-op if the current
  # directory isn't a beads workspace or podman isn't available.
  shellHook = ''
    if [ -d "$PWD/.beads/dolt" ] && command -v podman >/dev/null 2>&1; then
      if ${beadsDolt}/bin/beads-dolt start "$PWD" >/dev/null 2>&1; then
        export BEADS_DOLT_SERVER_HOST=127.0.0.1
        BEADS_DOLT_SERVER_PORT=$(${beadsDolt}/bin/beads-dolt port "$PWD")
        export BEADS_DOLT_SERVER_PORT
        export BEADS_DOLT_AUTO_START=0
      else
        echo "warning: beads-dolt failed to start for $PWD — bd will fall back to embedded autostart" >&2
      fi
    fi
  '';

in
{
  image = doltImageDrv;
  inherit imageName shellHook;
  cli = beadsDolt;
  push = beadsPush;
}
