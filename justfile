# Cursed — justfile
#
# Fully self-contained build: vendored LuaJIT + tree-sitter + parsers.
# Only requires a C compiler (clang/gcc) and make. No system packages needed.

CC       := "clang"
STYLUA   := "stylua"
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

# Auto-discovered parsers: any vendor/tree-sitter-* directory
PARSERS := `find vendor -maxdepth 1 -type d -name 'tree-sitter-*' ! -name 'tree-sitter-lib' | sed 's|.*/tree-sitter-||' | sort | tr '\n' ' '`

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

fmt:
    {{STYLUA}} --search-parent-directories {{SRC_DIR}}

# ── Build ──────────────────────────────────────────────────────────

build mode="release": (build-luajit) (compile-bytecode) (compile-vendor mode) (compile-binary mode) (print-summary)

# ── print-summary: final rollup of all build artifacts ────────────

print-summary:
    #!/usr/bin/env bash
    set -euo pipefail
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo "  BUILD COMPLETE"
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo ""

    # ── Final binary ──────────────────────────────────────────────────────────────
    if [ -f {{BINARY}} ]; then
        size=$(stat -f%z "{{BINARY}}" 2>/dev/null || stat --format=%s "{{BINARY}}" 2>/dev/null)
        human=$(numfmt --to=si --suffix=B --format="%.1f" <<< "$size" 2>/dev/null || echo "$size B")
        echo "  ▶ Binary:       {{BINARY}}  ($human)"
    fi

    # ── LuaJIT ────────────────────────────────────────────────────────────────────
    echo "  ▶ LuaJIT:       {{LUAJIT_BIN}}"
    echo "  ▶ LuaJIT lib:   {{LUAJIT_LIB}}"

    # ── Count all artifacts ────────────────────────────────────────────────────────
    bc_count=$(find {{BUILD_DIR}} -name 'bytecode_*.h' | wc -l | tr -d ' ')
    obj_count=$(find {{BUILD_DIR}} -name '*.o' | wc -l | tr -d ' ')
    inc_size=$(wc -c < {{BUILD_DIR}}/includes.inc 2>/dev/null || echo 0)
    mod_size=$(wc -c < {{BUILD_DIR}}/modules.inc 2>/dev/null || echo 0)

    echo ""
    echo "  ▼ Artifacts in {{BUILD_DIR}}/"
    echo "    · Bytecode headers:  ${bc_count}"
    echo "    · Object files:      ${obj_count}"
    echo "    · includes.inc:      $(numfmt --to=iec ${inc_size} 2>/dev/null || echo "${inc_size} bytes")"
    echo "    · modules.inc:       $(numfmt --to=iec ${mod_size} 2>/dev/null || echo "${mod_size} bytes")"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════"

# Step 0: Build vendored LuaJIT (only if not already built)
build-luajit:
    #!/usr/bin/env bash
    set -euo pipefail
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo "  STAGE: build-luajit — Build vendored LuaJIT"
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo ""

    if [ -x {{LUAJIT_BIN}} ] && [ -f {{LUAJIT_LIB}} ]; then
        bin_size=$(stat -f%z "{{LUAJIT_BIN}}" 2>/dev/null || stat --format=%s "{{LUAJIT_BIN}}" 2>/dev/null)
        lib_size=$(stat -f%z "{{LUAJIT_LIB}}" 2>/dev/null || stat --format=%s "{{LUAJIT_LIB}}" 2>/dev/null)
        bin_human=$(numfmt --to=si --suffix=B --format="%.1f" <<< "$bin_size" 2>/dev/null || echo "$bin_size B")
        lib_human=$(numfmt --to=si --suffix=B --format="%.1f" <<< "$lib_size" 2>/dev/null || echo "$lib_size B")
        echo "  ▼ Status: cached (reusing existing build)"
        echo "  ▼ Binary: {{LUAJIT_BIN}}  (${bin_human})"
        echo "  ▼ Library: {{LUAJIT_LIB}}  (${lib_human})"
    else
        echo "  ▼ Status: building from source"
        echo "  ▼ Source: {{VENDOR_DIR}}/luajit"
        echo ""
        cd {{VENDOR_DIR}}/luajit
        MACOSX_DEPLOYMENT_TARGET={{MACOSX_DEPLOYMENT_TARGET}} make -j$(sysctl -n hw.ncpu 2>/dev/null || echo 4) clean 2>/dev/null || true
        MACOSX_DEPLOYMENT_TARGET={{MACOSX_DEPLOYMENT_TARGET}} make -j$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
        bin_size=$(stat -f%z "{{LUAJIT_BIN}}" 2>/dev/null || stat --format=%s "{{LUAJIT_BIN}}" 2>/dev/null)
        lib_size=$(stat -f%z "{{LUAJIT_LIB}}" 2>/dev/null || stat --format=%s "{{LUAJIT_LIB}}" 2>/dev/null)
        bin_human=$(numfmt --to=si --suffix=B --format="%.1f" <<< "$bin_size" 2>/dev/null || echo "$bin_size B")
        lib_human=$(numfmt --to=si --suffix=B --format="%.1f" <<< "$lib_size" 2>/dev/null || echo "$lib_size B")
        echo ""
        echo "  ▼ Binary: {{LUAJIT_BIN}}  (${bin_human})"
        echo "  ▼ Library: {{LUAJIT_LIB}}  (${lib_human})"
    fi

# Step 1: Lua → bytecode C headers + generated modules.inc (one per module)
# LUA_PATH must point to the jit/ modules so -b (bcsave.lua) works.
compile-bytecode:
    #!/usr/bin/env bash
    set -euo pipefail
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo "  STAGE: compile-bytecode — Lua source → bytecode C headers"
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo ""

    mkdir -p {{BUILD_DIR}}
    src="{{SRC_DIR}}"

    # Enumerate all source files
    all_files=()
    while IFS= read -r -d '' f; do
        all_files+=("$f")
    done < <(find "$src" -name '*.lua' -print0 | sort -z)

    total=${#all_files[@]}
    fresh=0
    cached=0
    echo "  ▼ Source: ${total} .lua files in ${src}/"
    echo ""

    # Compile each .lua → bytecode header (only if missing or stale)
    for f in "${all_files[@]}"; do
        rel="${f#$src/}"
        name="${rel%.lua}"
        modname="${name//\//.}"
        ident="${modname//\./_}"
        header="{{BUILD_DIR}}/bytecode_${ident}.h"

        if [ ! -f "$header" ] || [ "$f" -nt "$header" ]; then
            LUA_PATH="{{LUAJIT_SRC}}/?.lua" {{LUAJIT_BIN}} -b -g -n "$modname" "$f" "$header"
            size=$(stat -f%z "$header" 2>/dev/null || stat --format=%s "$header" 2>/dev/null)
            printf "  · built   %-50s  %s B\n" "${rel}" "${size}"
            fresh=$((fresh + 1))
        else
            cached=$((cached + 1))
        fi
    done

    # Generate includes.inc
    echo ""
    echo "  ▼ Generating {{BUILD_DIR}}/includes.inc"
    > {{BUILD_DIR}}/includes.inc
    for f in "${all_files[@]}"; do
        rel="${f#$src/}"
        name="${rel%.lua}"
        modname="${name//\//.}"
        ident="${modname//\./_}"
        echo "#include \"bytecode_${ident}.h\""
    done > {{BUILD_DIR}}/includes.inc
    inc_lines=$(wc -l < {{BUILD_DIR}}/includes.inc | tr -d ' ')
    inc_size=$(wc -c < {{BUILD_DIR}}/includes.inc | tr -d ' ')
    echo "    · ${inc_lines} #include directives"
    echo "    · ${inc_size} bytes"

    # Generate modules.inc
    echo "  ▼ Generating {{BUILD_DIR}}/modules.inc"
    > {{BUILD_DIR}}/modules.inc
    for f in "${all_files[@]}"; do
        rel="${f#$src/}"
        name="${rel%.lua}"
        modname="${name//\//.}"
        ident="${modname//\./_}"
        echo "    { \"${modname}\", (const char *)luaJIT_BC_${ident}, sizeof(luaJIT_BC_${ident}) },"
    done > {{BUILD_DIR}}/modules.inc
    mod_lines=$(wc -l < {{BUILD_DIR}}/modules.inc | tr -d ' ')
    mod_size=$(wc -c < {{BUILD_DIR}}/modules.inc | tr -d ' ')
    echo "    · ${mod_lines} module entries"
    echo "    · ${mod_size} bytes"

    echo ""
    echo "  ▼ Summary: ${fresh} built, ${cached} cached, ${total} total modules"
    if [ "$fresh" -gt 0 ]; then
        echo "    · Fresh builds listed above"
    fi

# Step 2: Compile vendored C libraries (only if object files are missing or stale)
compile-vendor mode="release":
    #!/usr/bin/env bash
    set -euo pipefail

    # ── Helper: compile a single-file C lib with staleness check ────────
    # Usage: build_lib LABEL OBJ_NAME SOURCE_FILE [EXTRA_CFLAGS...]
    build_lib() {
        local label="$1" output="$2" source="$3"; shift 3
        local obj="{{BUILD_DIR}}/$output"
        local needed=0
        if [ ! -f "$obj" ] || [ "$source" -nt "$obj" ]; then
            printf "  · %-15s (%s) — compiling\n" "$label" "$output"
            clang $CFLAGS -DMACOSX_DEPLOYMENT_TARGET={{MACOSX_DEPLOYMENT_TARGET}} \
                "$@" -c "$source" -o "$obj"
            needed=1
        fi
        local size
        size=$(stat -f%z "$obj" 2>/dev/null || stat --format=%s "$obj" 2>/dev/null)
        local human
        human=$(numfmt --to=si --suffix=B --format="%.1f" <<< "$size" 2>/dev/null || echo "$size B")
        printf "  · %-15s (%s) — %s  (%s)\n" "$label" "$output" \
            "$( [ $needed = 1 ] && echo 'fresh' || echo 'cached' )" "$human"
    }

    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo "  STAGE: compile-vendor — Vendored C libraries + parsers"
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo ""

    mkdir -p {{BUILD_DIR}}
    CFLAGS="{{if mode == "debug" { "-g -O0 -DDEBUG" } else { "-O2 -DNDEBUG" }}} -std=c11 {{TS_INC}}"
    echo "  ▼ Mode: {{mode}}"
    echo "  ▼ Compiler: {{CC}}"
    echo "  ▼ CFLAGS: ${CFLAGS}"
    echo ""

    # ── Single-file C libraries ────────────────────────────────────────────────────
    echo "  ▼ Libraries"
    build_lib "tree-sitter"   "ts_lib.o"       "{{VENDOR_DIR}}/tree-sitter-lib/lib/src/lib.c"
    build_lib "termbox2"      "termbox2.o"     "{{VENDOR_DIR}}/termbox2/termbox2_impl.c" \
        -DTB_OPT_ATTR_W=64 -DTB_OPT_EGC -I{{VENDOR_DIR}}/termbox2
    build_lib "yyjson"        "yyjson.o"       "{{VENDOR_DIR}}/yyjson/yyjson.c" \
        -I{{VENDOR_DIR}}/yyjson
    build_lib "yyjson shim"   "yyjson_shim.o"  "{{VENDOR_DIR}}/yyjson/yyjson_shim.c" \
        -I{{VENDOR_DIR}}/yyjson

    # Collect library labels for the summary
    lib_labels=("tree-sitter" "termbox2" "yyjson" "yyjson shim")

    # ── TRE (autotools-based, genuinely different build) ──────────────────────────
    echo ""
    echo "  ▼ Regex engine: TRE"
    tre_needed=0
    if [ ! -f {{VENDOR_DIR}}/tre/lib/.libs/libtre.a ]; then
        echo "    · libtre.a — compiling from source"
        (cd {{VENDOR_DIR}}/tre && autoreconf -i 2>/dev/null && \
            ./configure --disable-shared --enable-static --disable-wchar --disable-multibyte --disable-approx && \
            make -j$(sysctl -n hw.ncpu 2>/dev/null || echo 4))
        tre_needed=1
    fi
    tre_size=$(stat -f%z "{{VENDOR_DIR}}/tre/lib/.libs/libtre.a" 2>/dev/null || stat --format=%s "{{VENDOR_DIR}}/tre/lib/.libs/libtre.a" 2>/dev/null)
    if [ -n "$tre_size" ] && [ "$tre_size" -gt 0 ]; then
        tre_human=$(numfmt --to=si --suffix=B --format="%.1f" <<< "$tre_size" 2>/dev/null || echo "$tre_size B")
        echo "    · libtre.a     — $( [ "$tre_needed" = 1 ] && echo 'fresh' || echo 'cached' )  (${tre_human})"
        echo "    · at: {{VENDOR_DIR}}/tre/lib/.libs/libtre.a"
    fi

    # ── Parsers (auto-discovered from vendor/tree-sitter-*) ──────────────────────
    echo ""
    echo "  ▼ Parsers"

    total_parsers=0
    total_scanners=0
    fresh_parsers=0
    cached_parsers=0
    fresh_scanners=0
    cached_scanners=0
    has_scanners=()

    for lang in {{PARSERS}}; do
        dir="{{VENDOR_DIR}}/tree-sitter-$lang"
        obj="{{BUILD_DIR}}/parser_${lang}.o"
        src="$dir/src/parser.c"

        pstatus="cached"
        if [ ! -f "$obj" ] || [ "$src" -nt "$obj" ]; then
            clang $CFLAGS -DMACOSX_DEPLOYMENT_TARGET={{MACOSX_DEPLOYMENT_TARGET}} -c "$src" -o "$obj"
            pstatus="fresh"
            fresh_parsers=$((fresh_parsers + 1))
        else
            cached_parsers=$((cached_parsers + 1))
        fi
        total_parsers=$((total_parsers + 1))

        psize=$(stat -f%z "$obj" 2>/dev/null || stat --format=%s "$obj" 2>/dev/null)
        phuman=$(numfmt --to=si --suffix=B --format="%.1f" <<< "$psize" 2>/dev/null || echo "$psize B")

        # Check for scanner
        sstatus=""
        if [ -f "$dir/src/scanner.c" ]; then
            sobj="{{BUILD_DIR}}/scanner_${lang}.o"
            ssrc="$dir/src/scanner.c"
            sstatus="cached"
            if [ ! -f "$sobj" ] || [ "$ssrc" -nt "$sobj" ]; then
                clang $CFLAGS -DMACOSX_DEPLOYMENT_TARGET={{MACOSX_DEPLOYMENT_TARGET}} -c "$ssrc" -o "$sobj"
                sstatus="fresh"
                fresh_scanners=$((fresh_scanners + 1))
            else
                cached_scanners=$((cached_scanners + 1))
            fi
            total_scanners=$((total_scanners + 1))
            ssize=$(stat -f%z "$sobj" 2>/dev/null || stat --format=%s "$sobj" 2>/dev/null)
            shuman=$(numfmt --to=si --suffix=B --format="%.1f" <<< "$ssize" 2>/dev/null || echo "$ssize B")
            has_scanners+=("$lang")
        fi

        # Print one line per parser
        if [ -n "$sstatus" ]; then
            printf "  · %-15s parser %s  ($phuman, %s)  + scanner %s  ($shuman, %s)\n" \
                "$lang" "$obj" "$pstatus" "$sobj" "$sstatus"
        else
            printf "  · %-15s parser %s  ($phuman, %s)   no scanner\n" \
                "$lang" "$obj" "$pstatus"
        fi
    done

    echo ""
    echo "  ▼ Summary"
    echo "    · Libraries: ${lib_labels[*]} TRE"
    echo "    · Parsers:   ${total_parsers} (${fresh_parsers} fresh, ${cached_parsers} cached)"
    echo "    · Scanners:  ${total_scanners} (${fresh_scanners} fresh, ${cached_scanners} cached) in: ${has_scanners[*]}"

# Step 3: Link everything into the cursed binary
compile-binary mode="release":
    #!/usr/bin/env bash
    set -euo pipefail
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo "  STAGE: compile-binary — Link final binary"
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo ""

    mkdir -p {{BUILD_DIR}}

    cflags="{{if mode == "debug" { "-g -O0 -DDEBUG" } else { "-O2 -DNDEBUG" }}}"
    echo "  ▼ Mode:   {{mode}}"
    echo "  ▼ CFLAGS: ${cflags}"
    echo "  ▼ CC:     {{CC}}"
    echo ""

    # Discover all object files dynamically, grouped by type
    echo "  ▼ Objects"

    # Libraries: known base names
    lib_objs=()
    for base in ts_lib.o termbox2.o yyjson.o yyjson_shim.o; do
        f="{{BUILD_DIR}}/$base"
        if [ -f "$f" ]; then
            lib_objs+=("$f")
            echo "    · $base ($f)"
        fi
    done

    # Parsers + scanners: discovered from parser list
    parser_objs=()
    scanner_objs=()
    for lang in {{PARSERS}}; do
        pf="{{BUILD_DIR}}/parser_${lang}.o"
        if [ -f "$pf" ]; then
            parser_objs+=("$pf")
            echo "    · parser_${lang}.o ($pf)"
        fi
        sf="{{BUILD_DIR}}/scanner_${lang}.o"
        if [ -f "$sf" ]; then
            scanner_objs+=("$sf")
            echo "    · scanner_${lang}.o ($sf)"
        fi
    done

    # Combine all objects for linking
    all_objs=( "${lib_objs[@]}" "${parser_objs[@]}" "${scanner_objs[@]}" )
    obj_count=${#all_objs[@]}

    echo ""
    echo "  ▼ Linking ${obj_count} object files"
    echo "    · LuaJIT: {{LUAJIT_LIB}}"
    echo "    · TRE:    {{VENDOR_DIR}}/tre/lib/.libs/libtre.a (force-loaded)"
    echo "    · System: -lm -ldl -lpthread"
    echo ""

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
        "${all_objs[@]}" \
        {{LUAJIT_LIB}} \
        -Wl,-force_load,{{VENDOR_DIR}}/tre/lib/.libs/libtre.a \
        -lm -ldl -lpthread \
        -o {{BINARY}}

    echo "  ✓ Linked successfully"
    echo ""

    bin_size=$(stat -f%z "{{BINARY}}" 2>/dev/null || stat --format=%s "{{BINARY}}" 2>/dev/null)
    bin_human=$(numfmt --to=si --suffix=B --format="%.1f" <<< "$bin_size" 2>/dev/null || echo "$bin_size B")
    echo "  ▼ Output"
    echo "    · Binary: {{BINARY}}"
    echo "    · Size:   ${bin_human}"
    echo "    · Objects linked: ${obj_count}"

# ── Run ────────────────────────────────────────────────────────────

# NOTE: the old `*ARGS` + `{{ARGS}}` form flattens variadic args with
# whitespace and re-emits them UNQUOTED, so a quoted path like
#   just run '/path/with spaces/file'
# reached the binary as TWO argv entries (`/path/with` and `spaces/file`),
# and cursed opened the first one. A single positional `file` arg,
# manually single-quoted in the body, survives intact. Paths containing
# a literal single quote aren't supported here — call the binary
# directly:  ./build/cursed one two 'three with spaces'

run file="": (build "release")
    {{BINARY}} {{ if file == "" { "" } else { "'" + file + "'" } }}

run-debug file="": (build "debug")
    {{BINARY}} {{ if file == "" { "" } else { "'" + file + "'" } }}
