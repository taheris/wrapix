# Wrapix Notification Daemon

Runs `wrapix-notifyd` on the host to receive notifications from containers.

## Overview

The daemon listens on `~/.local/share/wrapix/notify.sock` and triggers native
desktop notifications when Claude Code (inside a container) needs attention.

## Files

- `com.local.wrapix-notifyd.plist` - macOS LaunchAgent config
- `wrapix-notifyd.service` - Linux systemd user service

## macOS Installation

### Option A: Run manually

```bash
nix run github:taheris/wrapix#wrapix-notifyd
```

### Option B: Install as LaunchAgent (recommended)

1. Build the daemon and note its path:

```bash
nix build github:taheris/wrapix#wrapix-notifyd
DAEMON_PATH="$(nix path-info github:taheris/wrapix#wrapix-notifyd)/bin/wrapix-notifyd"
echo "Daemon path: $DAEMON_PATH"
```

2. Generate the plist with the correct path:

```bash
sed "s|__DAEMON_PATH__|$DAEMON_PATH|g" scripts/notify/com.local.wrapix-notifyd.plist \
    > ~/Library/LaunchAgents/com.local.wrapix-notifyd.plist
```

3. Load the agent:

```bash
launchctl load ~/Library/LaunchAgents/com.local.wrapix-notifyd.plist
```

4. Verify it's running:

```bash
launchctl list | grep wrapix-notifyd
tail -f /tmp/wrapix-notifyd.log
```

### macOS Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.local.wrapix-notifyd.plist
rm ~/Library/LaunchAgents/com.local.wrapix-notifyd.plist
```

## Linux Installation

### Option A: Run manually

```bash
nix run github:taheris/wrapix#wrapix-notifyd
```

### Option B: Install as systemd user service (recommended)

1. Build the daemon and note its path:

```bash
nix build github:taheris/wrapix#wrapix-notifyd
DAEMON_PATH="$(nix path-info github:taheris/wrapix#wrapix-notifyd)/bin/wrapix-notifyd"
echo "Daemon path: $DAEMON_PATH"
```

2. Generate the service file with the correct path:

```bash
mkdir -p ~/.config/systemd/user
sed "s|__DAEMON_PATH__|$DAEMON_PATH|g" scripts/notify/wrapix-notifyd.service \
    > ~/.config/systemd/user/wrapix-notifyd.service
```

3. Enable and start the service:

```bash
systemctl --user daemon-reload
systemctl --user enable --now wrapix-notifyd
```

4. Verify it's running:

```bash
systemctl --user status wrapix-notifyd
journalctl --user -u wrapix-notifyd -f
```

### Linux Uninstall

```bash
systemctl --user disable --now wrapix-notifyd
rm ~/.config/systemd/user/wrapix-notifyd.service
systemctl --user daemon-reload
```

## Testing

From inside a wrapix container:

```bash
wrapix-notify "Test" "Hello from container"
```

You should see a notification appear on your desktop.
