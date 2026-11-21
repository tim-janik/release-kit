# release-kit

Shared release tooling for the tim-janik repositories. Everything is
maintained here once; consumers reference this repository at a pinned ref
and carry no copies, so a kit update needs no per-repository commits.

## Files

| file | purpose |
| --- | --- |
| `ircbot.py` | announces CI results on IRC |
| `test_ircbot.py` | unit tests for `ircbot.py` |
| `.github/workflows/ping-irc.yml` | reusable Ping-IRC job; callers pass `join(needs.*.result)`, no secrets required |
| `gh-release.sh` | builds release assets via `make distcheck` and creates the GitHub release |
| `release-test.sh` | offline tests for `gh-release.sh` |
| `.github/workflows/release.yml` | reusable Release job; callers pass docker-image, docker-env or setup inputs |
| `release-helper.sh` | maintainer tool: checks a consumer repo, pushes nightly/release tags |
| `release-helper-test.sh` | offline tests for `release-helper.sh` |
| `.github/workflows/ci.yml` | kit CI: runs the test suites, shellcheck and actionlint on every push to trunk |

## Consumer wiring

Announce CI results from any repository:

```yaml
  Ping-IRC:
    # !cancelled() && push on trunk or tag, needs: [ CI, Release ]
    uses: tim-janik/release-kit/.github/workflows/ping-irc.yml@trunk
    with: { jobs: "${{ join(needs.*.result, ' ') }}" }   # no secrets: inherit
```

Scheduled (nightly) runs carry no push payload, so they pass a `title` and
get "<title> <git describe --always> - <run URL>" announced; the kit checks
out the caller repository just to run `git describe`:

```yaml
  Ping-IRC:
    # schedule: cron '42 3 * * *', needs: [ Distcheck ]
    uses: tim-janik/release-kit/.github/workflows/ping-irc.yml@trunk
    with:
      jobs: "${{ join(needs.*.result, ' ') }}"
      title: 'Distcheck'
```

Publish releases: the kit checks out the caller and itself, builds assets via
`make distcheck` and creates the GitHub release (lightweight tags give public
prereleases, annotated tags drafts). The caller job keeps its own tag `if:`
and `needs:` and must grant `contents: write` so `github.token` may create
the release. Building inside a pinned docker image:

```yaml
  Release:
    if: github.ref_type == 'tag'        # constrained by on.push.tags
    needs: [ Build-And-Test ]
    permissions: { contents: write }    # allow github.token to create a release
    uses: tim-janik/release-kit/.github/workflows/release.yml@trunk
    with:
      docker-image: 'cimg/go:1.25.14@sha256:...'
      docker-env: 'GOTOOLCHAIN=local GOFLAGS=-mod=readonly'
```

Building on the runner instead, with setup commands run in the caller
checkout before the release:

```yaml
  Release:
    if: github.ref_type == 'tag'
    needs: [ Build-And-Test ]
    permissions: { contents: write }
    uses: tim-janik/release-kit/.github/workflows/release.yml@trunk
    with:
      setup: |
        sudo apt-get update
        sudo TZ=Etc/UTC DEBIAN_FRONTEND=noninteractive apt-get install -y tzdata nano tmux asciinema pv bsdextrautils
        make apt-deps-install
```

## Release helper

Maintainers check a consumer repository and push release tags with the
helper, run from inside the consumer checkout:

    /path/to/release-kit/release-helper.sh           # checks, shows nightly and release tag
    /path/to/release-kit/release-helper.sh -n -f     # push lightweight nightly tag
    /path/to/release-kit/release-helper.sh -r -f     # push annotated vX.Y.Z tag from NEWS.md

It verifies the `dist`/`distcheck` make rules, the ci.yml release workflow
wiring, a clean tree and origin coverage, then pushes the tag; CI creates the
GitHub release. The kit's CI runs `release-test.sh` and
`release-helper-test.sh`, consumers never run them.

## Development

Change the kit first, run `python3 test_ircbot.py`, `bash release-test.sh` and
`bash release-helper-test.sh`, push. The kit's CI runs the same tests on
every push to trunk, which is what allows consumers to pin `trunk`. Prefer a
tag when a consumer needs to stay behind a breaking kit change.
