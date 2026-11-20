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
| `.github/workflows/ci.yml` | kit CI: runs the test suite on every push to trunk |

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

## Development

Change the kit first, run `python3 test_ircbot.py`, push. The kit's CI runs
the same test on every push to trunk, which is what allows consumers to pin
`trunk`. Prefer a tag when a consumer needs to stay behind a breaking kit
change.
