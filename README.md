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
| `.github/workflows/build-and-test.yml` | reusable Build-And-Test job; callers pass make targets and artifact names |
| `.github/workflows/ci.yml` | kit CI: runs the test suite on every push to trunk |

## Consumer wiring

Announce CI results from any repository:

```yaml
  Ping-IRC:
    # !cancelled() && push on trunk or tag, needs: [ CI, Release ]
    uses: tim-janik/release-kit/.github/workflows/ping-irc.yml@trunk
    with: { jobs: "${{ join(needs.*.result, ' ') }}" }   # no secrets: inherit
```

Build and test a repository with make, upload artifacts:

```yaml
  Build-And-Test:
    uses: tim-janik/release-kit/.github/workflows/build-and-test.yml@trunk
    with:
      runs-on: ubuntu-24.04
      apt-packages: 'tzdata nano tmux asciinema pv bsdextrautils'
      make-targets: |
        apt-deps-install
        distcheck
      tarball-path: artifacts/example-*.tar.zst
      tarball-dir: /tmp/example
      tarball-targets: |
        all
        check
        sudo install
        installcheck
        sudo uninstall
      post: |
        if [[ $GITHUB_REF_TYPE != tag ]]; then .github/workflows/release-test.sh; fi
      artifact-name: Example-Artifacts
      artifact-path: artifacts/
```

The job checks out the caller with full history and tags, runs one `make -w`
invocation per `make-targets` line, optionally unpacks a dist tarball into
`tarball-dir` and runs `tarball-targets` there, runs `post`, then uploads up
to two artifacts (even after a failure). A `sudo` word in a target line runs
that invocation under sudo. Lines are word split into make arguments, no
shell substitution. Because caller workflow env does not reach called
workflows, differences become arguments: `make-env` exports `KEY=VALUE`
lines, `setup` and `post` run shell snippets, `apt-packages`,
`go-version-file`, `container` (a JSON mapping) and `submodules` configure
the environment. Container images must provide bash, git and make.
Consumers with mid-job ccache steps (anklang) keep a local
job until the kit grows cache support.

## Development

Change the kit first, run `python3 test_ircbot.py`, push. The kit's CI runs
the same test on every push to trunk, which is what allows consumers to pin
`trunk`. Prefer a tag when a consumer needs to stay behind a breaking kit
change.
