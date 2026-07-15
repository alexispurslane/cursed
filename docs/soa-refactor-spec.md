# SoA Refactor Spec: Ring Buffers & Kqueue FDs

## Goal
Replace the 10 named `outbox_*`/`inbox_*` ring buffer fields and 6 named `*_kq_fd` fields
in `struct SharedState` with indexed arrays keyed by `LANE_IDX_*` constants.

## New Struct Layout (shared_state.h)

```c
struct SharedState {
    /* Ring buffers for lane communication — indexed by LANE_IDX_* */
    struct RingBuf outboxes[NUM_LANES];  /* main → lane */
    struct RingBuf inboxes[NUM_LANES];   /* lane → main */

    /* Kqueue fds — indexed by LANE_IDX_* for lanes; main_kq_fd is separate */
    int            lane_kq_fds[NUM_LANES];
    int            main_kq_fd;           /* central kqueue for main lane */

    _Atomic bool   running;

    /* Heartbeat array: one slot per lane */
    _Atomic uint8_t lane_heartbeats[NUM_LANES];

    /* Shared parse-tree slot table (highlight → main). */
    struct SharedTree shared_tree;
};
```

## Field Mapping

| Old name | New access |
|---|---|
| `outbox_io` | `outboxes[LANE_IDX_IO]` (0) |
| `outbox_hl` | `outboxes[LANE_IDX_HL]` (1) |
| `outbox_lsp` | `outboxes[LANE_IDX_LSP]` (2) |
| `outbox_proc` | `outboxes[LANE_IDX_PROC]` (3) |
| `outbox_task` | `outboxes[LANE_IDX_TASK]` (4) |
| `inbox_io` | `inboxes[LANE_IDX_IO]` |
| `inbox_hl` | `inboxes[LANE_IDX_HL]` |
| `inbox_lsp` | `inboxes[LANE_IDX_LSP]` |
| `inbox_proc` | `inboxes[LANE_IDX_PROC]` |
| `inbox_task` | `inboxes[LANE_IDX_TASK]` |
| `io_kq_fd` | `lane_kq_fds[LANE_IDX_IO]` |
| `hl_kq_fd` | `lane_kq_fds[LANE_IDX_HL]` |
| `lsp_kq_fd` | `lane_kq_fds[LANE_IDX_LSP]` |
| `proc_kq_fd` | `lane_kq_fds[LANE_IDX_PROC]` |
| `task_kq_fd` | `lane_kq_fds[LANE_IDX_TASK]` |
| `main_kq_fd` | `main_kq_fd` (unchanged) |

## Init Pattern (shared_state.h, in shared_state_alloc)

Replace the 20+ individual lines with loops:

```c
/* Create kqueues */
for (int i = 0; i < NUM_LANES; i++) {
    ss->lane_kq_fds[i] = kqueue();
}
ss->main_kq_fd = kqueue();

/* Wire outboxes: each wakes its lane */
for (int i = 0; i < NUM_LANES; i++) {
    ss->outboxes[i].consumer_kq_fd = ss->lane_kq_fds[i];
    ss->outboxes[i].wake_ident = 1;
}
/* Wire inboxes: each wakes main, distinct idents */
for (int i = 0; i < NUM_LANES; i++) {
    ss->inboxes[i].consumer_kq_fd = ss->main_kq_fd;
    ss->inboxes[i].wake_ident = i + 1;  // IO→1, HL→2, LSP→3, PROC→4, TASK→5
}

/* Check all kq fds */
if (ss->main_kq_fd < 0) { shared_state_free(ss); return NULL; }
for (int i = 0; i < NUM_LANES; i++) {
    if (ss->lane_kq_fds[i] < 0) { shared_state_free(ss); return NULL; }
}
```

## Cleanup Pattern (shared_state_free)

```c
for (int i = 0; i < NUM_LANES; i++) {
    if (ss->lane_kq_fds[i] >= 0) close(ss->lane_kq_fds[i]);
}
if (ss->main_kq_fd >= 0) close(ss->main_kq_fd);
```

## Stop Pattern (shared.lua)

```lua
function SharedState:stop()
    self._ptr.running = false
    for i = 0, shared_ffi.NUM_LANES - 1 do
        self:push(self._ptr.outboxes[i], { type = shared_ffi.MSG_SHUTDOWN })
    end
end
```

## FFI Declaration (shared_ffi.lua)

```c
struct SharedState {
    struct RingBuf outboxes[5];  /* NUM_LANES */
    struct RingBuf inboxes[5];
    int            lane_kq_fds[5];
    int            main_kq_fd;
    bool           running;
    uint8_t        lane_heartbeats[5];
    uint8_t        _pad[2];      /* alignment for shared_tree */
    struct SharedTree shared_tree;
};
```

## Consumer Access Patterns — BEFORE → AFTER

### Lua-side push/pop (everywhere):
```
ss._ptr.outbox_io  →  ss._ptr.outboxes[LANE_IDX_IO]
ss._ptr.inbox_io   →  ss._ptr.inboxes[LANE_IDX_IO]
ss._ptr.outbox_hl  →  ss._ptr.outboxes[LANE_IDX_HL]
...
```
Where `LANE_IDX_*` comes from `require("cursed.shared")` in the file.

### kq fd access in lanes:
```
ss._ptr.io_kq_fd   →  ss._ptr.lane_kq_fds[LANE_IDX_IO]
ss._ptr.hl_kq_fd   →  ss._ptr.lane_kq_fds[LANE_IDX_HL]
...
```

### Wake ident access in lanes:
```
ss._ptr.outbox_io.wake_ident   →  ss._ptr.outboxes[LANE_IDX_IO].wake_ident
ss._ptr.outbox_hl.wake_ident   →  ss._ptr.outboxes[LANE_IDX_HL].wake_ident
...
```

### main.lua inbox drain dispatch:
Replace the 5-fold if/elseif chain with a loop over the lane array,
using `ss._ptr.inboxes[i].wake_ident` to match the kq event ident.

### main.lua add_wake registrations:
Replace 5 explicit calls with a loop.

### main.c thread creation:
Change references from `ss->io_kq_fd` to `ss->lane_kq_fds[LANE_IDX_IO]`, etc.

## Files to Change (by grouping)

### Group 1: C-side (shared_state.h, main.c)
- shared_state.h: struct definition, init loop, cleanup loop
- main.c: ~3 references to `ss->io_kq_fd` etc.

### Group 2: FFI + wrapper (shared_ffi.lua, shared.lua)
- shared_ffi.lua: struct FFI definition
- shared.lua: stop() loop

### Group 3: Lane files (io_lane, highlight_lane, lsp_lane, proc_lane, task_lane)
Each lane needs:
- Import the LANE_IDX_* constant it uses
- Replace `ss._ptr.outbox_XX` → `ss._ptr.outboxes[LANE_IDX_XX]`
- Replace `ss._ptr.inbox_XX` → `ss._ptr.inboxes[LANE_IDX_XX]`
- Replace `ss._ptr.XX_kq_fd` → `ss._ptr.lane_kq_fds[LANE_IDX_XX]`

### Group 4: Main-side consumers (main.lua, editor.lua, proc_client.lua, task_client.lua)
- main.lua: wake registrations, drain dispatch, outbox pushes
- editor.lua: ~20 push calls to outbox_io
- proc_client.lua: 3 push calls to outbox_proc
- task_client.lua: 1 push call to outbox_task
