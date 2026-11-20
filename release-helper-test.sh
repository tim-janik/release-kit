#!/usr/bin/env bash
# This Source Code Form is licensed MPL-2.0: http://mozilla.org/MPL/2.0/
set -Eeuo pipefail

scripts=$(cd "$(dirname "$0")" && pwd)
helper=$scripts/release-helper.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
unset GITHUB_TOKEN
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# Consumer repository with dist/distcheck rules, NEWS.md and kit release wiring.
git init -q --initial-branch=trunk "$work/repo"
cd "$work/repo"
git config user.name 'Release Helper Test'
git config user.email rht@example.invalid
printf 'dist:\n\techo dist\n\ndistcheck: dist\n\techo distcheck\n' > Makefile
printf '## Release Helper Test 0.2.0\n\nNotes.\n' > NEWS.md
mkdir -p .github/workflows
cat > .github/workflows/ci.yml <<'EOF'
name: CI
on: { push: { tags: [ 'v*' ] } }
jobs:
  Release:
    if: github.ref_type == 'tag'
    permissions: { contents: write }
    uses: tim-janik/release-kit/.github/workflows/release.yml@trunk
EOF
git add .; git commit -qm 'Consumer wiring'
git tag -a v0.1.0 -m v0.1.0
git clone -q --bare "$work/repo" "$work/origin.git"
git remote add origin "$work/origin.git"
git fetch -q origin

expect_failure()
{
  if "$@" > "$work/failure" 2>&1; then
    echo "Expected failure: $*" >&2
    exit 1
  fi
}

# Check mode shows the derivable nightly tag and the NEWS.md release tag.
out=$("$helper")
grep -q 'NIGHTLY   will tag: v0.1.0.nightly' <<<"$out"
grep -q 'RELEASE   ok: v0.2.0' <<<"$out"

# -n -f pushes a lightweight nightly tag to origin.
"$helper" -n -f > "$work/nightly"
nightly=$(sed -n 's/^  TAG: *//p' "$work/nightly")
[[ $nightly == v0.1.0.nightly[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9] ]]
[[ $(git cat-file -t "refs/tags/$nightly") == commit ]]
git --git-dir="$work/origin.git" rev-parse -q --verify "refs/tags/$nightly" >/dev/null

# -r -f pushes an annotated vX.Y.Z tag from the NEWS.md heading.
"$helper" -r -f > "$work/release"
grep -qx '  TAG:      v0.2.0' "$work/release"
[[ $(git cat-file -t refs/tags/v0.2.0) == tag ]]
git --git-dir="$work/origin.git" rev-parse -q --verify refs/tags/v0.2.0 >/dev/null

# An already tagged release and a missing ci.yml release reference fail.
expect_failure "$helper" -r -f
grep -q 'tag v0.2.0 already exists locally' "$work/failure"
sed -i 's/release\.yml/ping-irc.yml/' .github/workflows/ci.yml
expect_failure "$helper"
grep -q 'ci.yml does not use' "$work/failure"
echo 'Release helper tests passed.'
