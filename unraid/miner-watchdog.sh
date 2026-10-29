#!/usr/bin/env bash
# miner-watchdog.sh - restart the Twitch Drops Miner container when it freezes and file a
# Todoist card. Run every 5 minutes (Unraid User Scripts, schedule */5 * * * *).
#
# Why: when the miner hits a fatal error it does not exit, it sits on "Application
# Terminated" forever. Its Docker health check then says "unhealthy", but nothing on Unraid
# restarts unhealthy containers.
#
# Settings (environment variables, all optional):
#   MW_CONTAINER   container to watch                  (default: twitch-drops-miner)
#   MW_STATE_DIR   where state and saved logs live     (default: /mnt/user/appdata/miner-watchdog)
#   MW_ALERT_CMD   command called as: $MW_ALERT_CMD "<title>" "<description>"
#                  (default: file the card through the Hermes-WebUI Todoist helper)
#   MW_NOW         pretend the time is this epoch second (tests only)
#
# Exit code: 0 = the run was clean, 1 = something went wrong (also written to the system log
# with `logger -t miner-watchdog` and to stderr).

set -uo pipefail
shopt -s nullglob
umask 077 # runs as root; saved logs and state are for root only

CONTAINER=${MW_CONTAINER:-twitch-drops-miner}
STATE_DIR=${MW_STATE_DIR:-/mnt/user/appdata/miner-watchdog}
ALERT_CMD=${MW_ALERT_CMD:-}
if [[ -n ${MW_NOW:-} ]]; then NOW=$MW_NOW; else printf -v NOW '%(%s)T' -1; fi

HERMES_CONTAINER=Hermes-WebUI
HERMES_PY="import sys; sys.path.insert(0,'/opt/data/scripts'); import todoist_tasks as t; sys.exit(0 if t.alert_automation_issue(sys.argv[1], sys.argv[2]) else 1)"

RESTART_WINDOW=$((6 * 3600)) # budget: MAX_RESTARTS restarts per this many seconds
MAX_RESTARTS=3
CARD_COOLDOWN=$((6 * 3600))   # same kind of card at most this often
MISSING_COOLDOWN=$((24 * 3600))
KEEP_LOGS=10
LOG_LINES=150
ALERT_TIMEOUT=90

RC=0 # becomes 1 if anything goes wrong during this run

log() {
  echo "miner-watchdog: $*" >&2
  if command -v logger >/dev/null 2>&1; then
    logger -t miner-watchdog -- "$*" || echo "miner-watchdog: logger failed" >&2
  fi
}

# put FILE TEXT: replace FILE with TEXT (atomically). A state file we cannot write is fatal.
put() {
  local f=$1
  shift
  if ! { printf '%s\n' "$*" >"$f.tmp" && mv -f "$f.tmp" "$f"; }; then
    log "ERROR: cannot write $f"
    exit 1
  fi
}

# read_num FILE: print the whole number stored in FILE, or 0 if it is missing or corrupt.
# Never use a state file's text in (( )) unchecked: bash runs $(...) found inside it.
read_num() {
  local v=0
  [[ -f $1 ]] || { echo 0; return 0; }
  v=$(<"$1")
  if [[ ! $v =~ ^[0-9]+$ ]]; then
    log "ignoring corrupt state file $1"
    v=0
  fi
  echo "$v"
}

STAMP="" # NOW as 20261028T093000Z (UTC), set in main
ISO=""   # NOW as 2026-10-28T09:30:00Z (UTC), set in main

# ------------------------------------------------------------------ cards

run_alert() { # run_alert TITLE DESCRIPTION
  if [[ -n $ALERT_CMD ]]; then
    local -a cmd
    read -r -a cmd <<<"$ALERT_CMD"
    timeout "$ALERT_TIMEOUT" "${cmd[@]}" "$1" "$2" >&2
  else
    timeout "$ALERT_TIMEOUT" docker exec "$HERMES_CONTAINER" /opt/hermes/.venv/bin/python -c "$HERMES_PY" "$1" "$2" >&2
  fi
}

# deliver KIND: send the pending card for KIND. On success clear it and start its cooldown.
deliver() {
  local kind=$1 pend="$STATE_DIR/pending-$1" title desc n
  { IFS= read -r title; desc=$(cat); } <"$pend"
  n=$(read_num "$STATE_DIR/suppressed-$kind")
  if ((n > 0)); then
    desc+=$'\n\n'"$n more since last card."
  fi
  if run_alert "$title" "$desc"; then
    rm -f "$pend" "$STATE_DIR/suppressed-$kind"
    put "$STATE_DIR/card-$kind.ts" "$NOW"
    return 0
  fi
  log "ERROR: could not file card '$title'; keeping it pending and retrying next run"
  RC=1
  return 1
}

bump_suppressed() {
  local f="$STATE_DIR/suppressed-$1" n
  n=$(read_num "$f")
  put "$f" $((n + 1))
}

# send_card KIND COOLDOWN_SECONDS TITLE DESCRIPTION
send_card() {
  local kind=$1 cooldown=$2 title=$3 desc=$4 last
  if [[ -f $STATE_DIR/pending-$kind ]]; then
    bump_suppressed "$kind" # an earlier card of this kind is still waiting to be sent
    return 0
  fi
  last=$(read_num "$STATE_DIR/card-$kind.ts")
  if ((NOW - last < cooldown)); then
    bump_suppressed "$kind"
    return 0
  fi
  put "$STATE_DIR/pending-$kind" "$title"$'\n'"$desc"
  deliver "$kind"
}

# problem KIND SHORT DETAIL: the watchdog itself hit a problem. Log it, fail the run, file a card.
problem() {
  log "ERROR: $2: $3"
  RC=1
  send_card "$1" "$CARD_COOLDOWN" "miner-watchdog problem: $2" "$3"
}

retry_pending() {
  local f kind
  for f in "$STATE_DIR"/pending-*; do
    kind=${f##*/pending-}
    deliver "$kind" || true # failure already logged and RC set
  done
}

# ------------------------------------------------------------------ freeze handling

RESTART_COUNT=0
prune_restarts() { # drop restarts outside the window; count the rest
  local f="$STATE_DIR/restarts.log" t kept=""
  RESTART_COUNT=0
  [[ -f $f ]] || return 0
  while read -r t; do
    [[ $t =~ ^[0-9]+$ ]] || continue
    if ((t > NOW - RESTART_WINDOW)); then
      kept+="$t"$'\n'
      RESTART_COUNT=$((RESTART_COUNT + 1))
    fi
  done <"$f"
  if ! { printf '%s' "$kept" >"$f.tmp" && mv -f "$f.tmp" "$f"; }; then
    log "ERROR: cannot update $f"
    exit 1
  fi
}

key_errors() { # key_errors LOGFILE
  local out
  out=$(grep -E -A3 'Traceback|[Ff]atal|FATAL|Exception' "$1" | tail -n 40)
  if [[ -z $out ]]; then
    out="(no Traceback/Fatal/Exception lines; last 10 log lines)"$'\n'$(tail -n 10 "$1")
  fi
  printf '%s' "$out"
}

handle_freeze() {
  prune_restarts
  if ((RESTART_COUNT >= MAX_RESTARTS)); then
    local files=("$STATE_DIR"/freeze-*.log) latest="none saved"
    ((${#files[@]} > 0)) && latest=${files[${#files[@]} - 1]}
    send_card keepfreezing "$CARD_COOLDOWN" \
      "$CONTAINER keeps freezing; watchdog stopped restarting it" \
      "The container is unhealthy again, but it was already restarted $RESTART_COUNT times in the last 6 hours, so the watchdog is NOT restarting it any more. It stays frozen until someone looks at it. Latest saved freeze log: $latest (all in $STATE_DIR)."
    return 0
  fi

  local logfile="$STATE_DIR/freeze-$STAMP.log" logmsg="" out
  if ! docker logs --tail "$LOG_LINES" "$CONTAINER" >"$logfile" 2>&1; then
    log "ERROR: docker logs failed for $CONTAINER"
    RC=1
    logmsg=" (docker logs failed; the saved file may be incomplete)"
  fi
  local files=("$STATE_DIR"/freeze-*.log) extra
  if ((${#files[@]} > KEEP_LOGS)); then
    extra=$((${#files[@]} - KEEP_LOGS))
    rm -f -- "${files[@]:0:extra}"
  fi

  if ! out=$(docker restart "$CONTAINER" 2>&1); then
    problem restartfailed "could not restart $CONTAINER" "docker restart failed: $out. Saved log: $logfile"
    return 0
  fi
  printf '%s\n' "$NOW" >>"$STATE_DIR/restarts.log" || {
    log "ERROR: cannot record restart in $STATE_DIR/restarts.log"
    exit 1
  }
  send_card froze "$CARD_COOLDOWN" \
    "$CONTAINER froze and was restarted (watchdog)" \
    "The health check reported unhealthy; the watchdog restarted the container at $ISO.

Key error lines:
$(key_errors "$logfile")

Saved log (last $LOG_LINES lines)$logmsg: $logfile"
}

handle_stopped() { # handle_stopped EXITCODE FINISHEDAT
  local code=$1 finished=$2
  if [[ -f $STATE_DIR/last-stopped && $(<"$STATE_DIR/last-stopped") == "$finished" ]]; then
    return 0 # already carded this stop
  fi
  put "$STATE_DIR/last-stopped" "$finished"
  send_card stopped "$CARD_COOLDOWN" \
    "$CONTAINER stopped with exit code $code (watchdog)" \
    "The container is not running. It exited with code $code at $finished. The watchdog did NOT start it (it could have been stopped on purpose). Check with: docker logs --tail 100 $CONTAINER"
}

# ------------------------------------------------------------------ main

if ! mkdir -p "$STATE_DIR"; then
  log "ERROR: cannot create state dir $STATE_DIR"
  exit 1
fi
if [[ ! $NOW =~ ^[0-9]+$ ]]; then
  log "ERROR: bad time value '$NOW'"
  exit 1
fi
# bash built-in printf: no extra processes
TZ=UTC0 printf -v STAMP '%(%Y%m%dT%H%M%SZ)T' "$NOW"
TZ=UTC0 printf -v ISO '%(%Y-%m-%dT%H:%M:%SZ)T' "$NOW"

retry_pending

fmt='{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.State.ExitCode}}|{{.State.FinishedAt}}'
if ! info=$(docker inspect -f "$fmt" "$CONTAINER" 2>&1); then
  if names=$(docker ps -a --format '{{.Names}}' 2>&1); then
    if grep -Fxq -- "$CONTAINER" <<<"$names"; then
      problem inspectfailed "could not inspect $CONTAINER" "docker inspect failed: $info"
    else
      send_card missing "$MISSING_COOLDOWN" \
        "$CONTAINER container not found (watchdog)" \
        "There is no container named $CONTAINER on this server, so the watchdog cannot check it. Was it removed or renamed?"
    fi
  else
    problem dockerdown "docker is not answering" "docker inspect and docker ps both failed: $names"
  fi
  exit "$RC"
fi

IFS='|' read -r status health code finished <<<"$info"
if [[ -z $status || ! $code =~ ^[0-9]+$ ]]; then
  problem badinspect "unreadable docker inspect output" "Expected status|health|exitcode|finishedat, got: $info"
  exit "$RC"
fi

if [[ $status == running ]]; then
  case $health in
    unhealthy) handle_freeze ;;
    healthy | starting | none) put "$STATE_DIR/last-ok" "$ISO" ;;
    *) problem badhealth "unknown health status" "Docker reported health status '$health' for $CONTAINER" ;;
  esac
elif ((code != 0)); then
  handle_stopped "$code" "$finished"
fi

exit "$RC"
