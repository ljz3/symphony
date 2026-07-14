#!/bin/sh
set -eu

root=$(mktemp -d "${TMPDIR:-/tmp}/symphony-escript-smoke.XXXXXX")
trap 'rm -rf "$root"' EXIT HUP INT TERM

home="$root/home"
cache="$root/cache"
worktrees="$root/worktrees"
logs="$root/logs"
output="$root/status.json"

mkdir -p "$home" "$cache" "$worktrees" "$logs"

XDG_CACHE_HOME="$cache" \
  ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --port 0 \
  --symphony-home "$home" \
  --worktrees-root "$worktrees" \
  --logs-root "$logs" \
  board status "$PWD/WORKFLOW.yml" > "$output"

grep -q '"id": "symphony"' "$output"
test -f "$home/symphony/runtime/board.sqlite3"
test -d "$home/symphony/workpads/records"
test -d "$home/symphony/workpads/publications"
