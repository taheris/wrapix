use std::fs;

use wrix_sandbox::command::{MountMode, ProfileMount, SpawnMount, classify_darwin_mounts};

type TestResult<T = ()> = Result<T, Box<dyn std::error::Error>>;

#[test]
fn mount_classifier_handles_profile_and_spawn_mounts_uniformly() -> TestResult {
    let root = tempfile::Builder::new().prefix("darwin-mounts").tempdir()?;
    let host_dir = root.path().join("host-dir");
    let host_file = root.path().join("host-file");
    let sibling_file = root.path().join("sibling-secret");
    let staging = root.path().join("staging");
    fs::create_dir_all(&host_dir)?;
    fs::create_dir_all(&staging)?;
    fs::write(host_dir.join("payload"), "profile dir\n")?;
    fs::write(&host_file, "spawn file\n")?;
    fs::write(&sibling_file, "private\n")?;

    let profile_mounts = vec![ProfileMount {
        source: host_dir.display().to_string(),
        dest: String::from("/mnt/profile-dir"),
        mode: MountMode::Ro,
        optional: false,
    }];
    let spawn_mounts = vec![SpawnMount {
        host_path: host_file.display().to_string(),
        container_path: String::from("/etc/spawn-file"),
        read_only: true,
    }];

    let plan = classify_darwin_mounts(&profile_mounts, &spawn_mounts, &staging)?;
    assert_eq!(
        plan.dir_env().as_deref(),
        Some("/mnt/wrix/dir0:/mnt/profile-dir:ro")
    );
    assert!(staging.join("dir0/payload").is_file());
    assert_eq!(
        plan.file_env().as_deref(),
        Some("/mnt/wrix/file0/host-file:/etc/spawn-file:ro")
    );
    assert_eq!(plan.mounts.len(), 2);
    assert!(
        plan.mounts
            .iter()
            .any(|mount| mount.container == "/mnt/wrix/dir0")
    );
    let file_mount = plan
        .mounts
        .iter()
        .find(|mount| mount.container == "/mnt/wrix/file0")
        .expect("file mount should be classified");
    assert_eq!(file_mount.host, staging.join("file0").display().to_string());
    assert!(plan.mounts.iter().all(|mount| mount.read_only));
    assert_eq!(
        fs::read_dir(&file_mount.host)?
            .collect::<Result<Vec<_>, _>>()?
            .len(),
        1
    );
    assert_eq!(fs::read(staging.join("file0/host-file"))?, b"spawn file\n");
    assert!(!staging.join("file0/sibling-secret").exists());

    Ok(())
}

#[cfg(unix)]
#[test]
fn mount_classifier_rejects_unix_sockets() -> TestResult {
    use std::os::unix::net::UnixListener;

    let root = tempfile::Builder::new()
        .prefix("darwin-socket-mount")
        .tempdir()?;
    let socket_path = root.path().join("mount.sock");
    let staging = root.path().join("staging");
    fs::create_dir_all(&staging)?;
    let _listener = UnixListener::bind(&socket_path)?;

    let error = classify_darwin_mounts(
        &[],
        &[SpawnMount {
            host_path: socket_path.display().to_string(),
            container_path: String::from("/run/test.sock"),
            read_only: false,
        }],
        &staging,
    )
    .unwrap_err();
    let message = error.to_string();
    assert!(message.contains(&socket_path.display().to_string()));
    assert!(message.contains("/run/test.sock"));
    assert!(message.contains("Unix-socket mount source rejected"));
    Ok(())
}
