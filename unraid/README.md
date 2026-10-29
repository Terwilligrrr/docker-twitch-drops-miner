# Miner watchdog (Unraid)

`miner-watchdog.sh` restarts the `twitch-drops-miner` container when it freezes, and files a
Todoist card in "Automation Workflow Issues" (undated) so the failure is never silent.

## Why

When the miner hits a fatal error it does not exit: it sits on "Application Terminated"
forever. Docker's health check then reports `unhealthy`, but Unraid does not restart
unhealthy containers (the restart policy is `no`). On 2026-10-28 it sat frozen for 8 hours.

## What it does (each run)

| Container state | Action |
|---|---|
| running, health `healthy` / `starting` / none | writes `last-ok` (a heartbeat) |
| running, `unhealthy` | saves the last 150 log lines to `freeze-<UTC time>.log` (newest 10 kept), runs `docker restart`, files a card with the key error lines |
| `unhealthy` but already restarted 3 times in 6 h | does NOT restart; files a "keeps freezing" card |
| stopped with a non-zero exit code | files one card per stop (per `FinishedAt`); does NOT start it |
| stopped with exit code 0 | nothing (could be deliberate) |
| container missing | files a card, at most once per 24 h |

The same kind of card is filed at most once per 6 h. Skipped cards are counted, and the next
card says "N more since last card". If the card cannot be filed, the watchdog logs it
(`logger -t miner-watchdog` and stderr), keeps the card pending in the state folder, retries
it on the next run, and exits 1. Any problem exits non-zero. Errors never delete state.

If the Hermes-WebUI container is down when a card is due, the card waits and is retried
every 5 minutes until it goes through.

## Install (on the server, done by Allen or the director, not by this PR)

1. Unraid: Settings > User Scripts > Add New Script, name it `miner-watchdog`.
2. Paste the contents of `miner-watchdog.sh` into the script.
3. Schedule: Custom, `*/5 * * * *`.
4. Run it once by hand ("Run Script") and check that `/mnt/user/appdata/miner-watchdog/last-ok`
   appears.

Settings are environment variables with defaults: `MW_CONTAINER` (`twitch-drops-miner`),
`MW_STATE_DIR` (`/mnt/user/appdata/miner-watchdog`), `MW_ALERT_CMD` (default: file the card
through the Hermes-WebUI Todoist helper). To change one, add `export MW_CONTAINER=...` above
the script body. `MW_NOW` (a fake clock) is for the tests only.

The watchdog is not a watchdog for itself: if the schedule stops or the server is off, nothing
says so. `last-ok` is the heartbeat for a separate check.

## Test

```
bash unraid/test_miner_watchdog.sh
```

Needs only bash 5 (and `timeout`, `date -d`, `grep`: standard on Unraid and Git Bash). It uses
a fake `docker` and a fake alert command, a temp state folder and a fake clock, so it does not
touch Docker, Todoist or the network. Expect `14 passed, 0 failed`.
