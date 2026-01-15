#!/bin/bash
set -euo pipefail

# Builder entrypoint: starts sshd and nix-daemon for remote building

BUILDER_USER="builder"
BUILDER_UID=1000
BUILDER_HOME="/home/$BUILDER_USER"

# Generate SSH host key on first run
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    echo "Generating SSH host key..."
    ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N ""
fi

# Setup builder user if not exists
if ! id "$BUILDER_USER" &>/dev/null; then
    echo "Creating builder user..."
    echo "$BUILDER_USER:x:$BUILDER_UID:$BUILDER_UID::$BUILDER_HOME:/bin/bash" >> /etc/passwd
    echo "$BUILDER_USER:x:$BUILDER_UID:" >> /etc/group
fi

# Create home directory
mkdir -p "$BUILDER_HOME"
chown "$BUILDER_UID:$BUILDER_UID" "$BUILDER_HOME"

# Setup SSH directory
mkdir -p "$BUILDER_HOME/.ssh"
chmod 700 "$BUILDER_HOME/.ssh"
chown "$BUILDER_UID:$BUILDER_UID" "$BUILDER_HOME/.ssh"

# Install authorized keys from mounted location
KEYS_FILE="/run/keys/builder_ed25519.pub"
if [ -f "$KEYS_FILE" ]; then
    echo "Installing authorized keys..."
    cp "$KEYS_FILE" "$BUILDER_HOME/.ssh/authorized_keys"
    chmod 600 "$BUILDER_HOME/.ssh/authorized_keys"
    chown "$BUILDER_UID:$BUILDER_UID" "$BUILDER_HOME/.ssh/authorized_keys"
else
    echo "Warning: No authorized keys found at $KEYS_FILE" >&2
fi

# Configure nix-daemon
echo "Configuring nix..."
mkdir -p /etc/nix
cat > /etc/nix/nix.conf <<EOF
experimental-features = nix-command flakes
sandbox = false
trusted-users = root $BUILDER_USER
max-jobs = auto
cores = 0
min-free = 1073741824
max-free = 3221225472
EOF

# Start nix-daemon in background
echo "Starting nix-daemon..."
nix-daemon &

# Start sshd in background
echo "Starting sshd..."
/bin/sshd -e

# Keep container alive and reap zombies (act as init)
echo "Services started, waiting..."
while true; do
    sleep 60 &
    wait
done
