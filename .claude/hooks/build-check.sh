#!/bin/bash
# Stop hook: when Swift sources have uncommitted changes, make sure Sorrel still
# compiles before Claude finishes. Exit 2 sends the errors back to Claude to fix.
input=$(cat)
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

# Only build when Sources/ or Package.swift have changed.
changed=$(git status --porcelain -- Sources Package.swift 2>/dev/null)
[ -z "$changed" ] && exit 0

# Build outside the project so build/Sorrel.app is never touched.
# One scratch folder per project copy, so parallel sessions don't collide.
key=$(printf '%s' "$PWD" | shasum | cut -c1-8)
scratch="${TMPDIR:-/tmp}/sorrel-hook-build-$key"

out=$(swift build --scratch-path "$scratch" 2>&1)
status=$?
[ $status -eq 0 ] && exit 0

errors=$(printf '%s\n' "$out" | grep -E "error:" | head -40)
[ -z "$errors" ] && errors=$(printf '%s\n' "$out" | tail -40)

if printf '%s' "$input" | grep -Eq '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
  # Claude already had one chance to fix it. Don't loop; tell the user instead.
  echo "Sorrel still doesn't compile after Claude's fix attempt:" >&2
  printf '%s\n' "$errors" >&2
  exit 1
fi

echo "Sorrel doesn't compile (swift build failed). Fix these errors before finishing:" >&2
printf '%s\n' "$errors" >&2
exit 2
