use std::{fs, process::Command};

use serde_json::json;

type TestResult<T = ()> = Result<T, Box<dyn std::error::Error>>;

#[test]
fn invalid_network_mode_fails_before_service_or_container_start() -> TestResult {
    let root = tempfile::Builder::new()
        .prefix("invalid-network-mode")
        .tempdir()?;
    let workspace = root.path().join("workspace");
    let profile = root.path().join("profile.json");
    fs::create_dir_all(workspace.join(".beads/dolt"))?;
    let source_kind = if cfg!(target_os = "macos") {
        "docker-archive"
    } else {
        "nix-descriptor"
    };
    fs::write(
        &profile,
        serde_json::to_vec(&json!({
            "schema": 1,
            "system": "test",
            "profile": {
                "name": "base",
                "env": {},
                "mounts": [],
                "writable_dirs": [],
                "network_allowlist": []
            },
            "image": {
                "ref": "localhost/wrix-test:latest",
                "source": "/missing/image-source",
                "source_kind": source_kind,
                "digest": format!("sha256:{}", "a".repeat(64))
            },
            "agent": { "kind": "direct" },
            "resources": { "cpus": null, "memory_mb": 4096, "pids_limit": 4096 },
            "security": { "deploy_key": null },
            "services": { "beads": { "enable": "auto" }, "nix_cache": { "enable": false } }
        }))?,
    )?;

    let output = Command::new(env!("CARGO_BIN_EXE_wrix"))
        .args([
            "--profile-config",
            &profile.display().to_string(),
            "run",
            &workspace.display().to_string(),
            "true",
        ])
        .env("WRIX_NETWORK", "lan")
        .env("HOME", root.path().join("home"))
        .env_remove("WRIX_DRY_RUN")
        .output()?;

    assert!(!output.status.success());
    let stderr = String::from_utf8(output.stderr)?;
    assert!(
        stderr.contains("WRIX_NETWORK must be 'open' or 'limit'"),
        "{stderr}"
    );
    assert!(!stderr.contains("service command failed"), "{stderr}");
    assert!(!stderr.contains("command failed: podman"), "{stderr}");
    Ok(())
}
