# Cursed — justfile
#
# Fully self-contained build: vendored LuaJIT + tree-sitter + parsers.
# Only requires a C compiler (clang/gcc) and make. No system packages needed.

CC       := "clang"
STYLUA   := "stylua"
LUALS    := "lua-language-server"

SRC_DIR   := "src"
BUILD_DIR := "build"
VENDOR_DIR := "vendor"
BINARY    := BUILD_DIR / "cursed"

# ── Vendored LuaJIT paths ──────────────────────────────────────────
LUAJIT_SRC  := VENDOR_DIR + "/luajit/src"
LUAJIT_INC  := LUAJIT_SRC  # lua.h etc. live directly in luajit/src/
LUAJIT_LIB  := LUAJIT_SRC + "/libluajit.a"
LUAJIT_BIN  := LUAJIT_SRC + "/luajit"

# ── Vendored tree-sitter paths ─────────────────────────────────────
TS_INC := "-I" + VENDOR_DIR + "/tree-sitter-lib/lib/include -I" + VENDOR_DIR + "/tree-sitter-lib/lib/src"

# Bundled parser list
PARSERS := "bash c go json lua markdown_block markdown_inline python rust toml yaml"

# macOS deployment target (needed by LuaJIT build and our own compile)
# Must be consistent across all object files.
MACOSX_DEPLOYMENT_TARGET := `sw_vers -productVersion 2>/dev/null | cut -d. -f1-2 || echo "14.0"`

# Default: build the standalone binary
default: (build "release")

# ── Clean ──────────────────────────────────────────────────────────

clean:
    rm -rf {{BUILD_DIR}}
    cd {{VENDOR_DIR}}/tre && make clean 2>/dev/null || true

clean-vendor:
    cd {{VENDOR_DIR}}/luajit && make clean 2>/dev/null || true
    cd {{VENDOR_DIR}}/tree-sitter-lib && git clean -fdx 2>/dev/null || true

# ── Lint & Format ──────────────────────────────────────────────────

lint:
    #!/usr/bin/env bash
    set -euo pipefail
    {{LUALS}} check --configpath .luarc.json --check {{SRC_DIR}}/

fmt:
    {{STYLUA}} {{SRC_DIR}}

fmt-check:
    {{STYLUA}} --check {{SRC_DIR}}

# ── Build ──────────────────────────────────────────────────────────

build mode="release": (build-luajit) (compile-bytecode) (compile-vendor mode) (compile-binary mode)

# Step 0: Build vendored LuaJIT (only if not already built)
build-luajit:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -x {{LUAJIT_BIN}} ] && [ -f {{LUAJIT_LIB}} ]; then
        echo "vendored LuaJIT already built"
        exit 0
    fi
    cd {{VENDOR_DIR}}/luajit
    MACOSX_DEPLOYMENT_TARGET={{MACOSX_DEPLOYMENT_TARGET}} make -j$(sysctl -n hw.ncpu 2>/dev/null || echo 4) clean 2>/dev/null || true
    MACOSX_DEPLOYMENT_TARGET={{MACOSX_DEPLOYMENT_TARGET}} make -j$(sysctl -n hw.ncpu 2>/dev/null || echo 4)

# Step 1: Lua → bytecode C headers + generated modules.inc (one per module)
# LUA_PATH must point to the jit/ modules so -b (bcsave.lua) works.
compile-bytecode:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p {{BUILD_DIR}}
    src="{{SRC_DIR}}"

    # Compile each .lua → bytecode header (only if missing or stale)
    find "$src" -name '*.lua' -print0 | sort -z | while IFS= read -r -d '' f; do
        rel="${f#$src/}"
        name="${rel%.lua}"
        modname="${name//\//.}"
        ident="${modname//\./_}"
        header="{{BUILD_DIR}}/bytecode_${ident}.h"
        if [ ! -f "$header" ] || [ "$f" -nt "$header" ]; then
            LUA_PATH="{{LUAJIT_SRC}}/?.lua" {{LUAJIT_BIN}} -b -n "$modname" "$f" "$header"
        fi
    done

    # Generate includes.inc and modules.inc from whatever .lua files exist
    find "$src" -name '*.lua' -print0 | sort -z | while IFS= read -r -d '' f; do
        rel="${f#$src/}"
        name="${rel%.lua}"
        modname="${name//\//.}"
        ident="${modname//\./_}"
        echo "#include \"bytecode_${ident}.h\""
    done > {{BUILD_DIR}}/includes.inc

    find "$src" -name '*.lua' -print0 | sort -z | while IFS= read -r -d '' f; do
        rel="${f#$src/}"
        name="${rel%.lua}"
        modname="${name//\//.}"
        ident="${modname//\./_}"
        echo "    { \"${modname}\", (const char *)luaJIT_BC_${ident}, sizeof(luaJIT_BC_${ident}) },"
    done > {{BUILD_DIR}}/modules.inc

# Step 2: Compile vendored C libraries (only if object files are missing or stale)
compile-vendor mode="release":
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p {{BUILD_DIR}}
    CFLAGS="{{if mode == "debug" { "-g -O0 -DDEBUG" } else { "-O2 -DNDEBUG" }}} -std=c11 {{TS_INC}}"

    # tree-sitter lib
    if [ ! -f {{BUILD_DIR}}/ts_lib.o ] || [ {{VENDOR_DIR}}/tree-sitter-lib/lib/src/lib.c -nt {{BUILD_DIR}}/ts_lib.o ]; then
        echo "vendored tree-sitter not built — compiling"
        clang $CFLAGS -DMACOSX_DEPLOYMENT_TARGET={{MACOSX_DEPLOYMENT_TARGET}} -c {{VENDOR_DIR}}/tree-sitter-lib/lib/src/lib.c -o {{BUILD_DIR}}/ts_lib.o
    fi

    # termbox2 (header-only -- compile the impl shim, 64-bit attrs for truecolor)
    if [ ! -f {{BUILD_DIR}}/termbox2.o ] || [ {{VENDOR_DIR}}/termbox2/termbox2_impl.c -nt {{BUILD_DIR}}/termbox2.o ]; then
        echo "vendored termbox2 not built — compiling"
        clang $CFLAGS -DMACOSX_DEPLOYMENT_TARGET={{MACOSX_DEPLOYMENT_TARGET}} \
            -DTB_OPT_ATTR_W=64 \
            -I{{VENDOR_DIR}}/termbox2 \
            -c {{VENDOR_DIR}}/termbox2/termbox2_impl.c -o {{BUILD_DIR}}/termbox2.o
    fi

    # TRE (POSIX regex, non-backtracking) — built via autotools
    if [ ! -f {{VENDOR_DIR}}/tre/lib/.libs/libtre.a ]; then
        echo "vendored TRE not built — compiling"
        (cd {{VENDOR_DIR}}/tre && autoreconf -i 2>/dev/null && \
            ./configure --disable-shared --enable-static --disable-wchar --disable-multibyte --disable-approx && \
            make -j$(sysctl -n hw.ncpu 2>/dev/null || echo 4))
    fi

    # Each parser (and its scanner, if present)
    for lang in {{PARSERS}}; do
        dir="{{VENDOR_DIR}}/tree-sitter-$lang"
        obj="{{BUILD_DIR}}/parser_${lang}.o"
        src="$dir/src/parser.c"
        if [ ! -f "$obj" ] || [ "$src" -nt "$obj" ]; then
            echo "vendored tree-sitter-$lang not built — compiling"
            clang $CFLAGS -DMACOSX_DEPLOYMENT_TARGET={{MACOSX_DEPLOYMENT_TARGET}} -c "$src" -o "$obj"
        fi
        if [ -f "$dir/src/scanner.c" ]; then
            sobj="{{BUILD_DIR}}/scanner_${lang}.o"
            ssrc="$dir/src/scanner.c"
            if [ ! -f "$sobj" ] || [ "$ssrc" -nt "$sobj" ]; then
                clang $CFLAGS -DMACOSX_DEPLOYMENT_TARGET={{MACOSX_DEPLOYMENT_TARGET}} -c "$ssrc" -o "$sobj"
            fi
        fi
    done

# Step 3: Link everything into the cursed binary
compile-binary mode="release":
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p {{BUILD_DIR}}

    # Gather all object files
    objs="{{BUILD_DIR}}/ts_lib.o {{BUILD_DIR}}/termbox2.o"
    for lang in {{PARSERS}}; do
        objs="$objs {{BUILD_DIR}}/parser_${lang}.o"
        if [ -f "{{BUILD_DIR}}/scanner_${lang}.o" ]; then
            objs="$objs {{BUILD_DIR}}/scanner_${lang}.o"
        fi
    done

    clang \
        {{if mode == "debug" { "-g -O0 -DDEBUG" } else { "-O2 -DNDEBUG" }}} \
        -std=c11 \
        -Wall -Wextra -Werror \
        -mmacosx-version-min={{MACOSX_DEPLOYMENT_TARGET}} \
        -I{{LUAJIT_INC}} \
        -I{{BUILD_DIR}} \
        -I{{SRC_DIR}} \
        -I{{VENDOR_DIR}}/tree-sitter-lib/lib/include \
        -I{{VENDOR_DIR}}/termbox2 \
        -I{{VENDOR_DIR}}/tre/include \
        {{SRC_DIR}}/main.c \
        $objs \
        {{LUAJIT_LIB}} \
        -Wl,-force_load,{{VENDOR_DIR}}/tre/lib/.libs/libtre.a \
        -lm -ldl -lpthread \
        -o {{BINARY}}

# ── Run ────────────────────────────────────────────────────────────

run *ARGS: (build "release")
    {{BINARY}} {{ARGS}}

run-debug *ARGS: (build "debug")
    {{BINARY}} {{ARGS}}

# ── All checks ─────────────────────────────────────────────────────

check: fmt-check lint
