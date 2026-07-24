mod common;

use std::{fs, path::Path, path::PathBuf, process::Command, time::SystemTime};

use common::{
    TestResult, assert_not_contains, assert_success_with_clean_stderr, common_git_dir, mode,
    run_command, setup_committed_repo, write_fake_gh, write_online_success_git, write_prek_hooks,
    wrix_command_with_path,
};

#[test]
fn repeated_init_does_not_churn_managed_state() -> TestResult {
    let fixture = tempfile::Builder::new()
        .prefix("wrix-init-idempotency")
        .tempdir()?;
    let repo = setup_committed_repo("idempotent-init", true)?;
    let home = fixture.path().join("home");
    let fake_git = write_online_success_git(&fixture.path().join("fake-git"))?;
    let gh_state = fixture.path().join("gh-state");
    let gh_log = fixture.path().join("gh.log");
    let fake_gh = write_fake_gh(&fixture.path().join("fake-gh"), &gh_state, &gh_log)?;
    let hooks = write_prek_hooks(&fixture.path().join("hooks"))?;
    let args = ["--deploy", "--key", "stable-key"];

    let first = run_init(repo.path(), &home, &fake_git, &fake_gh, &hooks, &args)?;
    assert_success_with_clean_stderr(&first);
    let snapshots = managed_paths(repo.path(), &home)?
        .into_iter()
        .map(FileSnapshot::read)
        .collect::<TestResult<Vec<_>>>()?;
    fs::write(&gh_log, "")?;
    std::thread::sleep(std::time::Duration::from_millis(20));

    let second = run_init(repo.path(), &home, &fake_git, &fake_gh, &hooks, &args)?;

    assert_success_with_clean_stderr(&second);
    for snapshot in snapshots {
        snapshot.assert_unchanged()?;
    }
    let log = fs::read_to_string(&gh_log)?;
    assert_not_contains("repeated init GitHub calls", &log, "POST");
    assert_not_contains("repeated init GitHub calls", &log, "DELETE");
    Ok(())
}

struct FileSnapshot {
    path: PathBuf,
    content: Vec<u8>,
    modified: SystemTime,
    mode: u32,
}

impl FileSnapshot {
    fn read(path: PathBuf) -> TestResult<Self> {
        let metadata = fs::metadata(&path)?;
        Ok(Self {
            content: fs::read(&path)?,
            modified: metadata.modified()?,
            mode: mode(&path)?,
            path,
        })
    }

    fn assert_unchanged(self) -> TestResult {
        let metadata = fs::metadata(&self.path)?;
        assert_eq!(
            fs::read(&self.path)?,
            self.content,
            "managed content changed: {}",
            self.path.display(),
        );
        assert_eq!(
            metadata.modified()?,
            self.modified,
            "managed file was rewritten: {}",
            self.path.display(),
        );
        assert_eq!(
            mode(&self.path)?,
            self.mode,
            "managed mode changed: {}",
            self.path.display(),
        );
        Ok(())
    }
}

fn managed_paths(repo: &Path, home: &Path) -> TestResult<Vec<PathBuf>> {
    let common_dir = common_git_dir(repo)?;
    let key_dir = home.join(".ssh/deploy_keys");
    Ok(vec![
        common_dir.join("config"),
        common_dir.join("wrix/git-ssh"),
        common_dir.join("wrix/github_known_hosts"),
        common_dir.join("wrix/allowed_signers"),
        key_dir.join("stable-key"),
        key_dir.join("stable-key.pub"),
        key_dir.join("stable-key-signing"),
        key_dir.join("stable-key-signing.pub"),
    ])
}

fn run_init(
    repo: &Path,
    home: &Path,
    fake_git: &Path,
    fake_gh: &Path,
    hooks: &Path,
    args: &[&str],
) -> TestResult<common::RunResult> {
    let mut command = init_command(repo, home, fake_git, fake_gh, hooks)?;
    command.arg("init").args(args);
    run_command(&mut command)
}

fn init_command(
    repo: &Path,
    home: &Path,
    fake_git: &Path,
    fake_gh: &Path,
    hooks: &Path,
) -> TestResult<Command> {
    let mut command = wrix_command_with_path(repo, &[fake_gh, fake_git])?;
    command
        .env("HOME", home)
        .env("WRIX_PREK_HOOKS", hooks)
        .env_remove("WRIX_DEPLOY_KEY")
        .env_remove("WRIX_SIGNING_KEY");
    Ok(command)
}
