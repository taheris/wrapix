mod common;

use std::process::Command;

use common::{
    TestResult, assert_contains, assert_success_with_clean_stderr, run_command,
    setup_committed_repo, write_capturing_git, write_capturing_ssh, write_fake_gh, write_fake_ssh,
    write_logging_ssh_keygen, write_online_success_git, write_tracing_git,
};

#[test]
fn command_fixtures_have_expected_observable_contract() -> TestResult {
    let fixture = tempfile::Builder::new()
        .prefix("wrix-init-command-fixtures")
        .tempdir()?;
    let source_repo = setup_committed_repo("wrix-init-command-fixtures-source", false)?;
    let fake_git = write_online_success_git(&fixture.path().join("fake-git"))?;
    let tracing_git_capture = fixture.path().join("tracing-git-capture");
    let tracing_git = write_tracing_git(&fixture.path().join("tracing-git"), &tracing_git_capture)?;
    let capturing_mode = fixture.path().join("capturing-git-mode");
    let capturing_dir = fixture.path().join("capturing-git-capture");
    let capturing_git = write_capturing_git(
        &fixture.path().join("capturing-git"),
        &capturing_mode,
        &capturing_dir,
    )?;
    let capturing_ssh_mode = fixture.path().join("capturing-ssh-mode");
    let capturing_ssh_dir = fixture.path().join("capturing-ssh-capture");
    let capturing_ssh = write_capturing_ssh(
        &fixture.path().join("capturing-ssh"),
        &capturing_ssh_mode,
        &capturing_ssh_dir,
    )?;
    let gh_state = fixture.path().join("gh-state");
    let gh_log = fixture.path().join("gh.log");
    let fake_gh = write_fake_gh(&fixture.path().join("fake-gh"), &gh_state, &gh_log)?;
    let ssh_keygen_log = fixture.path().join("ssh-keygen.log");
    let fake_ssh_keygen =
        write_logging_ssh_keygen(&fixture.path().join("fake-ssh-keygen"), &ssh_keygen_log)?;
    let fake_ssh = write_fake_ssh(&fixture.path().join("fake-ssh"))?;

    let real_git = run_command(Command::new("git").arg("--version"))?;
    let fake_git_version = run_command(Command::new(fake_git.join("git")).arg("--version"))?;
    assert_success_with_clean_stderr(&real_git);
    assert_success_with_clean_stderr(&fake_git_version);
    assert_eq!(fake_git_version.stdout, real_git.stdout);

    let fake_ls_remote = run_command(
        Command::new(fake_git.join("git"))
            .arg("ls-remote")
            .arg("origin")
            .arg("HEAD"),
    )?;
    assert_success_with_clean_stderr(&fake_ls_remote);
    assert_contains(
        "fake ls-remote",
        &fake_ls_remote.stdout,
        "0123456789012345678901234567890123456789\tHEAD",
    );

    let tracing_ls_remote = run_command(
        Command::new(tracing_git.join("git"))
            .arg("ls-remote")
            .arg(source_repo.path())
            .arg("HEAD"),
    )?;
    assert_success_with_clean_stderr(&tracing_ls_remote);
    assert_contains("tracing git output", &tracing_ls_remote.stdout, "HEAD");
    assert_eq!(
        std::fs::read_to_string(tracing_git_capture.join("args"))?,
        format!("ls-remote\n{}\nHEAD\n", source_repo.path().display()),
    );

    std::fs::write(&capturing_mode, "success\n")?;
    let capturing_ls_remote = run_command(
        Command::new(capturing_git.join("git"))
            .arg("ls-remote")
            .arg("origin")
            .arg("HEAD"),
    )?;
    assert_success_with_clean_stderr(&capturing_ls_remote);
    assert_contains(
        "capturing fake ls-remote",
        &capturing_ls_remote.stdout,
        "0123456789012345678901234567890123456789\tHEAD",
    );
    assert_contains(
        "capturing fake args",
        &std::fs::read_to_string(capturing_dir.join("args"))?,
        "ls-remote\norigin\nHEAD",
    );

    std::fs::write(&capturing_ssh_mode, "auth\n")?;
    let capturing_ssh_result = run_command(
        Command::new(capturing_ssh.join("ssh"))
            .arg("git@github.com")
            .arg("git-upload-pack 'example/fixture.git'"),
    )?;
    assert!(!capturing_ssh_result.status.success());
    assert_contains(
        "capturing fake ssh auth failure",
        &capturing_ssh_result.stderr,
        "Permission denied (publickey)",
    );
    assert_contains(
        "capturing fake ssh args",
        &std::fs::read_to_string(capturing_ssh_dir.join("args"))?,
        "git-upload-pack 'example/fixture.git'",
    );

    let fake_gh_create = run_command(
        Command::new(fake_gh.join("gh"))
            .arg("api")
            .arg("--method")
            .arg("POST")
            .arg("repos/example/fixture/keys")
            .arg("--raw-field")
            .arg("title=fixture-key")
            .arg("--raw-field")
            .arg("key=ssh-ed25519 AAAAFIXTURE")
            .arg("--field")
            .arg("read_only=false"),
    )?;
    assert_success_with_clean_stderr(&fake_gh_create);
    let fake_gh_list = run_command(
        Command::new(fake_gh.join("gh"))
            .arg("api")
            .arg("--method")
            .arg("GET")
            .arg("repos/example/fixture/keys?per_page=100"),
    )?;
    assert_success_with_clean_stderr(&fake_gh_list);
    assert_contains("fake gh list", &fake_gh_list.stdout, "fixture-key");
    assert_contains("fake gh list", &fake_gh_list.stdout, "\"read_only\":false");
    assert_contains(
        "fake gh log",
        &std::fs::read_to_string(&gh_log)?,
        "POST repos/example/fixture/keys",
    );

    let fixture_key = fixture.path().join("ssh-keygen-fixture-key");
    let fake_ssh_keygen_output = run_command(
        Command::new(fake_ssh_keygen.join("ssh-keygen"))
            .arg("-q")
            .arg("-t")
            .arg("ed25519")
            .arg("-N")
            .arg("")
            .arg("-f")
            .arg(&fixture_key),
    )?;
    assert_success_with_clean_stderr(&fake_ssh_keygen_output);
    assert!(fixture_key.is_file(), "fake ssh-keygen did not delegate");
    assert_contains(
        "fake ssh-keygen log",
        &std::fs::read_to_string(&ssh_keygen_log)?,
        "-t\ned25519",
    );

    let capture = fixture.path().join("ssh.args");
    let fake_ssh_output = run_command(
        Command::new(fake_ssh.join("ssh"))
            .arg("-G")
            .arg("github.com")
            .env("WRIX_TEST_CAPTURE", &capture),
    )?;
    assert_success_with_clean_stderr(&fake_ssh_output);
    assert_eq!(std::fs::read_to_string(capture)?, "-G\ngithub.com\n");

    Ok(())
}
