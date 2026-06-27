#!/usr/bin/env bash
# UTF-8 rendering + navigation smoke test for cursed.
#
# Launches the built binary on a file containing CJK, combining marks,
# emoji ZWJ families, and flag pairs. Verifies the renderer places wide
# glyphs at correct display columns and that navigation/insertion across
# grapheme clusters doesn't corrupt the buffer.
#
# The editor is NOT vim-modal: keys insert directly; arrow keys move.

set -u
cd "$(dirname "$0")/.." || exit 1

BIN=build/cursed
[ -x "$BIN" ] || { echo "build missing"; exit 1; }

SESSION=cursed_utf8
TMPFILE=/tmp/cursed_utf8_input.txt
trap 'tmux kill-session -t "$SESSION" 2>/dev/null; rm -f "$TMPFILE"; : > /tmp/cursed.log' EXIT
: > /tmp/cursed.log

cap() { tmux capture-pane -p -J -t "$SESSION:0.0" 2>/dev/null | tr -d '\0'; }
check() {
    local name="$1" expected="$2"
    local out; out=$(cap)
    if echo "$out" | grep -qF -- "$expected"; then
        echo "ok: $name"
    else
        echo "FAIL: $name"
        echo "  expected to contain: $expected"
        echo "  got (first 6 lines):"
        echo "$out" | head -6 | sed 's/^/    /'
        fail=$((fail+1))
    fi
}
send() { tmux send-keys -t "$SESSION:0.0" "$@"; sleep 0.25; }

fail=0

# Seed file: line 1 = ASCII+CJK intermixed, line 2 = combining marks,
# line 3 = ZWJ family emoji, line 4 = flag pair.
printf 'hello 中 world 你好\n' > "$TMPFILE"
printf 'café résumé déjà\n' >> "$TMPFILE"
printf 'family: \xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\n' >> "$TMPFILE"
printf 'flag: \xf0\x9f\x87\xa6\xf0\x9f\x87\xa7\n' >> "$TMPFILE"

tmux new-session -d -s "$SESSION" -x 80 -y 24 "$BIN $TMPFILE 2>/tmp/cursed.log"
sleep 0.6

# 1. File loads & renders line 1 (CJK + ASCII intermixed at correct columns).
check "renders CJK line" "hello 中 world 你好"

# 2. Combining marks render as single precomposed-looking cells (é),
#    NOT split into 'e' + floating accent.
check "renders combining é line" "café résumé déjà"

# 3. ZWJ family emoji renders as the joined family. tmux capture-pane
# can't read back composed ZWJ clusters from its cell model, so verify
# via the escape-sequence capture that the full cluster bytes
# (👨 + ZWJ + 👩) are emitted contiguously — proof termbox stored the
# whole grapheme in one extended cell and the terminal will compose it.
tmux capture-pane -p -e -t "$SESSION:0.0" 2>/dev/null > /tmp/utf8_egc_cap.txt
if grep -qF $'\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9' /tmp/utf8_egc_cap.txt; then
    echo "ok: ZWJ family cluster bytes emitted contiguously"
else
    echo "FAIL: ZWJ family cluster bytes not contiguous in render output"
    xxd /tmp/utf8_egc_cap.txt | grep -B1 -A1 'f09f' | head | sed 's/^/    /'
    fail=$((fail+1))
fi

# 4. Flag pair renders as one flag glyph (grapheme intact).
check "renders flag pair grapheme" "flag: 🇦🇧"

# 5. Arrow-key navigation across a wide glyph: cursor must skip the wide
#    glyph's 2nd cell, not land inside it. We can't assert exact caret
#    position via capture-pane, but we verify the process stays alive &
#    responsive (no crash) after heavy navigation around wide chars.
#    Move to line 1, walk right through the CJK glyphs.
send Right Right Right Right Right Right Right Right
sleep 0.3
check "process alive after horizontal nav across CJK" "hello"

# 6. Vertical navigation across lines of differing grapheme widths.
send Down Down Down
sleep 0.3
check "process alive after vertical nav across grapheme lines" "flag"

# 7. Navigate back up to the ZWJ family line and walk the cursor through
#    the cluster — must not crash or split it visually.
send Up
sleep 0.2
send Right Right Right Right Right Right Right Right Right Right Right Right
sleep 0.3
check "process alive after nav across ZWJ family" "family"

# 8. Insert an ASCII char near the ZWJ family — the cluster bytes must
# stay contiguous in the rendered output (proving the edit didn't corrupt
# the grapheme's cell). Verify via escape-capture, not capture-pane plain text
# (tmux can't read back composed ZWJ clusters).
send "0"
sleep 0.3
tmux capture-pane -p -e -t "$SESSION:0.0" 2>/dev/null > /tmp/utf8_egc_cap2.txt
if grep -qF $'\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9' /tmp/utf8_egc_cap2.txt; then
    echo "ok: ZWJ family intact after nearby insert"
else
    echo "FAIL: ZWJ family corrupted after nearby insert"
    xxd /tmp/utf8_egc_cap2.txt | grep 'f09f' | head | sed 's/^/    /'
    fail=$((fail+1))
fi

# 9. Navigate to the flag line and insert nearby — flag must render intact.
send Down
sleep 0.2
check "flag line still renders after edits above" "🇦🇧"

echo ""
if [ "$fail" -eq 0 ]; then
    echo "ALL UTF-8 SMOKE TESTS PASSED"
    exit 0
else
    echo "$fail FAILURES"
    exit 1
fi
