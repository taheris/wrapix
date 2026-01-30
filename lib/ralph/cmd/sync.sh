#!/usr/bin/env bash
set -euo pipefail

# ralph sync [--dry-run]
# Synchronizes local templates with packaged versions
# - Creates .claude/ralph/templates/ with fresh packaged templates
# - Backs up existing customized templates to .claude/ralph/backup/
# - Copies all templates including partial/ directory
# - Verbose by default (prints actions taken)

# Load shared helpers
# shellcheck source=util.sh
source "$(dirname "$0")/util.sh"

RALPH_DIR="${RALPH_DIR:-.claude/ralph}"

# Template directory: use RALPH_TEMPLATE_DIR if set and exists
if [ -n "${RALPH_TEMPLATE_DIR:-}" ] && [ -d "$RALPH_TEMPLATE_DIR" ]; then
  PACKAGED_DIR="$RALPH_TEMPLATE_DIR"
else
  PACKAGED_DIR=""
fi

# Parse arguments
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run|-n)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      echo "Usage: ralph sync [--dry-run]"
      echo ""
      echo "Synchronizes local templates with packaged versions."
      echo ""
      echo "Options:"
      echo "  --dry-run, -n  Preview changes without executing"
      echo "  --help, -h     Show this help message"
      echo ""
      echo "Actions:"
      echo "  1. Creates .claude/ralph/templates/ with fresh packaged templates"
      echo "  2. Backs up existing customized templates to .claude/ralph/backup/"
      echo "  3. Copies all templates including partial/ directory"
      echo ""
      echo "After sync, use 'ralph diff' to see what changed,"
      echo "then 'ralph tune' to merge customizations from backup."
      echo ""
      echo "Environment:"
      echo "  RALPH_DIR           Local ralph directory (default: .claude/ralph)"
      echo "  RALPH_TEMPLATE_DIR  Packaged template directory (from nix develop)"
      exit 0
      ;;
    *)
      error "Unknown option: $1
Run 'ralph sync --help' for usage."
      ;;
  esac
done

# Validate RALPH_TEMPLATE_DIR is set
if [ -z "$PACKAGED_DIR" ]; then
  error "RALPH_TEMPLATE_DIR not set or directory doesn't exist.

Run from 'nix develop' shell which sets RALPH_TEMPLATE_DIR.
Current value: ${RALPH_TEMPLATE_DIR:-<not set>}"
fi

# Directories
TEMPLATES_DIR="$RALPH_DIR/templates"
BACKUP_DIR="$RALPH_DIR/backup"

# Prefix for dry-run output
prefix() {
  if [ "$DRY_RUN" = "true" ]; then
    echo "[dry-run] "
  else
    echo ""
  fi
}

# Print action with optional dry-run prefix
action() {
  echo "$(prefix)$*"
}

# Create directory if it doesn't exist
ensure_dir() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    action "Creating directory: $dir"
    if [ "$DRY_RUN" = "false" ]; then
      mkdir -p "$dir"
    fi
  fi
}

# Copy file with action logging
copy_file() {
  local src="$1"
  local dst="$2"
  local name="${3:-$(basename "$src")}"

  action "Copying: $name"
  debug "  from: $src"
  debug "  to:   $dst"

  if [ "$DRY_RUN" = "false" ]; then
    # Remove existing file if it exists (may be read-only from previous sync)
    if [ -f "$dst" ]; then
      rm -f "$dst"
    fi
    cp "$src" "$dst"
  fi
}

# List files matching patterns in a directory
# Usage: list_files "$dir" "*.md" "*.nix"
# Returns files one per line, empty if none found
list_files() {
  local dir="$1"
  shift

  if [ ! -d "$dir" ]; then
    return 0
  fi

  for pattern in "$@"; do
    # Use find for reliable file listing
    find "$dir" -maxdepth 1 -type f -name "$pattern" 2>/dev/null || true
  done
}

# Backup existing templates if they differ from packaged
backup_existing() {
  local templates_dir="$1"
  local backup_dir="$2"
  local packaged_dir="$3"

  if [ ! -d "$templates_dir" ]; then
    debug "No existing templates to backup"
    return 0
  fi

  local has_backups=false

  # Check each file in templates directory
  while IFS= read -r local_file; do
    [ -f "$local_file" ] || continue

    local name
    name=$(basename "$local_file")
    local packaged_file="$packaged_dir/$name"

    # Skip if no packaged version exists
    if [ ! -f "$packaged_file" ]; then
      debug "Skipping $name: no packaged version"
      continue
    fi

    # Check if local differs from packaged
    if ! diff -q "$packaged_file" "$local_file" >/dev/null 2>&1; then
      if [ "$has_backups" = "false" ]; then
        ensure_dir "$backup_dir"
        has_backups=true
      fi

      action "Backing up: $name (has local changes)"
      if [ "$DRY_RUN" = "false" ]; then
        cp "$local_file" "$backup_dir/$name"
      fi
    else
      debug "$name: matches packaged, no backup needed"
    fi
  done < <(list_files "$templates_dir" "*.md" "*.nix")

  # Handle partial directory
  local partial_dir="$templates_dir/partial"
  if [ -d "$partial_dir" ]; then
    local packaged_partial="$packaged_dir/partial"

    while IFS= read -r local_file; do
      [ -f "$local_file" ] || continue

      local name
      name=$(basename "$local_file")
      local packaged_file="$packaged_partial/$name"

      if [ ! -f "$packaged_file" ]; then
        debug "Skipping partial/$name: no packaged version"
        continue
      fi

      if ! diff -q "$packaged_file" "$local_file" >/dev/null 2>&1; then
        if [ "$has_backups" = "false" ]; then
          ensure_dir "$backup_dir"
          has_backups=true
        fi

        ensure_dir "$backup_dir/partial"
        action "Backing up: partial/$name (has local changes)"
        if [ "$DRY_RUN" = "false" ]; then
          cp "$local_file" "$backup_dir/partial/$name"
        fi
      fi
    done < <(list_files "$partial_dir" "*.md")
  fi

  if [ "$has_backups" = "true" ]; then
    echo ""
    echo "Customizations backed up to: $backup_dir"
    echo "Use 'ralph tune' to merge them after reviewing with 'ralph diff'."
  fi
}

# Copy fresh templates from packaged directory
copy_fresh_templates() {
  local packaged_dir="$1"
  local templates_dir="$2"

  ensure_dir "$templates_dir"

  echo ""
  echo "Copying fresh templates from: $packaged_dir"

  # Copy top-level template files
  local file_count=0
  while IFS= read -r src_file; do
    [ -f "$src_file" ] || continue

    # Skip default.nix - it's the Nix template definitions, not a user template
    local name
    name=$(basename "$src_file")
    if [ "$name" = "default.nix" ]; then
      debug "Skipping $name: internal Nix definitions"
      continue
    fi

    copy_file "$src_file" "$templates_dir/$name" "$name"
    ((file_count++)) || true
  done < <(list_files "$packaged_dir" "*.md" "*.nix")

  # Copy partial directory
  local packaged_partial="$packaged_dir/partial"
  if [ -d "$packaged_partial" ]; then
    local partial_dir="$templates_dir/partial"
    ensure_dir "$partial_dir"

    while IFS= read -r src_file; do
      [ -f "$src_file" ] || continue

      local name
      name=$(basename "$src_file")
      copy_file "$src_file" "$partial_dir/$name" "partial/$name"
      ((file_count++)) || true
    done < <(list_files "$packaged_partial" "*.md")
  fi

  echo ""
  echo "Copied $file_count template files to: $templates_dir"
}

# Main
echo "Ralph Template Sync"
echo "==================="
echo ""

if [ "$DRY_RUN" = "true" ]; then
  echo "DRY RUN MODE - No changes will be made"
  echo ""
fi

echo "Packaged templates: $PACKAGED_DIR"
echo "Local templates:    $TEMPLATES_DIR"
echo ""

# Step 1: Backup existing customizations
backup_existing "$TEMPLATES_DIR" "$BACKUP_DIR" "$PACKAGED_DIR"

# Step 2: Copy fresh templates
copy_fresh_templates "$PACKAGED_DIR" "$TEMPLATES_DIR"

echo ""
if [ "$DRY_RUN" = "true" ]; then
  echo "Dry run complete. Run without --dry-run to apply changes."
else
  echo "Sync complete."
  echo ""
  echo "Next steps:"
  echo "  ralph diff   - Review changes vs packaged templates"
  echo "  ralph check  - Validate template syntax"
fi
