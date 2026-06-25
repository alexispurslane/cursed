#ifndef SHARED_STATE_H
#define SHARED_STATE_H

#include <stdint.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/event.h>
#include <unistd.h>

/* ── SharedState ────────────────────────────────────────────────────
 *
 * SharedState is the IPC mechanism between lanes. It holds ring buffers
 * for communication and a staging area for the IO lane to relay mmap'd
 * file data to the main lane.
 *
 * The piece table lives in Buffer objects (see buffer.h), not here.
 */

#define RING_CAP 1024

#define MSG_FILE_LOAD   0   /* main → IO: please load this file (ptr = filepath string) */
#define MSG_FILE_LOADED 1   /* IO → main: file loaded — read io_orig_* fields */
#define MSG_FILE_ERROR  2   /* IO → main: file load failed (arg = error code) */
#define MSG_FILE_SAVE   3   /* main → IO: please save file (ptr = filepath string, arg = text ptr, arg2 = text len) */
#define MSG_FILE_SAVED   4   /* IO → main: file saved */

#define MSG_HL_INITIALIZE_LANGUAGE 8  /* main → hl: ptr = struct HlInitLangReq* */
#define MSG_HL_QUERY              9  /* main → hl: ptr = struct HlQueryReq* */
#define MSG_HL_SPANS              10 /* hl → main: ptr = struct HlSpansHdr* */

struct Msg {
    uint8_t  type;
    uint8_t  _pad[3];
    uint32_t arg;
    void    *ptr;
};

struct RingBuf {
    _Atomic uint32_t head;
    _Atomic uint32_t tail;
    struct Msg       entries[RING_CAP];
    int              consumer_kq_fd;   /* kqueue fd of the consumer lane */
    uintptr_t       wake_ident;        /* EVFILT_USER ident for wake */
};

struct SharedState {
    /* Ring buffers for lane communication */
    struct RingBuf outbox_io;
    struct RingBuf inbox_io;
    struct RingBuf outbox_hl;   /* main → highlight */
    struct RingBuf inbox_hl;    /* highlight → main */
    int            main_kq_fd;  /* central kqueue for main lane (tty, resize, inbox wakes) */
    int            io_kq_fd;    /* kqueue for IO lane (outbox wake) */
    int            hl_kq_fd;    /* kqueue for highlight lane (outbox_hl wake) */
    _Atomic bool   running;
};

/* ── Global pointer (set by main.c before lanes start) ──────────── */

extern struct SharedState *g_shared_state;

/* ── Lifecycle ──────────────────────────────────────────────────── */

static inline void shared_state_free(struct SharedState *ss);

static inline struct SharedState *shared_state_alloc(void)
{
    struct SharedState *ss = calloc(1, sizeof(*ss));
    if (!ss) return NULL;

    atomic_store_explicit(&ss->inbox_io.head, 0, memory_order_relaxed);
    atomic_store_explicit(&ss->inbox_io.tail, 0, memory_order_relaxed);
    atomic_store_explicit(&ss->outbox_io.head, 0, memory_order_relaxed);
    atomic_store_explicit(&ss->outbox_io.tail, 0, memory_order_relaxed);
    atomic_store_explicit(&ss->inbox_hl.head, 0, memory_order_relaxed);
    atomic_store_explicit(&ss->inbox_hl.tail, 0, memory_order_relaxed);
    atomic_store_explicit(&ss->outbox_hl.head, 0, memory_order_relaxed);
    atomic_store_explicit(&ss->outbox_hl.tail, 0, memory_order_relaxed);
    atomic_store_explicit(&ss->running, true, memory_order_relaxed);

    ss->main_kq_fd = kqueue();
    ss->io_kq_fd = kqueue();
    ss->hl_kq_fd = kqueue();

    /* Each ring wakes its consumer lane via a distinct EVFILT_USER ident.
     * Idents are lane-local: outbox_* wakes the consumer lane (io/hl),
     * inbox_* wakes main. Using distinct idents per ring on main's kq lets
     * the main loop tell which lane replied. */
    ss->outbox_io.consumer_kq_fd = ss->io_kq_fd;
    ss->outbox_io.wake_ident = 1;
    ss->inbox_io.consumer_kq_fd = ss->main_kq_fd;
    ss->inbox_io.wake_ident = 1;
    ss->outbox_hl.consumer_kq_fd = ss->hl_kq_fd;
    ss->outbox_hl.wake_ident = 1;
    ss->inbox_hl.consumer_kq_fd = ss->main_kq_fd;
    ss->inbox_hl.wake_ident = 2;

    if (ss->main_kq_fd < 0 || ss->io_kq_fd < 0 || ss->hl_kq_fd < 0) {
        shared_state_free(ss);
        return NULL;
    }

    return ss;
}

static inline void shared_state_free(struct SharedState *ss)
{
    if (!ss) return;
    if (ss->main_kq_fd >= 0) close(ss->main_kq_fd);
    if (ss->io_kq_fd >= 0) close(ss->io_kq_fd);
    if (ss->hl_kq_fd >= 0) close(ss->hl_kq_fd);
    free(ss);
}

/* ── Ring buffer ────────────────────────────────────────────────── */

bool ring_push(struct RingBuf *rb, const struct Msg *msg)
{
    uint32_t head = atomic_load_explicit(&rb->head, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&rb->tail, memory_order_acquire);

    if (head - tail >= RING_CAP)
        return false;

    rb->entries[head & (RING_CAP - 1)] = *msg;
    atomic_store_explicit(&rb->head, head + 1, memory_order_release);
    /* Wake the consumer lane via EVFILT_USER on its kqueue. */
    if (rb->consumer_kq_fd >= 0) {
        struct kevent trigger;
        EV_SET(&trigger, rb->wake_ident, EVFILT_USER, 0, NOTE_TRIGGER, 0, NULL);
        kevent(rb->consumer_kq_fd, &trigger, 1, NULL, 0, NULL);
    }
    return true;
}

bool ring_pop(struct RingBuf *rb, struct Msg *msg)
{
    uint32_t tail = atomic_load_explicit(&rb->tail, memory_order_relaxed);
    uint32_t head = atomic_load_explicit(&rb->head, memory_order_acquire);

    if (tail >= head)
        return false;

    *msg = rb->entries[tail & (RING_CAP - 1)];
    atomic_store_explicit(&rb->tail, tail + 1, memory_order_release);
    return true;
}

#endif /* SHARED_STATE_H */
