//! Tmux command execution
//!
//! This module handles all tmux command execution for the MCP server.
//! It manages a single tmux session and provides methods for pane lifecycle management.

use std::io;
use std::process::{Command, Output};

/// Error type for tmux operations
#[derive(Debug)]
pub enum TmuxError {
    /// Tmux command execution failed
    CommandFailed { command: String, stderr: String },
    /// Session does not exist
    SessionNotFound(String),
    /// Window/pane not found
    WindowNotFound(String),
    /// IO error during command execution
    IoError(io::Error),
}

impl std::fmt::Display for TmuxError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TmuxError::CommandFailed { command, stderr } => {
                write!(f, "Tmux command '{}' failed: {}", command, stderr)
            }
            TmuxError::SessionNotFound(name) => {
                write!(f, "Tmux session '{}' not found", name)
            }
            TmuxError::WindowNotFound(name) => {
                write!(f, "Tmux window '{}' not found. Use tmux_list_panes to see active panes.", name)
            }
            TmuxError::IoError(e) => write!(f, "IO error: {}", e),
        }
    }
}

impl std::error::Error for TmuxError {}

impl From<io::Error> for TmuxError {
    fn from(e: io::Error) -> Self {
        TmuxError::IoError(e)
    }
}

/// Result type for tmux operations
pub type TmuxResult<T> = Result<T, TmuxError>;

/// Trait for executing tmux commands, allowing for mocking in tests
pub trait CommandExecutor: Send + Sync {
    fn execute(&self, args: &[&str]) -> io::Result<Output>;
}

/// Real command executor that runs actual tmux commands
#[derive(Default)]
pub struct RealExecutor;

impl CommandExecutor for RealExecutor {
    fn execute(&self, args: &[&str]) -> io::Result<Output> {
        Command::new("tmux").args(args).output()
    }
}

/// Manages a tmux session for the MCP server
pub struct TmuxSession<E: CommandExecutor = RealExecutor> {
    /// Session name (debug-{pid})
    session_name: String,
    /// Whether the session has been created
    session_created: bool,
    /// Command executor (for testability)
    executor: E,
    /// Terminal width for new sessions
    width: u32,
    /// Terminal height for new sessions
    height: u32,
}

impl TmuxSession<RealExecutor> {
    /// Create a new TmuxSession with default executor
    pub fn new() -> Self {
        Self::with_executor(RealExecutor)
    }
}

impl Default for TmuxSession<RealExecutor> {
    fn default() -> Self {
        Self::new()
    }
}

impl<E: CommandExecutor> TmuxSession<E> {
    /// Create a new TmuxSession with a custom executor (for testing)
    pub fn with_executor(executor: E) -> Self {
        let pid = std::process::id();
        Self {
            session_name: format!("debug-{}", pid),
            session_created: false,
            executor,
            width: 200,
            height: 50,
        }
    }

    /// Get the session name
    pub fn session_name(&self) -> &str {
        &self.session_name
    }

    /// Check if the session has been created
    pub fn is_created(&self) -> bool {
        self.session_created
    }

    /// Execute a tmux command and return the output
    fn run_tmux(&self, args: &[&str]) -> TmuxResult<String> {
        let output = self.executor.execute(args)?;

        if output.status.success() {
            Ok(String::from_utf8_lossy(&output.stdout).to_string())
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr).to_string();
            let command = format!("tmux {}", args.join(" "));

            // Check for specific error conditions
            if stderr.contains("session not found") || stderr.contains("no server running") {
                Err(TmuxError::SessionNotFound(self.session_name.clone()))
            } else if stderr.contains("can't find window")
                || stderr.contains("window not found")
                || stderr.contains("no such window")
            {
                // Extract window name from args if possible
                let window_name = args
                    .iter()
                    .find(|a| a.starts_with(&format!("{}:", self.session_name)))
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| "unknown".to_string());
                Err(TmuxError::WindowNotFound(window_name))
            } else {
                Err(TmuxError::CommandFailed { command, stderr })
            }
        }
    }

    /// Create the tmux session if it doesn't exist
    fn ensure_session(&mut self) -> TmuxResult<()> {
        if self.session_created {
            return Ok(());
        }

        // Create session with specified dimensions
        // -d: detached, -s: session name, -x: width, -y: height
        let width = self.width.to_string();
        let height = self.height.to_string();
        self.run_tmux(&[
            "new-session",
            "-d",
            "-s",
            &self.session_name,
            "-x",
            &width,
            "-y",
            &height,
        ])?;

        // Configure remain-on-exit so panes stay after process exits
        self.run_tmux(&[
            "set-option",
            "-t",
            &self.session_name,
            "remain-on-exit",
            "on",
        ])?;

        self.session_created = true;
        Ok(())
    }

    /// Create a new pane running the given command
    ///
    /// Returns the window/pane name that can be used to reference it
    pub fn create_pane(&mut self, command: &str, name: &str) -> TmuxResult<String> {
        self.ensure_session()?;

        // Create a new window with the given name
        let target = format!("{}:{}", self.session_name, name);
        self.run_tmux(&["new-window", "-t", &self.session_name, "-n", name])?;

        // Set remain-on-exit for this window so pane stays after process exits
        // Note: session-level remain-on-exit doesn't apply to windows created after it's set
        self.run_tmux(&["set-option", "-t", &target, "remain-on-exit", "on"])?;

        // Send the command to the window
        self.run_tmux(&["send-keys", "-t", &target, command, "Enter"])?;

        Ok(name.to_string())
    }

    /// Send keystrokes to a pane
    pub fn send_keys(&self, pane_id: &str, keys: &str) -> TmuxResult<()> {
        let target = format!("{}:{}", self.session_name, pane_id);
        self.run_tmux(&["send-keys", "-t", &target, keys])?;
        Ok(())
    }

    /// Capture output from a pane
    ///
    /// Returns the captured text. The `lines` parameter controls how many
    /// lines of history to capture (negative start value).
    pub fn capture_pane(&self, pane_id: &str, lines: i32) -> TmuxResult<String> {
        let target = format!("{}:{}", self.session_name, pane_id);
        // -p: print to stdout, -S: start line (negative = history)
        let start = format!("-{}", lines);
        let output = self.run_tmux(&["capture-pane", "-t", &target, "-p", "-S", &start])?;
        Ok(output)
    }

    /// Kill a pane/window
    pub fn kill_pane(&self, pane_id: &str) -> TmuxResult<()> {
        let target = format!("{}:{}", self.session_name, pane_id);
        self.run_tmux(&["kill-window", "-t", &target])?;
        Ok(())
    }

    /// List all windows in the session
    ///
    /// Returns a list of (window_name, pane_pid, pane_dead) tuples
    pub fn list_windows(&self) -> TmuxResult<Vec<WindowInfo>> {
        if !self.session_created {
            return Ok(Vec::new());
        }

        // Format: #{window_name}|#{pane_pid}|#{pane_dead}
        let format = "#{window_name}|#{pane_pid}|#{pane_dead}";
        let output = self.run_tmux(&[
            "list-windows",
            "-t",
            &self.session_name,
            "-F",
            format,
        ])?;

        let windows = output
            .lines()
            .filter(|line| !line.is_empty())
            .filter_map(|line| {
                let parts: Vec<&str> = line.split('|').collect();
                if parts.len() >= 3 {
                    let name = parts[0].to_string();
                    let pid = parts[1].parse::<u32>().ok();
                    let is_dead = parts[2] == "1";
                    Some(WindowInfo {
                        name,
                        pid,
                        is_dead,
                    })
                } else {
                    None
                }
            })
            .collect();

        Ok(windows)
    }

    /// Get info about a specific window
    pub fn get_window_info(&self, pane_id: &str) -> TmuxResult<WindowInfo> {
        let target = format!("{}:{}", self.session_name, pane_id);
        let format = "#{window_name}|#{pane_pid}|#{pane_dead}";
        let output = self.run_tmux(&[
            "list-windows",
            "-t",
            &target,
            "-F",
            format,
        ])?;

        output
            .lines()
            .next()
            .and_then(|line| {
                let parts: Vec<&str> = line.split('|').collect();
                if parts.len() >= 3 {
                    let name = parts[0].to_string();
                    let pid = parts[1].parse::<u32>().ok();
                    let is_dead = parts[2] == "1";
                    Some(WindowInfo {
                        name,
                        pid,
                        is_dead,
                    })
                } else {
                    None
                }
            })
            .ok_or_else(|| TmuxError::WindowNotFound(pane_id.to_string()))
    }

    /// Kill the entire session (cleanup)
    pub fn kill_session(&mut self) -> TmuxResult<()> {
        if !self.session_created {
            return Ok(());
        }

        // Ignore errors - session might already be gone
        let _ = self.run_tmux(&["kill-session", "-t", &self.session_name]);
        self.session_created = false;
        Ok(())
    }
}

impl<E: CommandExecutor> Drop for TmuxSession<E> {
    fn drop(&mut self) {
        // Best effort cleanup - ignore errors
        let _ = self.kill_session();
    }
}

/// Information about a tmux window
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WindowInfo {
    /// Window name (used as pane_id)
    pub name: String,
    /// Process ID running in the pane (if available)
    pub pid: Option<u32>,
    /// Whether the pane's process has exited
    pub is_dead: bool,
}

impl WindowInfo {
    /// Get the status as a string ("running" or "exited")
    pub fn status(&self) -> &'static str {
        if self.is_dead {
            "exited"
        } else {
            "running"
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::rc::Rc;

    /// Mock executor that records commands and returns predefined outputs
    struct MockExecutor {
        calls: Rc<RefCell<Vec<Vec<String>>>>,
        responses: Rc<RefCell<Vec<io::Result<Output>>>>,
    }

    impl MockExecutor {
        fn new() -> Self {
            Self {
                calls: Rc::new(RefCell::new(Vec::new())),
                responses: Rc::new(RefCell::new(Vec::new())),
            }
        }

        fn with_responses(responses: Vec<io::Result<Output>>) -> Self {
            Self {
                calls: Rc::new(RefCell::new(Vec::new())),
                responses: Rc::new(RefCell::new(responses)),
            }
        }

        fn get_calls(&self) -> Vec<Vec<String>> {
            self.calls.borrow().clone()
        }

        fn success_output(stdout: &str) -> Output {
            Output {
                status: std::process::ExitStatus::default(),
                stdout: stdout.as_bytes().to_vec(),
                stderr: Vec::new(),
            }
        }
    }

    // Note: CommandExecutor requires Send + Sync, but RefCell is not Sync.
    // For single-threaded tests, we use a simpler approach.
    // In a real scenario, we'd use parking_lot::Mutex or similar.
    // For these unit tests, we'll use a different mock strategy.

    /// Simpler mock that doesn't require interior mutability
    #[derive(Default)]
    struct StaticMockExecutor {
        // For testing, we'll make the responses static
    }

    impl CommandExecutor for StaticMockExecutor {
        fn execute(&self, args: &[&str]) -> io::Result<Output> {
            // Return success for most commands
            let stdout = match args.first() {
                Some(&"new-session") => "",
                Some(&"set-option") => "",
                Some(&"new-window") => "",
                Some(&"send-keys") => "",
                Some(&"kill-window") => "",
                Some(&"kill-session") => "",
                Some(&"capture-pane") => "test output line 1\ntest output line 2\n",
                Some(&"list-windows") => "server|12345|0\nclient|12346|1\n",
                _ => "",
            };
            Ok(Output {
                status: std::process::ExitStatus::default(),
                stdout: stdout.as_bytes().to_vec(),
                stderr: Vec::new(),
            })
        }
    }

    /// Mock executor that fails commands
    struct FailingMockExecutor {
        error_message: String,
    }

    impl FailingMockExecutor {
        fn new(error_message: &str) -> Self {
            Self {
                error_message: error_message.to_string(),
            }
        }
    }

    impl CommandExecutor for FailingMockExecutor {
        fn execute(&self, _args: &[&str]) -> io::Result<Output> {
            // Simulate failed exit status - we can't create a failed ExitStatus directly,
            // so we return success status but with stderr content that we check
            Ok(Output {
                status: std::process::ExitStatus::default(),
                stdout: Vec::new(),
                stderr: self.error_message.as_bytes().to_vec(),
            })
        }
    }

    /// Mock that tracks calls
    struct TrackingMockExecutor {
        calls: std::sync::Mutex<Vec<Vec<String>>>,
    }

    impl TrackingMockExecutor {
        fn new() -> Self {
            Self {
                calls: std::sync::Mutex::new(Vec::new()),
            }
        }

        fn get_calls(&self) -> Vec<Vec<String>> {
            self.calls.lock().unwrap().clone()
        }
    }

    impl CommandExecutor for TrackingMockExecutor {
        fn execute(&self, args: &[&str]) -> io::Result<Output> {
            self.calls
                .lock()
                .unwrap()
                .push(args.iter().map(|s| s.to_string()).collect());

            let stdout = match args.first() {
                Some(&"list-windows") => "test-pane|12345|0\n",
                Some(&"capture-pane") => "captured output\n",
                _ => "",
            };

            Ok(Output {
                status: std::process::ExitStatus::default(),
                stdout: stdout.as_bytes().to_vec(),
                stderr: Vec::new(),
            })
        }
    }

    // --- Session Creation Tests ---

    #[test]
    fn test_session_name_format() {
        let session = TmuxSession::with_executor(StaticMockExecutor::default());
        assert!(session.session_name().starts_with("debug-"));
    }

    #[test]
    fn test_session_not_created_initially() {
        let session = TmuxSession::with_executor(StaticMockExecutor::default());
        assert!(!session.is_created());
    }

    #[test]
    fn test_session_created_after_create_pane() {
        let mut session = TmuxSession::with_executor(StaticMockExecutor::default());
        session.create_pane("echo hello", "test").unwrap();
        assert!(session.is_created());
    }

    // --- Command Execution Tests ---

    #[test]
    fn test_create_pane_executes_correct_commands() {
        let executor = TrackingMockExecutor::new();
        let mut session = TmuxSession::with_executor(executor);

        session.create_pane("cargo run", "server").unwrap();

        let calls = session.executor.get_calls();

        // Should have: new-session, set-option (session), new-window, set-option (window), send-keys
        assert!(calls.len() >= 5);

        // First call should be new-session
        assert_eq!(calls[0][0], "new-session");
        assert!(calls[0].contains(&"-d".to_string()));
        assert!(calls[0].contains(&"-s".to_string()));

        // Second call should be set-option for remain-on-exit (session level)
        assert_eq!(calls[1][0], "set-option");
        assert!(calls[1].contains(&"remain-on-exit".to_string()));
        assert!(calls[1].contains(&"on".to_string()));

        // Third call should be new-window
        assert_eq!(calls[2][0], "new-window");
        assert!(calls[2].contains(&"-n".to_string()));
        assert!(calls[2].contains(&"server".to_string()));

        // Fourth call should be set-option for remain-on-exit on the window
        assert_eq!(calls[3][0], "set-option");
        assert!(calls[3].contains(&"remain-on-exit".to_string()));
        assert!(calls[3].contains(&"on".to_string()));
        // Should target the specific window
        assert!(calls[3].iter().any(|s| s.contains("server")));

        // Fifth call should be send-keys
        assert_eq!(calls[4][0], "send-keys");
        assert!(calls[4].contains(&"cargo run".to_string()));
        assert!(calls[4].contains(&"Enter".to_string()));
    }

    #[test]
    fn test_send_keys_executes_correct_command() {
        let executor = TrackingMockExecutor::new();
        let mut session = TmuxSession::with_executor(executor);

        // Create pane first to initialize session
        session.create_pane("bash", "test").unwrap();

        session.send_keys("test", "echo hello").unwrap();

        let calls = session.executor.get_calls();
        let send_keys_call = calls.last().unwrap();

        assert_eq!(send_keys_call[0], "send-keys");
        assert!(send_keys_call.iter().any(|s| s.contains("test")));
        assert!(send_keys_call.contains(&"echo hello".to_string()));
    }

    #[test]
    fn test_capture_pane_executes_correct_command() {
        let executor = TrackingMockExecutor::new();
        let mut session = TmuxSession::with_executor(executor);

        // Create pane first
        session.create_pane("bash", "test").unwrap();

        let output = session.capture_pane("test", 100).unwrap();

        assert_eq!(output, "captured output\n");

        let calls = session.executor.get_calls();
        let capture_call = calls.last().unwrap();

        assert_eq!(capture_call[0], "capture-pane");
        assert!(capture_call.contains(&"-p".to_string()));
        assert!(capture_call.contains(&"-S".to_string()));
        assert!(capture_call.contains(&"-100".to_string()));
    }

    #[test]
    fn test_kill_pane_executes_correct_command() {
        let executor = TrackingMockExecutor::new();
        let mut session = TmuxSession::with_executor(executor);

        // Create pane first
        session.create_pane("bash", "test").unwrap();

        session.kill_pane("test").unwrap();

        let calls = session.executor.get_calls();
        let kill_call = calls.last().unwrap();

        assert_eq!(kill_call[0], "kill-window");
        assert!(kill_call.iter().any(|s| s.contains("test")));
    }

    #[test]
    fn test_list_windows_parses_output() {
        let mut session = TmuxSession::with_executor(StaticMockExecutor::default());

        // Create a pane to mark session as created
        session.create_pane("bash", "test").unwrap();

        let windows = session.list_windows().unwrap();

        assert_eq!(windows.len(), 2);

        assert_eq!(windows[0].name, "server");
        assert_eq!(windows[0].pid, Some(12345));
        assert!(!windows[0].is_dead);
        assert_eq!(windows[0].status(), "running");

        assert_eq!(windows[1].name, "client");
        assert_eq!(windows[1].pid, Some(12346));
        assert!(windows[1].is_dead);
        assert_eq!(windows[1].status(), "exited");
    }

    #[test]
    fn test_list_windows_empty_when_no_session() {
        let session = TmuxSession::with_executor(StaticMockExecutor::default());
        let windows = session.list_windows().unwrap();
        assert!(windows.is_empty());
    }

    // --- Session Lifecycle Tests ---

    #[test]
    fn test_kill_session_marks_not_created() {
        let mut session = TmuxSession::with_executor(StaticMockExecutor::default());

        session.create_pane("bash", "test").unwrap();
        assert!(session.is_created());

        session.kill_session().unwrap();
        assert!(!session.is_created());
    }

    #[test]
    fn test_kill_session_noop_when_not_created() {
        let mut session = TmuxSession::with_executor(StaticMockExecutor::default());
        // Should not error
        session.kill_session().unwrap();
    }

    #[test]
    fn test_ensure_session_only_creates_once() {
        let executor = TrackingMockExecutor::new();
        let mut session = TmuxSession::with_executor(executor);

        session.create_pane("bash", "pane1").unwrap();
        session.create_pane("bash", "pane2").unwrap();

        let calls = session.executor.get_calls();

        // Count new-session calls
        let new_session_count = calls
            .iter()
            .filter(|c| c.first() == Some(&"new-session".to_string()))
            .count();

        assert_eq!(new_session_count, 1);
    }

    // --- Error Handling Tests ---

    #[test]
    fn test_window_info_status_running() {
        let info = WindowInfo {
            name: "test".to_string(),
            pid: Some(123),
            is_dead: false,
        };
        assert_eq!(info.status(), "running");
    }

    #[test]
    fn test_window_info_status_exited() {
        let info = WindowInfo {
            name: "test".to_string(),
            pid: Some(123),
            is_dead: true,
        };
        assert_eq!(info.status(), "exited");
    }

    #[test]
    fn test_error_display_command_failed() {
        let err = TmuxError::CommandFailed {
            command: "tmux new-session".to_string(),
            stderr: "some error".to_string(),
        };
        let display = format!("{}", err);
        assert!(display.contains("tmux new-session"));
        assert!(display.contains("some error"));
    }

    #[test]
    fn test_error_display_session_not_found() {
        let err = TmuxError::SessionNotFound("debug-123".to_string());
        let display = format!("{}", err);
        assert!(display.contains("debug-123"));
        assert!(display.contains("not found"));
    }

    #[test]
    fn test_error_display_window_not_found() {
        let err = TmuxError::WindowNotFound("my-pane".to_string());
        let display = format!("{}", err);
        assert!(display.contains("my-pane"));
        assert!(display.contains("tmux_list_panes"));
    }
}
