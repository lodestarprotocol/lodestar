#!/bin/sh
# Push the cleaned history to a freshly recreated GitHub repo, and prove it landed clean.
#
# WHY THE REPO IS BEING RECREATED
#   LAUNCH_RUNBOOK.md was committed to this public repo. It was purged from all 169 commits with
#   git-filter-repo and force-pushed, but GitHub keeps the pre-rewrite objects reachable by direct
#   SHA -- raw.githubusercontent.com was still serving the file at three of them. Only GitHub Support
#   can garbage-collect those, which takes days. Deleting and recreating the repository destroys them
#   with certainty, immediately, and this repo has 0 forks / 0 stars / 0 issues / 0 PRs / 0 releases,
#   so nothing else is lost.
#
# RUN THIS ONLY AFTER you have deleted and recreated the empty repo on github.com (steps in the
# output of `tools/recreate_repo.sh --steps`). It refuses to run against a repo that still has
# history, so it cannot clobber anything by accident.
#
# Safety net: C:/Users/cyber/lodestar-clean.bundle is a complete, verified copy of both branches.
# Restore with:  git clone C:/Users/cyber/lodestar-clean.bundle restored

set -e
REPO="https://github.com/lodestarprotocol/lodestar.git"
BUNDLE="C:/Users/cyber/lodestar-clean.bundle"

if [ "$1" = "--steps" ]; then
cat <<'STEPS'

  BEFORE running this script, on github.com:

  1. Delete the old repo.
     github.com/lodestarprotocol/lodestar -> Settings -> Danger Zone
     -> Delete this repository -> type  lodestarprotocol/lodestar

  2. Create it again, EMPTY.
     github.com/new
       Owner        lodestarprotocol
       Name         lodestar
       Public
       Description  Borrow against XRP & FLR. No liquidations. Lock FXRP or sFLR, take USD0 at a fixed rate
       Do NOT tick "Add a README", ".gitignore" or "a license" -- an initial commit makes the
       push non-fast-forward and this script will refuse to run.

  3. Run:  sh tools/recreate_repo.sh

  AFTER the script reports OK:

  4. Reconnect Cloudflare Pages. dash.cloudflare.com -> Workers & Pages -> lodestar-8sp
     -> Settings -> Builds & deployments -> reconnect to lodestarprotocol/lodestar,
     production branch main, build command EMPTY, output directory  web/
     Then push any trivial commit and confirm lodestarprotocol.xyz rebuilds.

  5. Re-enable GitHub Pages for the redirect stub.
     Settings -> Pages -> Source: Deploy from a branch -> Branch: gh-pages / (root)
     Confirms at lodestarprotocol.github.io/lodestar/

  6. Delete the pre-purge mirror, which is the last copy of the leaked history:
     rm -rf C:/Users/cyber/belay-backup-prepurge

STEPS
exit 0
fi

echo "checking the new repo is empty..."
if git ls-remote --heads "$REPO" 2>/dev/null | grep -q .; then
  echo
  echo "  REFUSING TO PUSH: $REPO already has branches."
  echo "  Either it was not deleted, or it was recreated WITH a README/licence."
  echo "  Delete it again and recreate it with nothing ticked."
  exit 1
fi

echo "verifying the local history is clean before publishing it..."
if [ "$(git log --all --oneline -- LAUNCH_RUNBOOK.md .ltvtmp | wc -l)" != "0" ]; then
  echo "  REFUSING TO PUSH: the purged paths are back in local history."; exit 1
fi
python - <<'PY' || exit 1
import subprocess, re, sys
rx = re.compile(rb"lodestar-deploy[\\/]wallets|deploy\.pk|0x59b7fb215e9[cC]73[aA]25[bB]358929462[aA]107[eE]1f[eE]c5088|5 keys in one folder")
bad = []
for line in subprocess.run(["git","rev-list","--objects","main","gh-pages"],
                           capture_output=True, text=True).stdout.splitlines():
    p = line.split(" ", 1)
    if len(p) != 2: continue
    if rx.search(subprocess.run(["git","cat-file","-p",p[0]], capture_output=True).stdout):
        bad.append(p[1])
if bad:
    print("  REFUSING TO PUSH: leaked strings still present in", sorted(set(bad))); sys.exit(1)
print("  clean: 0 blobs on main or gh-pages contain any leaked string")
PY

echo "pushing main and gh-pages (ONLY those two -- local scratch branches stay local)..."
git push "$REPO" main:main
git push "$REPO" gh-pages:gh-pages
git remote set-url origin "$REPO" 2>/dev/null || git remote add origin "$REPO"
git remote set-head origin main 2>/dev/null || true

echo
echo "verifying what a stranger now sees..."
TMP="$(mktemp -d)"
git clone -q "$REPO" "$TMP/v"
cd "$TMP/v"
echo "  commits:                 $(git rev-list --all --count)"
echo "  runbook in history:      $(git log --all --oneline -- LAUNCH_RUNBOOK.md | wc -l) commits"
echo "  branches:                $(git ls-remote --heads "$REPO" | wc -l)"
for s in 38b2a91d516ca5fb0b3d8b2e8d2b13772d22be87 \
         9b8c3ec230ec3678b7088fbcc7253f57d66daa4f \
         959dbff8749c2bc313bae54bee37df55316b9dc5; do
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    "https://raw.githubusercontent.com/lodestarprotocol/lodestar/$s/LAUNCH_RUNBOOK.md" --max-time 15)
  echo "  old raw ${s%${s#???????}} -> $code  (must be 404)"
done
cd - >/dev/null; rm -rf "$TMP"

echo
echo "reinstalling the pre-commit hook (git clone never copies hooks)..."
printf '#!/bin/sh\nexec python "$(git rev-parse --show-toplevel)/tools/precommit_secrets.py"\n' \
  > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit

echo
echo "OK. Now do steps 4-6 from:  sh tools/recreate_repo.sh --steps"
echo "Bundle safety net remains at $BUNDLE"
