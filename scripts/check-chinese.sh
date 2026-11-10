#!/bin/bash
# Verify that no Chinese characters exist in repository files outside .xcstrings.
set -euo pipefail
cd "$(dirname "$0")/.."

if rg -P '\p{Han}' --hidden -g '!.git' -g '!.build' -g '!*.xcstrings' -n .; then
  echo "==> Failure: Chinese characters found in repository outside .xcstrings" >&2
  exit 1
fi

echo "==> Success: No Chinese characters found outside .xcstrings"
