/* Standalone key-capture tool for debugging termbox2 decoding on your terminal.
 *
 * Build:   see scripts/capture_keys.sh
 * Run:     ./build/capture_keys
 * Then press the key combo you want to inspect (e.g. Shift+Enter, then a
 * letter). Press Ctrl-C to exit. Prints one line per event.
 */
#define TB_IMPL
#include "termbox2.h"
#include <stdio.h>
#include <string.h>

int main(void) {
    int rv = tb_init();
    if (rv != TB_OK) {
        fprintf(stderr, "tb_init failed: %d\n", rv);
        return 1;
    }
    /* Mirrors cursed's default input mode. */
    int mode = tb_set_input_mode(TB_INPUT_ESC);
    fprintf(stderr, "capture_keys: input_mode=%d (ESC). Press keys; Ctrl-C to quit.\n", mode);
    fprintf(stderr, "type  key=0x%-6x  ch=0x%-6x  mod=%d\n", 0, 0, 0);

    for (;;) {
        struct tb_event ev;
        memset(&ev, 0, sizeof(ev));
        rv = tb_poll_event(&ev);
        if (rv != TB_OK) {
            fprintf(stderr, "tb_poll_event rc=%d\n", rv);
            break;
        }
        if (ev.type == TB_EVENT_RESIZE) {
            fprintf(stderr, "RESIZE %dx%d\n", ev.w, ev.h);
            continue;
        }
        /* KEY event */
        char chbuf[8] = {0};
        if (ev.ch >= 32 && ev.ch < 127) {
            chbuf[0] = (char)ev.ch;
        }
        fprintf(stderr, "KEY  key=0x%-6x(%d)  ch=0x%-6x(%d)  mod=%d  char='%s'\n",
                ev.key, ev.key, ev.ch, ev.ch, ev.mod, chbuf);
        if (ev.key == 0x03) break; /* Ctrl-C */
    }
    tb_shutdown();
    return 0;
}
