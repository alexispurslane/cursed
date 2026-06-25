#!/usr/bin/env bash
set -u
BIN="./build/cursed"
F=/tmp/cursed_sweep.lua
SESSION=csweep

# send a space-separated key string to the pane (small sleep per send)
sendk() { tmux send-keys -t "$SESSION:0.0" "$@"; sleep 0.22; }

check_err() {
  [ -s /tmp/cursed_err.log ] && return 0
  tmux capture-pane -p -t "$SESSION" 2>/dev/null | grep -q "command error\|arithmetic\|attempt to" && return 0
  return 1
}

run() {
  local name="$1" keys="$2" file="$3"
  tmux kill-session -t "$SESSION" 2>/dev/null
  rm -f /tmp/cursed_err.log
  tmux new-session -d -s "$SESSION" -x 110 -y 30 -c "$PWD" "$BIN $file"
  sleep 0.8
  # keys is a single string of tmux tokens; rely on word splitting
  # shellcheck disable=SC2086
  sendk $keys
  sleep 0.3
  if check_err; then
    echo "!!! REPRO [$name]"
    tmux capture-pane -p -t "$SESSION" | tail -4
    cat /tmp/cursed_err.log 2>/dev/null | head -30
  else
    echo "ok   [$name]"
  fi
}

printf 'local x = 1\nlocal y = "hello world"\nprint(y, x)\n' > "$F"
printf '' > /tmp/cursed_empty.lua

run "select+Del+undo"        "C-Right C-Right C-Right C-Space C-Right C-Right C-Right C-Right C-Right Delete C-x u" "$F"
run "select+BS+undo"         "C-Right C-Right C-Right C-Space C-Right C-Right C-Right C-Right C-Right BSpace C-x u" "$F"
run "select+type+undo2"      "C-Right C-Right C-Right C-Space C-Right C-Right C-Right C-Right C-Right X C-x u C-x u" "$F"
run "select-eol+Del+undo"    "C-Right C-Right C-Right C-Space C-e Delete C-x u" "$F"
run "select-wholeline+Del+undo" "C-a C-Space C-e Right Delete C-x u" "$F"
run "select+Del+undo2"       "C-Right C-Right C-Right C-Space C-Right C-Right C-Right C-Right C-Right Delete C-x u C-x u" "$F"
run "empty+type+sel+Del+undo2" "hello C-a C-Space C-Right C-Right C-Right Delete C-x u C-x u" "/tmp/cursed_empty.lua"
# try: select, backspace (no selection deletes char), then undo — selection already consumed
run "sel+del+undo+redo+undo" "C-Right C-Right C-Right C-Space C-Right C-Right C-Right Delete C-x u C-x r C-x u" "$F"
# select across newline then delete + undo
run "sel-crossnl+Del+undo"   "C-Right C-Right C-Right C-Right C-Right C-Right C-Right C-Right C-Space C-Right C-Right C-Right C-Right Delete C-x u" "$F"

tmux kill-session -t "$SESSION" 2>/dev/null
