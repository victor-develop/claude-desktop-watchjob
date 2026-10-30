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
| `probe-slack.sh` | Slack, in one of three modes picked by `SLACK_MODE` (below) | `CHANNEL` `SELF` (+ `THREAD_TS` in `thread` mode) |
| `probe-pr-and-slack.sh` | a PR and one Slack thread as a *single* watch | `REPO` `PR` `GITHUB_SELF` `CHANNEL` `THREAD_TS` `SLACK_SELF` |
| `probe-http-json.sh` | any endpoint returning a JSON list | `URL` `MAP` |

`probe-slack.sh` has three modes:

| `SLACK_MODE` | Watches | Requests per poll | Use it for |
|---|---|---|---|
| `thread` | replies in the one thread at `THREAD_TS` | 1 | a discussion you started |
| `top-level` | top-level messages of a channel or DM, no threads | 1 | busy public channels |
| `all-threads` | top-level messages plus new replies in every thread under the last `THREAD_SCAN` (default 30) top-level messages | 2 in steady state; a thread with new replies costs one extra request on each of the next two polls | DMs, and anywhere a missed reply is costly |

Without `SLACK_MODE` it picks `thread` when `THREAD_TS` is set and `all-threads` otherwise. Use
`all-threads` for DMs: people sometimes answer inline and sometimes in a thread, and both have been
missed in practice. Slack's history endpoint never returns thread replies, so `all-threads` fetches
threads one by one — but only those that may have something new: it compares the parent's
`latest_reply` with the cursor when the CLI provides it, and otherwise keeps a small cache of each
thread's `reply_count` and newest reply `ts`, skipping threads whose count hasn't changed (confirmed on two polls) and whose
wake-worthy replies are all at or before the cursor. Because one poll reads several places at
different moments, items newer than `SNAPSHOT_LAG` seconds (default 10) are held back to the next
poll, so a reply fetched late can't push the cursor past a message that wasn't visible yet. All three modes use the Slack `ts` as the cursor and emit
the same item shape (`kind` is `slack-message` for top-level and `slack-reply` for replies;
`thread_ts` names the thread, `null` at top level), so you can switch modes without re-seeding.

`probe-slack-thread.sh` (= `thread`) and `probe-slack-channel.sh` (= `all-threads`, or `top-level`
with `EXCLUDE_REPLIES=1`) are kept as thin wrappers so existing watches keep working.

In `thread` mode the Slack template supports both slackcli command shapes, trying them in order and only
falling back if the first fails: `slackcli conversations read <channel> --thread-ts <ts>`
(0.9+) and `slackcli messages --channel <channel> --thread <ts>` (0.7 and older). It also
normalises their differing output — 0.9+ puts users in a top-level `users[]` and messages
carry only `.user`, so the template joins on id to recover display names, and it skips the
progress lines that build prints to stdout before the JSON. If neither shape works it exits 3
carrying both attempts' stderr, rather than degrading into "no new messages" — the failure
mode that is hardest to notice.

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
| 10 | new items | read `inbox.json`, handle, remove the handled ids with `watch-ack.sh`, relaunch |
| 11 | terminal condition | wrap up, don't relaunch |
| 12 | probe failed | read `signal.json` and `log`, fix before relaunching |
| 13 | hit `--max-runtime` | nothing happened; relaunch as-is |

`inbox.json` accumulates data items — the loop only ever merges into it, never discards unhandled
entries, and removing handled items is the agent's job — with `scripts/watch-ack.sh --ids …`, never by
overwriting the file with `[]`: in daemon mode new items can land while you are handling the old ones,
and a blind overwrite drops them without any error. `watch-ack.sh` shares a short lock with the loop. (`--seed` is the one exception: it resets the inbox,
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
./tests/test-templates.sh       # 68 assertions: template filtering, pagination, failure propagation
./tests/test-ack.sh             # 21 assertions: watch-ack contract, lock takeover, no lost items when racing the loop
./tests/test-slack-modes.sh     # 51 assertions: the three Slack modes, thread-reply pickup, cursor, skipped unchanged threads
```

None of them touch the network — `gh` and `slackcli` are replaced by stubs on `PATH`, and the
HTTP template is exercised over `file://`. All of them finish in seconds.

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
