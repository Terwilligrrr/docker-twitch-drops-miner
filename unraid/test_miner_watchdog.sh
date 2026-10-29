#!/usr/bin/env bash
# Tests for miner-watchdog.sh. Plain bash, no network, no sleeps.
# Run:  bash unraid/test_miner_watchdog.sh
#
# A fake `docker` (put first on PATH) is driven by files in a temp dir; a fake alert
# command records every card it is asked to file. Time is faked with MW_NOW.

set -u
shopt -s nullglob
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WATCHDOG="$HERE/miner-watchdog.sh"
BASE=1800000000 # a fixed "now" (epoch seconds)
H=3600

T=""    # per-test temp dir
F=""    # fake docker control dir
S=""    # state dir
RC=0    # exit code of the last watchdog run
ERR=""  # stderr file of the last watchdog run

# ---------------------------------------------------------------- harness

setup() {
  T=$(mktemp -d)
  F="$T/fake"
  S="$T/state"
  ERR="$T/stderr"
  mkdir -p "$F/alerts" "$T/bin"
  : >"$F/calls"

  cat >"$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
d="$FAKE_DIR"
printf '%s\n' "$*" >>"$d/calls"
case "$1" in
  inspect)
    [ -f "$d/inspect" ] && cat "$d/inspect"
    if [ -f "$d/inspect_rc" ]; then echo "Error: No such object" >&2; exit "$(cat "$d/inspect_rc")"; fi
    exit 0 ;;
  ps)
    [ -f "$d/ps" ] && cat "$d/ps"
    [ -f "$d/ps_rc" ] && { echo "Cannot connect to the Docker daemon" >&2; exit "$(cat "$d/ps_rc")"; }
    exit 0 ;;
  logs)
    [ -f "$d/logs" ] && cat "$d/logs"
    exit 0 ;;
  restart)
    printf '%s\n' "$*" >>"$d/restarts"
    [ -f "$d/restart_rc" ] && { echo "restart failed" >&2; exit "$(cat "$d/restart_rc")"; }
    exit 0 ;;
  exec)
    printf '%s\n' "$@" >"$d/exec_args"
    exit 0 ;;
esac
echo "fake docker: unexpected command: $*" >&2
exit 99
EOF

  cat >"$T/alert" <<'EOF'
#!/usr/bin/env bash
d="$FAKE_DIR"
shopt -s nullglob
a=("$d"/alerts/*.title)
n=$((${#a[@]} + 1))
printf '%s' "$1" >"$d/alerts/$n.title"
printf '%s' "$2" >"$d/alerts/$n.desc"
[ -f "$d/alert_fail" ] && { echo "alert backend down" >&2; exit 1; }
exit 0
EOF
  chmod +x "$T/bin/docker" "$T/alert"
}

teardown() { rm -rf "$T"; }

# set_inspect STATUS HEALTH EXITCODE FINISHEDAT
set_inspect() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >"$F/inspect"; }

# run_wd [NOW_OFFSET_SECONDS] [env assignments...]: runs the watchdog, sets RC.
run_wd() {
  local off=${1:-0}
  shift || true
  RC=0
  env PATH="$T/bin:$PATH" FAKE_DIR="$F" MW_STATE_DIR="$S" MW_ALERT_CMD="$T/alert" \
    MW_NOW=$((BASE + off)) "$@" bash "$WATCHDOG" >"$T/stdout" 2>"$ERR" || RC=$?
}

alerts_count() { local a=("$F"/alerts/*.title); echo "${#a[@]}"; }
restarts_count() {
  local n=0 line
  [ -f "$F/restarts" ] && while read -r line; do n=$((n + 1)); done <"$F/restarts"
  echo "$n"
}
alert_title() { echo "$(<"$F/alerts/$1.title")"; }
alert_desc() { echo "$(<"$F/alerts/$1.desc")"; }

die() { echo "    ASSERT FAILED: $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || die "$3: expected '$2', got '$1'"; }
assert_contains() { case "$1" in *"$2"*) ;; *) die "$3: '$2' not found in: $1" ;; esac; }
assert_file() { [ -s "$1" ] || die "expected non-empty file $1"; }
assert_no_file() { [ ! -e "$1" ] || die "did not expect $1"; }

# ---------------------------------------------------------------- tests

test_healthy_writes_last_ok() {
  local h
  for h in healthy starting none; do
    rm -f "$S/last-ok"
    set_inspect running "$h" 0 "0001-01-01T00:00:00Z"
    run_wd
    assert_eq "$RC" 0 "exit code ($h)"
    assert_file "$S/last-ok"
    assert_eq "$(restarts_count)" 0 "restarts ($h)"
    assert_eq "$(alerts_count)" 0 "alerts ($h)"
  done
}

test_unhealthy_restarts_and_files_card() {
  set_inspect running unhealthy 0 "0001-01-01T00:00:00Z"
  printf 'info line\nTraceback (most recent call last):\n  File "x.py", line 1\nRuntimeError: boom\nApplication Terminated\n' >"$F/logs"
  run_wd
  assert_eq "$RC" 0 "exit code"
  assert_eq "$(restarts_count)" 1 "restarts"
  assert_contains "$(<"$F/restarts")" "restart twitch-drops-miner" "restart target"
  assert_contains "$(<"$F/calls")" "logs --tail 150 twitch-drops-miner" "log capture call"
  assert_eq "$(alerts_count)" 1 "alerts"
  assert_eq "$(alert_title 1)" "twitch-drops-miner froze and was restarted (watchdog)" "title"
  assert_contains "$(alert_desc 1)" "RuntimeError: boom" "key error in card"
  local logfile
  local lf=("$S"/freeze-*.log)
  logfile=${lf[0]}
  assert_contains "$(alert_desc 1)" "$logfile" "log path in card"
  assert_contains "$(<"$logfile")" "Application Terminated" "saved log content"
}

test_state_files_are_never_run_as_code() {
  mkdir -p "$S"
  local f payload="x[\$(touch $T/pwned)]"
  for f in suppressed-froze card-froze.ts suppressed-stopped card-stopped.ts; do
    printf '%s\n' "$payload" >"$S/$f"
  done
  printf '%s\n' "$payload" >"$S/restarts.log"
  set_inspect running unhealthy 0 "0001-01-01T00:00:00Z"
  run_wd
  set_inspect exited none 1 "2026-10-28T20:00:00Z"
  run_wd
  assert_no_file "$T/pwned"
  assert_eq "$(alerts_count)" 2 "corrupt state reads as 0, so both cards go out"
  assert_contains "$(<"$ERR")" "ignoring corrupt" "corrupt state is logged"
}

test_freeze_logs_keep_newest_10() {
  mkdir -p "$S"
  local i
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do : >"$S/freeze-202601${i}T000000Z.log"; done
  set_inspect running unhealthy 0 "0001-01-01T00:00:00Z"
  run_wd
  assert_eq "$RC" 0 "exit code"
  local kept=("$S"/freeze-*.log)
  assert_eq "${#kept[@]}" 10 "kept log files"
  assert_no_file "$S/freeze-20260101T000000Z.log"
  assert_no_file "$S/freeze-20260103T000000Z.log"
  [ -e "$S/freeze-20260112T000000Z.log" ] || die "newest old log was deleted"
}

test_restart_budget_blocks_fourth_restart() {
  mkdir -p "$S"
  printf '%s\n%s\n%s\n' $((BASE - 100)) $((BASE - 2 * H)) $((BASE - 5 * H)) >"$S/restarts.log"
  set_inspect running unhealthy 0 "0001-01-01T00:00:00Z"
  run_wd
  assert_eq "$RC" 0 "exit code"
  assert_eq "$(restarts_count)" 0 "restarts"
  assert_eq "$(alerts_count)" 1 "alerts"
  assert_eq "$(alert_title 1)" "twitch-drops-miner keeps freezing; watchdog stopped restarting it" "title"
  # still frozen five minutes later: no restart, no second card
  run_wd 300
  assert_eq "$(restarts_count)" 0 "restarts after rerun"
  assert_eq "$(alerts_count)" 1 "alerts after rerun"
}

test_old_restarts_do_not_count() {
  mkdir -p "$S"
  printf '%s\n%s\n%s\n' $((BASE - 6 * H - 1)) $((BASE - 7 * H)) $((BASE - 9 * H)) >"$S/restarts.log"
  set_inspect running unhealthy 0 "0001-01-01T00:00:00Z"
  run_wd
  assert_eq "$(restarts_count)" 1 "restart happens when old restarts expired"
  assert_eq "$(alert_title 1)" "twitch-drops-miner froze and was restarted (watchdog)" "title"
}

test_exited_nonzero_cards_once_per_finishedat() {
  set_inspect exited none 2 "2026-10-28T01:02:03Z"
  run_wd
  assert_eq "$RC" 0 "exit code"
  assert_eq "$(alerts_count)" 1 "alerts"
  assert_contains "$(alert_title 1)" "stopped with exit code 2" "title"
  assert_eq "$(restarts_count)" 0 "must not start it"
  run_wd 300
  assert_eq "$(alerts_count)" 1 "same FinishedAt: no second card"
  # a different stop, after the cooldown: new card
  set_inspect exited none 1 "2026-10-28T09:00:00Z"
  run_wd $((7 * H))
  assert_eq "$(alerts_count)" 2 "new FinishedAt: new card"
  assert_contains "$(alert_title 2)" "stopped with exit code 1" "second title"
  assert_eq "$(restarts_count)" 0 "still not started"
}

test_exited_zero_does_nothing() {
  set_inspect exited none 0 "2026-10-28T01:02:03Z"
  run_wd
  assert_eq "$RC" 0 "exit code"
  assert_eq "$(alerts_count)" 0 "alerts"
  assert_eq "$(restarts_count)" 0 "restarts"
}

test_stopped_by_docker_stop_does_nothing() {
  local c
  for c in 137 143; do
    set_inspect exited none "$c" "2026-10-28T04:0$((c % 10)):00Z"
    run_wd
    assert_eq "$RC" 0 "exit code ($c)"
  done
  assert_eq "$(alerts_count)" 0 "a docker stop (SIGTERM/SIGKILL) is not a crash"
}

test_overlapping_run_does_nothing() {
  mkdir -p "$S/lock"
  echo $$ >"$S/lock/pid" # this test shell is alive, so the lock is held
  set_inspect running unhealthy 0 "0001-01-01T00:00:00Z"
  run_wd
  assert_eq "$RC" 1 "an overlap means something is slow: fail the run"
  assert_eq "$(restarts_count)" 0 "no second restart while a run is going"
  assert_contains "$(<"$ERR")" "still running" "overlap is logged"
}

test_stale_lock_is_taken_over() {
  mkdir -p "$S/lock"
  echo 999999 >"$S/lock/pid" # no such process
  set_inspect running unhealthy 0 "0001-01-01T00:00:00Z"
  run_wd
  assert_eq "$(restarts_count)" 1 "stale lock does not block"
  assert_no_file "$S/lock"
}

test_missing_container_cards_once_per_24h() {
  echo 1 >"$F/inspect_rc"
  printf 'plex\nsonarr\n' >"$F/ps"
  run_wd
  assert_eq "$RC" 0 "exit code"
  assert_eq "$(alerts_count)" 1 "alerts"
  assert_contains "$(alert_title 1)" "not found" "title"
  run_wd $((7 * H))
  assert_eq "$(alerts_count)" 1 "within 24h: no second card"
  run_wd $((25 * H))
  assert_eq "$(alerts_count)" 2 "after 24h: second card"
}

test_cooldown_counts_skipped_cards() {
  set_inspect running unhealthy 0 "0001-01-01T00:00:00Z"
  run_wd 0
  run_wd "$H"
  run_wd $((2 * H))
  assert_eq "$(restarts_count)" 3 "all three freezes restarted"
  assert_eq "$(alerts_count)" 1 "only the first card filed"
  run_wd $((7 * H)) # t0 and t0+1h restarts are out of the 6h window; budget allows it
  assert_eq "$(restarts_count)" 4 "restart after cooldown"
  assert_eq "$(alerts_count)" 2 "second card after 6h"
  assert_contains "$(alert_desc 2)" "2 more since last card" "skipped count"
  run_wd $((8 * H))
  assert_eq "$(alerts_count)" 2 "cooldown restarts after a card"
}

test_alert_failure_keeps_pending_and_retries() {
  touch "$F/alert_fail"
  set_inspect running unhealthy 0 "0001-01-01T00:00:00Z"
  run_wd
  assert_eq "$RC" 1 "exit code when alert fails"
  assert_eq "$(restarts_count)" 1 "restart still happened"
  assert_contains "$(<"$ERR")" "miner-watchdog" "failure reported on stderr"
  assert_contains "$(<"$ERR")" "alert" "failure mentions the alert"
  local pend=("$S"/pending-*)
  [ "${#pend[@]}" -gt 0 ] || die "no pending alert kept"
  # alert backend back, container healthy again: the pending card is retried
  rm "$F/alert_fail"
  set_inspect running healthy 0 "0001-01-01T00:00:00Z"
  run_wd 300
  assert_eq "$RC" 0 "exit code after retry"
  assert_eq "$(alert_title 2)" "twitch-drops-miner froze and was restarted (watchdog)" "retried card"
  pend=("$S"/pending-*)
  [ "${#pend[@]}" -eq 0 ] || die "pending alert not cleared"
  assert_eq "$(restarts_count)" 1 "no extra restart"
  # and it is not sent a third time
  run_wd 600
  assert_eq "$(alerts_count)" 2 "no repeat"
}

test_docker_down_exits_nonzero_and_keeps_state() {
  mkdir -p "$S"
  printf '%s\n' $((BASE - 100)) >"$S/restarts.log"
  : >"$S/last-ok"
  echo 1 >"$F/inspect_rc"
  echo 1 >"$F/ps_rc"
  run_wd
  assert_eq "$RC" 1 "exit code"
  assert_contains "$(<"$ERR")" "miner-watchdog" "reported on stderr"
  assert_eq "$(alerts_count)" 1 "problem card"
  assert_contains "$(alert_title 1)" "problem" "title"
  assert_file "$S/restarts.log"
  [ -e "$S/last-ok" ] || die "state was deleted"
}

test_garbage_inspect_output_is_an_error() {
  echo "this is not what we asked for" >"$F/inspect"
  run_wd
  assert_eq "$RC" 1 "exit code"
  assert_no_file "$S/last-ok"
  assert_eq "$(restarts_count)" 0 "no restart on unparseable state"
}

test_restart_failure_is_an_error() {
  echo 1 >"$F/restart_rc"
  set_inspect running unhealthy 0 "0001-01-01T00:00:00Z"
  run_wd
  assert_eq "$RC" 1 "exit code"
  assert_eq "$(alerts_count)" 1 "problem card"
  assert_contains "$(alert_title 1)" "problem" "title"
  assert_contains "$(alert_desc 1)" "restart" "description"
  assert_no_file "$S/restarts.log" # a failed restart does not use up the budget
}

test_default_alert_command_uses_hermes_helper() {
  set_inspect exited none 2 "2026-10-28T01:02:03Z"
  run_wd 0 MW_ALERT_CMD=
  assert_eq "$RC" 0 "exit code"
  local args
  args=$(<"$F/exec_args")
  assert_contains "$args" "Hermes-WebUI" "container"
  assert_contains "$args" "/opt/hermes/.venv/bin/python" "interpreter"
  assert_contains "$args" "alert_automation_issue" "helper call"
  assert_contains "$args" "stopped with exit code 2" "title argument"
}

# ---------------------------------------------------------------- runner

pass=0
failed=0
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  setup
  s0=$SECONDS
  if ( "$t" ); then
    echo "PASS $t ($((SECONDS - s0))s)"
    pass=$((pass + 1))
  else
    echo "FAIL $t"
    failed=$((failed + 1))
  fi
  teardown
done
echo "---"
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
