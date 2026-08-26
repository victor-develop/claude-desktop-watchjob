# claude-desktop-watchjob

A watch loop for Claude Desktop that **costs zero tokens while nothing is happening**, and wakes
the agent only when a cursor diff says something actually changed.

```
a background shell loop            ← sleeping is free
  ├─ run a probe, diff against a cursor   ← all judgment happens in shell
  ├─ nothing new  → sleep, keep going
  └─ something new → write inbox.json → exit   ← exiting IS the wake-up
```

Launch it with the Bash tool's `run_in_background: true`. The script survives across turns, and
when it exits the harness wakes the agent and hands it the exit code. So the decision *"is this
worth interrupting the model for?"* runs in shell, for free.

Works for anything you can diff with a cursor: PR comments and reviews, CI status, Slack thread
replies, HTTP JSON endpoints, directory changes.

## Why not cron

Two approaches were tried first, on macOS with Claude Desktop. Both failed, for reasons worth
knowing before you reinvent them. Full evidence in [`references/mechanics.md`](references/mechanics.md).

**System cron can't authenticate.** `gh` stores its token in the login keyring. Cron runs in a
different bootstrap namespace and can't read it, so it sends unauthenticated requests — and a
private repo answers those with **404, not 401**. The logs look like you typed the path wrong.
(Cron's default `PATH` also excludes Homebrew, so `gh` isn't even found.)

**Rewriting the app's own scheduled-task file doesn't work either.** The idea was to have the
agent schedule a timer and let a shell guard push its fire time forward whenever nothing had
happened. Deleting or rescheduling a pending task from shell *does* work — but only while the
agent is inside an active turn. `scheduled_tasks.json` sits in the app's file-watcher **ignore
list**, so edits made while the agent is idle are never picked up — which is exactly when a
guard needs them. Also worth knowing: a scheduled task fires in whichever session holds the
scheduler lock, not the one that created it, and that lock can be taken over.

The background-shell approach has neither problem. Its output directory is keyed by session id,
so a wake-up always lands in the session that started it, and a background child inherits the
GUI session — so keyring-backed CLIs just work.

## Install

Drop it in as a Claude skill:

```bash
git clone https://github.com/victor-develop/claude-desktop-watchjob.git
cp -r claude-desktop-watchjob ~/.claude/skills/incremental-watch
```

`SKILL.md` carries the agent-facing instructions. Requires `bash`, `jq`, and whatever CLI your
probe uses.

## Usage

A **probe** is any executable that prints a JSON array, one element per item, each with a
sortable `at` field. The loop owns the cursor, the inbox, deduplication, locking and exit codes;
the probe owns "how do I read this source".

Ready-made probes live in [`scripts/templates/`](scripts/templates) and are configured
entirely through environment variables, so you point `--probe` straight at one — no editing:

```bash
export REPO=owner/repo PR=123 SELF=your-github-login

# 1. align the cursor first, or the first pass treats all history as new
scripts/watch-loop.sh --name pr-123 --probe scripts/templates/probe-github-pr.sh --seed

# 2. start the loop (from the agent: Bash tool, run_in_background: true)
scripts/watch-loop.sh --name pr-123 --probe scripts/templates/probe-github-pr.sh \
  --interval 120 --max-runtime 5400
```

| Template | Watches | Required env |
|---|---|---|
| `probe-github-pr.sh` | PR comments, inline review comments, review verdicts; terminal on merge/close | `REPO` `PR` `SELF` |
| `probe-github-checks.sh` | CI reaching a terminal state — green, red, cancelled or timed-out all wake you, in-flight doesn't | `REPO` `PR` |
| `probe-slack-thread.sh` | replies in one thread | `CHANNEL` `THREAD_TS` `SELF` |
| `probe-pr-and-slack.sh` | both of the above as a *single* watch | `REPO` `PR` `GITHUB_SELF` `CHANNEL` `THREAD_TS` `SLACK_SELF` |
| `probe-http-json.sh` | any endpoint returning a JSON list | `URL` `MAP` |

Each template's header comment documents its optional knobs (timeouts, body truncation, bot
filters). Writing your own is a matter of printing a JSON array — see
[`references/sources.md`](references/sources.md).

The GitHub PR template hits three separate endpoints — conversation comments, inline review
comments, and review verdicts — each with `--paginate`, because a PR with a hundred comments
would otherwise silently return only the first page. Every fetch's exit status is checked: if
one endpoint times out or gets rate-limited, the whole probe fails rather than returning partial
data, because partial data would advance the cursor past whatever it missed. Templates also
verify their CLIs (`gh`, `slackcli`, `jq`, `curl`) are installed up front and name the missing
one instead of failing halfway through.

| Exit | Meaning | What the agent does |
|---|---|---|
| 10 | new items | read `inbox.json`, handle, clear it, relaunch |
| 11 | terminal condition | wrap up, don't relaunch |
| 12 | probe failed | read `signal.json` and `log`, fix before relaunching |
| 13 | hit `--max-runtime` | nothing happened; relaunch as-is |

`inbox.json` accumulates data items — the loop only ever merges into it, never discards unhandled
entries, and clearing it is the agent's job. (`--seed` is the one exception: it resets the inbox,
so don't re-seed a watch that is already running.) `signal.json` says why the loop exited and is
overwritten each time. Keeping them apart matters: an earlier version wrote
both to one file, and a control signal could overwrite unhandled items — losing events silently.

Probe recipes for common sources are in [`references/sources.md`](references/sources.md).

## Two things that are easy to get wrong

**Filter out yourself and bots in the probe.** Otherwise your own reply wakes you up, and you
loop forever.

**Always set a timeout on network calls in the probe.** A crashed loop is safe — it exits, which
wakes the agent. A *hung* loop never exits and therefore never wakes anyone. That's the only
failure mode here without a built-in alarm.

The corollary is the nice part: if the loop dies, gets killed, or the probe breaks, the agent
finds out immediately. Silent failure is the usual curse of watch tooling, and this shape doesn't
have it.

## Cost model

Almost all the cost is in *waking up*, not in polling. Two levers, and the second one is the one
people miss:

1. **Wake less.** That's what the exit-code contract buys you.
2. **Don't drag raw data into context when you do wake.** Tool output stays in the conversation
   permanently and gets re-read on every later wake-up — compounding. Have the probe compress
   with `jq` and hand the agent a digest, not paginated JSON.

A corollary: N watches means N wake-ups. Split watches by *decision*, not by *data source* — a PR
and its Slack thread belong in one probe, because any activity on either leads to the same
judgment call.

## Tests

```bash
./tests/test-exit-codes.sh      # 28 assertions: exit-code contract, cursor, inbox safety
./tests/test-parallel.sh 5      #  8 assertions: N loops stay isolated
./tests/test-templates.sh       # 53 assertions: template filtering, pagination, failure propagation
```

None of them touch the network — `gh` and `slackcli` are replaced by stubs on `PATH`, and the
HTTP template is exercised over `file://`. All three finish in seconds.

## Limitations

- Quitting the app takes the loop with it — it's a child of the claude process. Nothing restarts
  it automatically.
- One loop per `--name` (directory lock): starting a second one exits 1 while the first is alive,
  and takes over the lock if the previous holder died. Different names run fully independently;
  5 in parallel is verified, higher counts are untested.
- The machine sleeping pauses the loop; it resumes on wake without catching up.
- Don't use this for work the harness already notifies you about (background tasks, subagents) —
  that's pure overhead.

## License

MIT
