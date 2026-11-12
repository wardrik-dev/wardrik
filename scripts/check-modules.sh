#!/usr/bin/env bash
# Fails if two packages define a module of the same name. Packages load into one VM, so one would
# replace the other.
set -euo pipefail
cd "$(dirname "$0")/.."

dupes=$(for dir in packages/*/lib extensions/*/lib; do
  grep -rhoE '^\s*defmodule [A-Z][A-Za-z0-9_.]*' "$dir" | awk '{print $2}' | sort -u
done | sort | uniq -d)

if [[ -n $dupes ]]; then
  echo "Defined in more than one package:"
  for module in $dupes; do
    echo "  $module: $(grep -rlE "^\s*defmodule $module( |$)" packages/*/lib extensions/*/lib | tr '\n' ' ')"
  done
  exit 1
fi
echo "No module is defined twice."
