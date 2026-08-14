#!/usr/bin/env bash
#
# Identify unused pubspec dependencies and move any associated abandoned source
# files into the "Geonix wrench software files removed" directory.
#
# SAFETY: this script never DELETES anything.
#   - pubspec.yaml is backed up into the failsafe directory before any change.
#   - unused dependency lines are COMMENTED OUT (not removed), so reverting is
#     a one-line uncomment or a restore from the backup.
#   - any lib file that imports an unused package is MOVED (not deleted) into
#     the failsafe directory, preserving its relative path.
#
# By default it runs in DRY-RUN mode and only reports what it would do.
# Pass --apply to actually make the changes.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBSPEC="$ROOT/pubspec.yaml"
REMOVED="$ROOT/Geonix wrench software files removed"
LIB="$ROOT/lib"

APPLY=0
if [[ "${1:-}" == "--apply" ]]; then
  APPLY=1
fi

mkdir -p "$REMOVED"

echo "==> Scanning $PUBSPEC for dependencies with no lib/ imports..."
echo

# Packages that are framework/platform primitives, not normal imports.
SKIP_RE="^(flutter|flutter_localizations|sdk)\$"

# Extract dependency names from the `dependencies:` block (stop at dev_dependencies).
deps=()
in_deps=0
while IFS= read -r line; do
  if [[ "$line" =~ ^dependencies: ]]; then in_deps=1; continue; fi
  if [[ "$line" =~ ^dev_dependencies: ]]; then in_deps=0; continue; fi
  if (( in_deps )); then
    if [[ "$line" =~ ^[[:space:]]+([a-zA-Z0-9_]+): ]]; then
      deps+=("${BASH_REMATCH[1]}")
    fi
  fi
done < "$PUBSPEC"

UNUSED=()
for pkg in "${deps[@]}"; do
  if [[ "$pkg" =~ $SKIP_RE ]]; then continue; fi
  count=$(grep -rl "package:${pkg}/" "$LIB" --include="*.dart" 2>/dev/null | wc -l | tr -d ' ' || true)
  if (( count == 0 )); then
    UNUSED+=("$pkg")
    echo "  UNUSED: $pkg"
  else
    echo "  used  : $pkg ($count file(s))"
  fi
done

echo
if (( ${#UNUSED[@]} == 0 )); then
  echo "==> No unused packages found. Nothing to do."
  exit 0
fi

if (( APPLY == 0 )); then
  echo "==> DRY RUN: the following would be commented out in pubspec.yaml and any"
  echo "    importing lib files moved into '$REMOVED'. Re-run with --apply to proceed."
  exit 0
fi

# --- APPLY MODE ---
BACKUP="$REMOVED/pubspec.yaml.bak"
if [[ ! -f "$BACKUP" ]]; then
  cp "$PUBSPEC" "$BACKUP"
  echo "==> Backed up pubspec.yaml -> $BACKUP"
fi

# Comment out each unused dependency line (exact `  name: ...` form).
for pkg in "${UNUSED[@]}"; do
  # Move any lib file that imports the package into the failsafe dir (mirrored path).
  while IFS= read -r f; do
    rel="${f#$ROOT/}"
    dest="$REMOVED/$rel"
    mkdir -p "$(dirname "$dest")"
    git -C "$ROOT" mv "$f" "$dest" 2>/dev/null || mv "$f" "$dest"
    echo "  moved $rel -> $REMOVED/$rel"
  done < <(grep -rl "package:${pkg}/" "$LIB" --include="*.dart" 2>/dev/null || true)

  # Comment the dependency line (support version ranges and git/path forms).
  sed -i.bak -E "s|^([[:space:]]+${pkg}:.*)\$|# REMOVED-BY-WRENCH: \1|" "$PUBSPEC"
  echo "  commented out dependency: $pkg"
done
rm -f "$PUBSPEC.bak"

echo
echo "==> Done. Run 'flutter pub get'. To revert: restore"
echo "   $BACKUP over $PUBSPEC (or uncomment the REMOVED-BY-WRENCH lines)."
