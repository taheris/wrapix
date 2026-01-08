#!/bin/bash
set -euo pipefail

# Add user entry with host UID (passwd is writable at runtime)
# Note: home directory must be /home/$HOST_USER to match where we copy .claude.json
echo "$HOST_USER:x:$HOST_UID:$HOST_UID::/home/$HOST_USER:/bin/bash" >> /etc/passwd
echo "$HOST_USER:x:$HOST_UID:" >> /etc/group

export USER="$HOST_USER"

# Use container-local HOME for Darwin VMs (VirtioFS maps files as root)
mkdir -p "/home/$HOST_USER"
chown "$HOST_UID:$HOST_UID" "/home/$HOST_USER"
export HOME="/home/$HOST_USER"

# Copy directories from mounts with correct ownership
# VirtioFS maps all files as root, so directories are mounted to staging location
# and need to be copied with correct permissions
declare -a DIR_MOUNT_PAIRS
if [ -n "${WRAPIX_DIR_MOUNTS:-}" ]; then
    IFS=',' read -ra DIR_MOUNTS <<< "$WRAPIX_DIR_MOUNTS"
    for mapping in "${DIR_MOUNTS[@]}"; do
        src="${mapping%%:*}"
        dst=$(eval echo "${mapping#*:}")
        if [ -d "$src" ]; then
            mkdir -p "$(dirname "$dst")"
            cp -r "$src" "$dst"
            chown -R "$HOST_UID:$HOST_UID" "$dst"
            DIR_MOUNT_PAIRS+=("$src:$dst")
        fi
    done
fi

# Copy files from mounts with correct ownership
# VirtioFS only supports directory mounts, so files are mounted via parent directory
# and need to be copied with correct permissions
declare -a FILE_MOUNT_PAIRS
if [ -n "${WRAPIX_FILE_MOUNTS:-}" ]; then
    IFS=',' read -ra MOUNTS <<< "$WRAPIX_FILE_MOUNTS"
    for mapping in "${MOUNTS[@]}"; do
        src="${mapping%%:*}"
        dst=$(eval echo "${mapping#*:}")
        if [ -f "$src" ]; then
            mkdir -p "$(dirname "$dst")"
            cp "$src" "$dst"
            chown "$HOST_UID:$HOST_UID" "$dst"
            FILE_MOUNT_PAIRS+=("$src:$dst")
        fi
    done
fi

# Copy modified files/directories back to mount on exit
cleanup() {
    for pair in "${DIR_MOUNT_PAIRS[@]+"${DIR_MOUNT_PAIRS[@]}"}"; do
        src="${pair%%:*}"
        dst="${pair#*:}"
        if [ -d "$dst" ]; then
            rsync -a --delete "$dst/" "$src/"
        fi
    done
    for pair in "${FILE_MOUNT_PAIRS[@]+"${FILE_MOUNT_PAIRS[@]}"}"; do
        src="${pair%%:*}"
        dst="${pair#*:}"
        if [ -f "$dst" ]; then
            cp "$dst" "$src"
        fi
    done
}
trap cleanup EXIT

cd /workspace

# Run without exec so trap can fire
setpriv --reuid="$HOST_UID" --regid="$HOST_UID" --init-groups \
  claude --dangerously-skip-permissions --append-system-prompt "$WRAPIX_PROMPT"
EXIT_CODE=$?
exit $EXIT_CODE
