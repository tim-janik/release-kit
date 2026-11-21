#!/usr/bin/env bash
# This Source Code Form is licensed MPL-2.0: http://mozilla.org/MPL/2.0
set -Eeuo pipefail

ME=$(basename "$0")
die() { echo "${ME##*/}: ${*:-aborted}" >&2; exit 127; }

usage()
{
  cat <<EOF
Usage: ${ME##*/} [OPTIONS] [COMMITISH]

Check that a repository can release: a make rule builds the release artifacts
and CI publishes them via .github/workflows/release.yml. Then push a nightly
or release tag, CI creates the GitHub release.

Without options, run all checks and show the nightly and release tag.
COMMITISH (default: HEAD) selects the commit to check and tag. -r requires
it to be HEAD, since the release commit must match the working tree.

Options:
  -n, --nightly   Create lightweight tag VERSION.nightlyDATE and push it (prerelease)
  -r, --release   Create annotated tag vVERSION from the NEWS.md heading and push it
  -c, --cliff     Generate NEWS for unreleased commits via git-cliff into xnews.md
                  (cached xnews.md is shown again, -f regenerates it)
  -f, --force     Skip the confirmation prompt, regenerate cached xnews.md
  -x              Enable shell debugging
  -h, --help      Show this help text and exit
EOF
  exit 0
}

MODE=check
FORCE=0
COMMITISH=
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--nightly)	MODE=nightly ;;
    -r|--release)	MODE=release ;;
    -c|--cliff)		MODE=cliff ;;
    -f|--force)		FORCE=1 ;;
    -x)			set -x ;;
    -h|--help)		usage ;;
    -*)			die "unknown option: $1 (try --help)" ;;
    *)			[[ -z $COMMITISH ]] || die "unexpected argument: $1 (one COMMITISH max)"
    			COMMITISH=$1 ;;
  esac
  shift
done

git_root()
{
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die 'not inside a git repository'
  cd "$ROOT"
  URL=$(git remote get-url origin 2>/dev/null) || die "missing remote 'origin'"
}

run_checks()
{
  local MAKE_DB MAKEFILES
  MAKE_DB=$(make -pRrq : 2>/dev/null || :)
  MAKEFILES=$(sed -n 's/^MAKEFILE_LIST := //p' <<< "$MAKE_DB")
  [[ $MAKEFILES != *' '* ]] || MAKEFILES=${MAKEFILES%% *}...
  echo "  CHECKING  need distcheck and dist targets: ${MAKEFILES:-no makefile}"
  RULES=$(sed -n 's/^\(dist\|distcheck\):.*/\1/p' <<< "$MAKE_DB" | sort -u | paste -sd' ' || :)
  [[ " $RULES " == *' distcheck '* && " $RULES " == *' dist '* ]] ||
    die "missing 'distcheck' or 'dist' target (found: ${RULES:-none})"

  echo "  CHECKING  CI release automation: .github/workflows/ci.yml"
  grep -q 'release-kit/\.github/workflows/release\.yml' .github/workflows/ci.yml 2>/dev/null ||
    die 'ci.yml does not use release-kit/.github/workflows/release.yml'

  echo "  CHECKING  clean working tree"
  if git diff --quiet $TARGET --; then
    echo "  CHECKED   working tree is clean"
  else
    echo "  WARNING   working tree differs from $TARGET" >&2
  fi

  if [[ -z $(git branch -r --contains $TARGET --list 'origin/*') ]]; then
    die "$TARGET is not on any cached origin branch (try 'git fetch origin' or 'git push origin $BRANCH')"
  fi
  echo "  CHECKED   $TARGET @ origin (cached branches): yes"
}

nightly_tag()
{
  local BASE
  BASE=$(git describe --match='v[0-9]*.[0-9]*.[0-9]*' "$TARGET" 2>/dev/null) || return 1
  printf '%s.nightly%s\n' "${BASE%%-*}" "$(date --utc +%y%m%d%H%M)"
}

release_tag()
{
  [[ -f NEWS.md ]] || return 1
  local V
  V=$(sed -nr '1{ /^##/{ s/.*\bv?([0-9]+\.[0-9]+\.[0-9]+[_a-z.0-9+-]*)\b.*/\1/; tPRNT; q; :PRNT p } }' NEWS.md)
  [[ -n $V ]] || return 1
  printf 'v%s\n' "$V"
}

run_cliff()
{
  if [[ -s xnews.md && $FORCE -eq 0 ]]; then
    echo "  CLIFF     cached xnews.md (use -f to regenerate)"
    cat xnews.md
    return 0
  fi
  [[ ($URL == *://* || $URL == *@*) && "$OWNER/$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
    die "cannot derive GitHub owner/repo from origin: $URL"
  echo "  CLIFF     $GH_REPO > xnews.md"
  WORK=$(mktemp -d /tmp/release-cliff-XXXXXX)
  trap 'rm -rf "$WORK"' EXIT
  CONFIG=$WORK/cliff.toml
  OUT=$WORK/news.md
  cat > "$CONFIG" <<'CLIFF_EOF'
# git-cliff ~ default configuration file
# https://git-cliff.org/docs/configuration
[remote.github]
owner = "OWNER"
repo = "REPO"
[changelog]
# template for the changelog header
header = """
# Changelog\n
All notable changes to this project will be documented in this file.\n
"""
# template for the changelog body, https://keats.github.io/tera/docs/#introduction
body = """
{% raw %}\n{% endraw -%}
{% if version %}\
    ## [{{ version | trim_start_matches(pat="v") }}] - {{ timestamp | date(format="%Y-%m-%d") }}
{% else %}\
    ## [unreleased]
{% endif %}\
{% for group, commits in commits | group_by(attribute="group") %}
    ### {{ group | upper_first | trim }}:
    {%- for commit in commits | unique(attribute="message") %}
        * {% if commit.scope %}*({{ commit.scope }})* {% endif %}\
            {% if commit.breaking %}[**breaking**] {% endif %}\
            {{ commit.message | split(pat="\n") | first | upper_first | trim }}\
              {% for link in commit.links | unique(attribute="href") %} \n{{ link.href }}{%- endfor -%}\
              {% if commit.remote.pr_number %}, #{{ commit.remote.pr_number }}{%- endif %}\
    {% endfor %}
{% endfor %}\n
{%- if github -%}
{% if github.contributors | length != 0 %}
  ### Contributors
  Thanks to everyone who made this release happen!
{% for contributor in github.contributors %}
  * @{{ contributor.username }}
{%- endfor -%}
{%- endif %}
{%- endif %}
{% raw %}\n{% endraw -%}
"""
# template for the changelog footer
footer = """
<!-- generated by git-cliff -->
"""
# remove the leading and trailing s
trim = true
# postprocessors
postprocessors = [
  # { pattern = '<REPO>', replace = "https://github.com/orhun/git-cliff" }, # replace repository URL
CLIFF_EOF
  # github-username-expander is a personal tool that may be missing.
  if command -v github-username-expander >/dev/null; then
    printf "  { pattern = '.*', replace_command = 'github-username-expander -' },  # '@jd' -> 'John Doe (@jd)'\n" >> "$CONFIG"
  fi
  cat >> "$CONFIG" <<'CLIFF_EOF'
  # Allow non-trimmed Tabs via special marker
  { pattern = '§', replace = '	' },
]
[git]
# parse the commits based on https://www.conventionalcommits.org
conventional_commits = true
# filter out the commits that are not conventional
filter_unconventional = false
# process each line of a commit as an individual commit
split_commits = false
# regex for preprocessing the commit messages
commit_preprocessors = [
  { pattern = 'Signed-off-by.*', replace = "" },
]
# regex for parsing and grouping commits
commit_parsers = [
  { message = "\\b[Aa]dd", group = "Added" },
  { message = "\\b[Ss]upport", group = "Added" },
  { message = "\\b[Ii]mplement", group = "Added" },
  { message = "\\b[Rr]emove", group = "Removed" },
  { message = "\\b[Dd]elete", group = "Removed" },
  { message = "\\b[Ss]kip", group = "Removed" },
  { message = "\\b[Dd]eprecate", body = "\\b[Dd]eprecate", group = "Deprecation" },
  { message = "\\b[Bb]reaking", body = "\\b[Bb]reaking", group = "Breaking" },
  { message = "\\b[Dd]epend", body = "\\b[Dd]epend", group = "Breaking" },
  { message = "\\b[Tt]est", group = "Fixed" },
  { message = "\\b[Ff]ix", group = "Fixed" },
  { message = "\\b[Ee]nsure", group = "Fixed" },
  { message = "^.*", group = "Changed" },
]
# https://git-cliff.org/docs/configuration/git/
link_parsers = [
  # Turn every #123 into a clickable GitHub issue link
  { pattern = "#(\\d+)\\b", href = "<REPO>/issues/$1" },
]
# Fail on a commit that is not matched by any commit parser.
fail_on_unmatched_commit = true
# filter out the commits that are not matched by commit parsers
filter_commits = false
# Any breaking changes will be protected against being skipped
protect_breaking_commits = true
# sort the tags topologically
topo_order = true
# sort the commits inside sections by oldest/newest order
sort_commits = "newest"
CLIFF_EOF
  command -v git-cliff >/dev/null || die 'git-cliff not installed'
  # git-cliff queries the GitHub API; a token avoids rate limits, none is fine too.
  if [[ -z ${GITHUB_TOKEN-} ]] && command -v gh >/dev/null; then
    export GITHUB_TOKEN=$(gh auth token 2>/dev/null || :)
  fi
  git-cliff -c "$CONFIG" --github-repo "$GH_REPO" -s all -u --tag-pattern '^v\d+\.\d+\.\d+$' | tee "$OUT" || die 'git-cliff failed'
  mv "$OUT" xnews.md
}

push_tag()
{
  echo "  CHECKING  tag $TAG is unused locally"
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    die "tag $TAG already exists locally"
  fi
  echo "  CHECKING  tag $TAG is unused on origin"
  if git ls-remote --exit-code origin "refs/tags/$TAG" >/dev/null 2>&1; then
    die "tag $TAG already exists on origin"
  fi
  git -P log --graph -1 --oneline "$TARGET"
  [[ $FORCE -eq 1 ]] || {
    local Y=
    read -r -e -p "Push \`${COMMITISH:-$BRANCH}\` tagged as $TAG (y/n) ? " Y || die
    [[ $Y == [YyJj1]* ]] || die
  }
  set -x
  if [[ $MODE == release ]]; then
    git tag -m "$REPO ${TAG#v}" "$TAG" $TARGET
  else
    git tag "$TAG" $TARGET
  fi
  git push origin "$TAG"
}

git_root
URL=${URL%/}
URL=${URL%.git}
REPO=${URL##*/}
OWNER=${URL%/*}
OWNER=${OWNER##*[/:]}
GH_REPO=$OWNER/$REPO
BRANCH=$(git symbolic-ref --short -q HEAD || echo HEAD)

if [[ -n $COMMITISH ]]; then
  git rev-parse -q --verify "${COMMITISH}^{commit}" >/dev/null || die "cannot resolve commit: $COMMITISH"
fi
TARGET=${COMMITISH:-HEAD}

if [[ $MODE == cliff ]]; then
  [[ -z $COMMITISH ]] || die "COMMITISH does not apply to -c"
  run_cliff
  exit 0
fi

if [[ $MODE == release && $(git rev-parse "$TARGET") != $(git rev-parse HEAD) ]]; then
  die "-r requires COMMITISH to be HEAD (release commit must match the working tree)"
fi

run_checks
FAIL=0
case $MODE in
  check)
    if TAG=$(nightly_tag); then
      echo "  NIGHTLY   will tag: $TAG"
    else
      echo "  NIGHTLY   FAIL: no version tag to derive from"
      FAIL=1
    fi
    if TAG=$(release_tag); then
      echo "  RELEASE   ok: $TAG"
    else
      echo "  RELEASE   FAIL: no release version at top of NEWS.md"
      FAIL=1
    fi
    exit $FAIL ;;
  nightly)
    TAG=$(nightly_tag) || die 'cannot derive nightly tag (no version tag?)' ;;
  release)
    TAG=$(release_tag) || die 'no release version at top of NEWS.md' ;;
esac
echo "  PACKAGE:  $REPO"
echo "  TAG:      $TAG"
push_tag
