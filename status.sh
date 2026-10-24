#!/bin/bash

# Reports the trader's state from the process table and the log alone, so it
# never needs the API secrets or a call to Binance. It parses only the log
# format that scavenger_trader.md fixes, so it survives a regeneration.

cd "$(dirname "$0")" || exit 1

LOG_FILE=scavenger_trader.log

if [ -t 1 ]; then
  OK=$'\e[32m✔\e[0m' FAIL=$'\e[31m✘\e[0m' INFO=$'\e[33m•\e[0m'
else
  OK='[ok]' FAIL='[!!]' INFO='[--]'
fi

pid=$(pgrep -f 'ruby.*scavenger_trader\.rb' | head -n 1)

if [ -n "$pid" ]; then
  echo "$OK Running (PID $pid, up $(ps -o etime= -p "$pid" | xargs))"
else
  echo "$FAIL Not running"
fi

if [ ! -f "$LOG_FILE" ]; then
  echo "$FAIL No $LOG_FILE found"
  exit 1
fi

awk -v ok="$OK" -v fail="$FAIL" -v info="$INFO" -v running="${pid:+1}" '
  / \[INFO\] Scavenger Trader started/ {
    started = $1 " " $2; run++; fatal = ""; funds = ""; ended = ""; buys = 0; sells = 0
  }
  / \[INFO\] Scavenger Trader ended\.$/ { ended = $1 " " $2 }
  / \[FATAL\] / && fatal == "" { fatal = $0 }
  / \[INFO\] Only .* available\. Skipping cycles until the account is funded\.$/ { funds = $0 }
  / \[INFO\] Order [0-9]+ is [A-Z_]+: type=/ {
    id = $5; status = $7; sub(/:$/, "", status)
    detail = $8 " " $9 " " $11 " " $12
    last_status[id] = status; last_line[id] = $1 " " $2 " " detail; order_run[id] = run
    if (!(id in seen)) { seen[id] = 1; ids[++count] = id }
    if (status == "FILLED") {
      last_fill = $1 " " $2 " #" id " " detail
      if (order_run[id] == run) { if ($9 == "side=BUY") buys++; else sells++ }
    }
    if (status == "NEW" || status == "PARTIALLY_FILLED") funds = ""
  }
  # Fatal backtraces continue on lines without the timestamp prefix.
  /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \[/ { last = $1 " " $2 }

  END {
    print (started ? ok " Last started " started : fail " Never started")
    print (fatal ? fail " Fatal error: " substr(fatal, index(fatal, "] ") + 2) : ok " No fatal errors since start")
    # A missing ending entry means the process died without running its
    # handlers, e.g. a SIGKILL or the machine shutting down.
    if (!running && started) print (ended ? info " Stopped cleanly at " ended : fail " Died without an ending log entry")
    if (funds) print info " Waiting for funds: " substr(funds, index(funds, "] ") + 2)

    open = 0
    for (i = 1; i <= count; i++) {
      id = ids[i]
      if (last_status[id] != "NEW" && last_status[id] != "PARTIALLY_FILLED") continue
      open++
      if (order_run[id] == run && running)
        print ok " Open order #" id " " last_status[id] " since " last_line[id]
      else
        print fail " Untracked order #" id " " last_status[id] " since " last_line[id] " (left by an earlier run, check Binance)"
    }
    if (!open) print info " No open orders"

    print info " Last fill: " (last_fill ? last_fill : "none")
    print info " Fills since start: " buys " buys, " sells " sells"
    print info " Last log entry: " last
  }
' "$LOG_FILE"

echo
tail -n 5 "$LOG_FILE"
