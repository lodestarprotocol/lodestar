#!/usr/bin/env python3
"""Refuse to commit key material or operational-secret files. Installed as .git/hooks/pre-commit.

Written because LAUNCH_RUNBOOK.md reached four public commits before anyone noticed. It carried no
key material -- verified by scanning all 167 commits -- but it did publish the deploy wallet address,
the exact path of the deploy private key, and the sentence saying five Safe signer keys sat in one
folder on one machine. That is targeting information for this specific box, and .gitignore only
helped after the fact.

Two independent checks, because either alone has a hole:

  1. NAME denylist -- catches a file whose CONTENT looks innocent today but whose whole purpose is
     operational secrecy (a runbook, a wallet dossier). .gitignore does not cover `git add -f`, and
     it does nothing for a file that was tracked before the ignore rule existed.
  2. CONTENT scan of the staged diff -- catches key material pasted into a file with an innocent
     name, which is how it usually happens.

Fails CLOSED: on any internal error the commit is refused. A false refusal costs a minute; a false
pass is permanent on a public repo.

Bypass, for the rare deliberate case, is `git commit --no-verify`. That is intentionally a thing you
have to type on purpose.
"""
import re
import subprocess
import sys

# Filenames whose existence in a public repo is itself the problem.
NAME_DENY = [
    re.compile(r"(^|/)LAUNCH_RUNBOOK\.md$", re.I),
    re.compile(r"(^|/)\.env(\.|$)"),
    re.compile(r"(^|/)(quest|dossier)/", re.I),
    re.compile(r"\.(pk|key|pem|p12|pfx|keystore)$", re.I),
    re.compile(r"(^|/)\.keeper$"),
    re.compile(r"(?i)(wallets?|keystore|seed|mnemonic|privkey|private[_-]?key)[^/]*$"),
    re.compile(r"(?i)password"),
]

# Content patterns. Only applied to ADDED lines, so an existing false positive never blocks work.
CONTENT_DENY = [
    ("64-hex value that could be a private key",
     re.compile(r"(?<![0-9a-fA-F])(?:0x)?[0-9a-fA-F]{64}(?![0-9a-fA-F])")),
    ("PEM private key block", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("keystore JSON", re.compile(r'"ciphertext"\s*:|"crypto"\s*:\s*\{')),
    ("AWS access key id", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("assigned secret/password/api key",
     re.compile(r"(?i)\b(private_?key|secret|passwd|password|api[_-]?key|mnemonic|seed_?phrase)\b\s*[:=]\s*['\"][^'\"]{8,}")),
    ("Windows path to a key file",
     re.compile(r"(?i)[a-z]:[\\/][^\s'\"`)]*(?:wallets?|keystore)[\\/][^\s'\"`)]*")),
]

# Files where a 64-hex string is normal and meaningless (hashes, bytes32 literals, minified bundles).
HEX_OK = re.compile(r"\.(sol|json|lock|min\.js|svg|png|jpg|jpeg|gif|ico)$|(^|/)out/|(^|/)cache/|(^|/)lib/")

# A 32-byte hash and a 32-byte private key are shape-identical, so the 64-hex rule cannot tell them
# apart and must not try to guess. A file that legitimately holds hashes (keccak test vectors, for
# instance) may opt OUT OF THAT ONE RULE with a line like:
#
#     # precommit-allow-hex: keccak256 test vectors, recomputed from public inputs by selftest
#
# Deliberately not `git commit --no-verify`, which disables every check for an entire commit and
# leaves no trace in the diff. This lives in the file, states a reason, and a reviewer sees it.
# Every other rule -- PEM blocks, keystore JSON, AWS keys, and `private_key = "..."` assignments,
# which is how a key realistically gets pasted -- stays armed.
ALLOW_HEX = re.compile(r"#\s*precommit-allow-hex:\s*\S")


def staged_files():
    r = subprocess.run(["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR"],
                       capture_output=True, text=True, encoding="utf-8", errors="replace", check=True)
    return [f for f in r.stdout.splitlines() if f.strip()]


def added_lines(path):
    r = subprocess.run(["git", "diff", "--cached", "-U0", "--", path],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    return [l[1:] for l in r.stdout.splitlines() if l.startswith("+") and not l.startswith("+++")]


def _fileOptsOutOfHexRule(path):
    """Does the file carry an explicit, reasoned opt-out of the 64-hex rule?

    Read from the STAGED blob, not the worktree, so the annotation being committed is the one that
    counts and a local-only edit cannot grant an exemption.
    """
    r = subprocess.run(["git", "show", ":" + path], capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    return r.returncode == 0 and bool(ALLOW_HEX.search(r.stdout))


def main():
    problems = []
    for f in staged_files():
        for rx in NAME_DENY:
            if rx.search(f):
                problems.append((f, None, "filename is on the secrets denylist"))
                break
        hex_exempt = HEX_OK.search(f) or _fileOptsOutOfHexRule(f)
        for label, rx in CONTENT_DENY:
            if rx is CONTENT_DENY[0][1] and hex_exempt:
                continue  # 64-hex is normal here, or the file opted out with a stated reason
            for i, line in enumerate(added_lines(f), 1):
                if rx.search(line):
                    problems.append((f, i, label))
                    break

    if not problems:
        return 0

    print("\n  COMMIT REFUSED -- possible secret or operational-secret file staged\n", file=sys.stderr)
    for f, i, why in problems:
        where = f if i is None else "%s (added line %d)" % (f, i)
        print("    %-52s %s" % (where, why), file=sys.stderr)
    print("""
  The matched text is NOT printed: echoing a key into a terminal or a log is a second disclosure.
  Open the file and look.

  If this is a false positive, commit with:  git commit --no-verify
  If it is real: unstage it, add it to .gitignore, and if it was ever pushed, treat the value as
  burned and rotate it. Public git history cannot be un-published.
""", file=sys.stderr)
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:                      # fail CLOSED
        print("  COMMIT REFUSED -- secret scanner failed to run: %s" % e, file=sys.stderr)
        sys.exit(1)
