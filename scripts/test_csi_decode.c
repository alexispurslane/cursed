/* Unit test for extract_esc_csi_numeric against real terminal byte
 * sequences. Doesn't touch the tty — feeds bytes into termbox2's input
 * buffer and drains events directly. */
#define TB_IMPL
#include "termbox2.h"
#include <stdio.h>
#include <string.h>

extern struct tb_global global;

static int failures = 0;

static void reset_in(void) { global.in.len = 0; }

static void push(const char *s) {
    size_t n = strlen(s);
    if (global.in.len + n > global.in.cap) {
        global.in.cap = (global.in.len + n) * 2 + 16;
        global.in.buf = global.in.buf
            ? realloc(global.in.buf, global.in.cap)
            : malloc(global.in.cap);
    }
    memcpy(global.in.buf + global.in.len, s, n);
    global.in.len += n;
}

static void check(const char *label, const char *seq,
                  int want_key, int want_ch, int want_mod, int want_events) {
    printf("--- %s  [", label);
    for (const char *p = seq; *p; p++) printf(" %02x", (unsigned char)*p);
    printf(" ]\n");
    reset_in();
    push(seq);
    int got = 0;
    int guard = 0;
    while (global.in.len > 0 && guard++ < 50) {
        struct tb_event ev;
        memset(&ev, 0, sizeof(ev));
        int rv = extract_event(&ev);
        if (rv == TB_ERR_NEED_MORE) {
            printf("  NEED_MORE (incomplete)\n");
            break;
        }
        if (rv == TB_ERR) {
            printf("  TB_ERR (leftover %zu bytes)\n", global.in.len);
            break;
        }
        got++;
        printf("  event key=0x%x ch=0x%x mod=%d\n", ev.key, ev.ch, ev.mod);
        if (got == 1) {
            if ((int)ev.key != want_key || (int)ev.ch != want_ch ||
                (int)ev.mod != want_mod) {
                printf("  FAIL: want key=0x%x ch=0x%x mod=%d\n",
                       want_key, want_ch, want_mod);
                failures++;
            } else {
                printf("  ok\n");
            }
        }
    }
    if (got != want_events) {
        printf("  FAIL: want %d events, got %d\n", want_events, got);
        failures++;
    }
    if (global.in.len > 0) {
        printf("  FAIL: %zu leftover bytes\n", global.in.len);
        failures++;
    }
}

int main(void) {
    load_builtin_caps();
    global.input_mode = TB_INPUT_ESC;

    /* Ghostty Shift+Enter -> ESC[27;2;13~ */
    check("Shift+Enter (xterm formOtherKeys)",
          "\x1b[27;2;13~", TB_KEY_ENTER, 0, TB_MOD_SHIFT, 1);
    /* Ctrl+Enter, xterm form -> ESC[27;5;13~ */
    check("Ctrl+Enter (xterm)",
          "\x1b[27;5;13~", TB_KEY_ENTER, 0, TB_MOD_CTRL, 1);
    /* Shift+Ctrl+Enter -> mod 1|4 = 6 */
    check("Shift+Ctrl+Enter (xterm)",
          "\x1b[27;6;13~", TB_KEY_ENTER, 0, TB_MOD_SHIFT | TB_MOD_CTRL, 1);
    /* kitty CSI-u Shift+Enter -> ESC[13;2u */
    check("Shift+Enter (kitty CSI-u)",
          "\x1b[13;2u", TB_KEY_ENTER, 0, TB_MOD_SHIFT, 1);
    /* kitty Ctrl+Enter -> ESC[13;5u */
    check("Ctrl+Enter (kitty)",
          "\x1b[13;5u", TB_KEY_ENTER, 0, TB_MOD_CTRL, 1);
    /* Shift+Tab via CSI-u -> ESC[9;2u */
    check("Shift+Tab (kitty)",
          "\x1b[9;2u", TB_KEY_TAB, 0, TB_MOD_SHIFT, 1);
    /* Plain Enter still decodes (no shift) */
    check("plain Enter", "\r", TB_KEY_CTRL_M, 0, TB_MOD_CTRL, 1);
    /* Plain Esc still decodes */
    check("plain Esc", "\x1b", TB_KEY_ESC, 0, 0, 1);
    /* Incomplete CSI-u should wait for more, not emit garbage. We don't
     * assert on key/ch/mod (want_events=0); we only require that no
     * spurious KEY event was produced and the bytes weren't consumed. */
    {
        printf("--- incomplete kitty  [ 1b 5b 31 33 ]\n");
        reset_in();
        push("\x1b[13");
        int got = 0;
        struct tb_event ev;
        memset(&ev, 0, sizeof(ev));
        int rv = extract_event(&ev);
        if (rv == TB_ERR_NEED_MORE) {
            printf("  NEED_MORE (ok)\n");
        } else if (rv == TB_ERR) {
            printf("  FAIL: got TB_ERR instead of NEED_MORE\n");
            failures++;
        } else {
            got++;
            printf("  FAIL: emitted spurious event key=0x%x\n", ev.key);
            failures++;
        }
        if (got != 0) { printf("  FAIL: want 0 events\n"); failures++; }
    }

    printf("\n%s (%d failures)\n", failures ? "FAIL" : "PASS", failures);
    return failures ? 1 : 0;
}
