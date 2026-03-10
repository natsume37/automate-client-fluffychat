#!/usr/bin/env bash
set -euo pipefail

base_sha="${BASE_SHA:-}"
head_sha="${HEAD_SHA:-${GITHUB_SHA:-HEAD}}"

if [ -z "$base_sha" ] || [ "$base_sha" = "0000000000000000000000000000000000000000" ]; then
  if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
    base_sha="$(git rev-parse HEAD~1)"
  else
    echo "No base commit available, skip formatting check."
    exit 0
  fi
fi

if ! git cat-file -e "${base_sha}^{commit}" >/dev/null 2>&1; then
  git fetch --no-tags origin "${base_sha}" >/dev/null 2>&1 || true
fi

if ! git cat-file -e "${base_sha}^{commit}" >/dev/null 2>&1; then
  if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
    base_sha="$(git rev-parse HEAD~1)"
  else
    echo "Unable to resolve base commit, skip formatting check."
    exit 0
  fi
fi

mapfile -t changed_dart_files < <(
  git diff --name-only --diff-filter=ACMR "$base_sha" "$head_sha" -- lib test \
    | awk '/\.dart$/'
)

if [ "${#changed_dart_files[@]}" -eq 0 ]; then
  echo "No changed Dart files in lib/ or test/."
  exit 0
fi

printf 'Checking format for %s changed Dart files:\n' "${#changed_dart_files[@]}"
printf '%s\n' "${changed_dart_files[@]}"

if ! dart format --output=none --set-exit-if-changed "${changed_dart_files[@]}"; then
  echo
  echo "Formatting check failed. Run:"
  printf '  dart format %q\n' "${changed_dart_files[@]}"
  exit 1
fi
