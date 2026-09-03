#!/usr/bin/env bash
set -euo pipefail

# Script: untrack-archives.sh
# Purpose: On a local clone, switch to the cleanup branch, untrack .7z and .zip files
# (keep local copies), commit, and push the branch.
# Usage: run from the repo root after fetching origin: ./scripts/untrack-archives.sh

BRANCH="cleanup/remove-tracked-archives"

echo "Fetching origin..."
git fetch origin --quiet

echo "Checking out branch ${BRANCH} (will create if needed)..."
if git show-ref --verify --quiet refs/heads/${BRANCH}; then
  git checkout ${BRANCH}
else
  git checkout -b ${BRANCH} origin/${BRANCH} 2>/dev/null || git checkout -b ${BRANCH}
fi

echo "Previewing tracked archive files:"
# Handles filenames with spaces
git ls-files -z '*.7z' '*.zip' | xargs -0 -r -n1 echo || true

read -p "Proceed to untrack these files from Git (they will remain in your working directory)? [y/N] " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Aborted. No changes made."
  exit 0
fi

# Untrack the matching files (keeps local files)
git ls-files -z '*.7z' '*.zip' | xargs -0 -r git rm --cached --

# If there were no files matched, xargs returns 0 but nothing happened.
# Check status to decide whether to commit
if git diff --cached --quiet; then
  echo "No tracked archive files found to untrack."
else
  git commit -m "Stop tracking archive files (.7z, .zip)"
  echo "Pushing ${BRANCH} to origin..."
  git push origin ${BRANCH}
  echo "Done: branch ${BRANCH} updated and pushed. Open a PR from this branch to main if desired."
fi
