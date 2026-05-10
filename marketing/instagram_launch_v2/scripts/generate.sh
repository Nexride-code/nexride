#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ ! -d .venv ]]; then
  python3 -m venv .venv
  . .venv/bin/activate
  pip install -r scripts/requirements.txt
else
  . .venv/bin/activate
fi
python3 scripts/build_ad_creatives.py
