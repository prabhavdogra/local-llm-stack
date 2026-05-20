#!/usr/bin/env bash
# Sync this repo to DGX Spark over SSH (rsync).
#
# Defaults (override via env or make sync DGX_HOST=...):
#   DGX_HOST=prabhav@spark-2393.local
#   DGX_PATH=~/Desktop/repositories/local-llm-stack
#
# Usage:
#   ./scripts/sync-to-dgx.sh
#   DRY_RUN=1 ./scripts/sync-to-dgx.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DGX_HOST="${DGX_HOST:-prabhav@spark-2393.local}"
DGX_PATH="${DGX_PATH:-~/Desktop/repositories/local-llm-stack}"

RSYNC_OPTS=(-avz --human-readable)
if [[ "${DRY_RUN:-}" == "1" ]]; then
  RSYNC_OPTS+=(--dry-run)
  echo "DRY RUN — no files will be changed on the remote."
fi

echo "→ Ensuring remote directory exists: ${DGX_HOST}:${DGX_PATH}"
ssh -o BatchMode=yes "${DGX_HOST}" "mkdir -p ${DGX_PATH}"

echo "→ Syncing ${ROOT}/ → ${DGX_HOST}:${DGX_PATH}/"
rsync "${RSYNC_OPTS[@]}" \
  --exclude '.git/index.lock' \
  --exclude '.env' \
  --exclude '.env.local' \
  --exclude '.env.*.local' \
  --exclude '.venv/' \
  --exclude '__pycache__/' \
  --exclude '*.pyc' \
  --exclude '.DS_Store' \
  --exclude '.idea/' \
  --exclude '.vscode/' \
  --exclude '.mlx.pid' \
  --exclude '.mlx.log' \
  --exclude '*.pid' \
  --exclude 'evalplus_results/' \
  "${ROOT}/" "${DGX_HOST}:${DGX_PATH}/"

echo ""
echo "Done. On the DGX:"
echo "  ssh -t ${DGX_HOST} \"cd ${DGX_PATH} && bash -l\""
echo "  make config    # first time only — creates .env + secrets on the DGX"
echo "  make check-env"
echo "  make up"
