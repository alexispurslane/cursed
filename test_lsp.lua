#!/usr/bin/env lua
--- Standalone test: JSON encode/decode + LSP subprocess + JSON-RPC.
---
--- Usage: cd src && lua luajit ../test_lsp.lua

local ffi = require("ffi")
local bit = require("bit")
local pffi = require("cursed.posix_ffi")
local lsp = require("cursed.lsp_client")

local passed = 0
local failed = 0

local function check(name, ok, detail)
    if ok then
        passed = passed + 1
        print("  PASS: " .. name)
    else
        failed = failed + 1
        print("  FAIL: " .. name .. detail and (": " .. detail) or "")
    end
end

local function roundtrip(name, v)
    local encoded = lsp.json_encode(v)
    local ok, decoded = pcall(lsp.json_decode, encoded)
    local equal = false
    if not ok then
        check(name, false, decoded)
        return
    end
    if v == nil then
        equal = decoded == nil
    elseif type(v) ~= "table" then
        equal = decoded == v
    else
        if type(decoded) ~= "table" then
            equal = false
        else
            equal = true
            for k, val in pairs(v) do
                if decoded[k] ~= val then
                    equal = false
                    break
                end
            end
        end
    end
    check(name, equal, not equal and " encoded: " .. encoded)
end

--------------------------------------------------------------------------------
print("\n=== JSON encode/decode ===\n")

roundtrip("nil", nil)
roundtrip("true", true)
roundtrip("false", false)
roundtrip("int", 42)
roundtrip("float", 3.14)
roundtrip("string", "hello")
roundtrip("str newline", "line1\nline2")
roundtrip("obj {a=1,b=2}", { a = 1, b = 2 })
roundtrip("arr", { "x", "y", "z" })

local decode_tests = {
    { input = "null",          verify = function(v) return v == nil end },
    { input = "true",          verify = function(v) return v == true end },
    { input = "false",         verify = function(v) return v == false end },
    { input = "42",            verify = function(v) return v == 42 end },
    { input = '{"key":"val"}', verify = function(v) return v.key == "val" end },
    { input = '["a","b"]',     verify = function(v) return v[1] == "a" and v[2] == "b" end },
    { input = '{"a":1,"b":{"n":true}}', verify = function(v) return v.b.n == true end },
    { input = '{"jsonrpc":"2.0","id":1}',
      verify = function(v) return v.jsonrpc == "2.0" and v.id == 1 end },
}

for _, t in ipairs(decode_tests) do
    local ok, decoded = pcall(lsp.json_decode, t.input)
    local nm = t.input:sub(1, math.min(36, #t.input))
    check("decode(" .. nm .. ")",
          ok and (not ok or t.verify(decoded)),
          not ok and decoded or "verify failed")
end

--------------------------------------------------------------------------------
print("\n=== LSP Subprocess ===\n")

local exe = lsp.find_executable({ "lua-language-server" })
check("find executable", exe ~= nil, exe and (" path: " .. exe) or "not on PATH")

if exe == nil then
    print(("\n" .. passed .. " passed, " .. failed .. " failed"))
    os.exit(failed > 0 and 1 or 0)
end

--- === Spawn subprocess with stdio pipes === ---

local stdin_pipe = ffi.new("int[2]")
assert(pffi.C.pipe(stdin_pipe) == 0, "pipe(stdin) failed")
local stdout_pipe = ffi.new("int[2]")
assert(pffi.C.pipe(stdout_pipe) == 0, "pipe(stdout) failed")

local lsp_pid = ffi.C.fork()
assert(lsp_pid >= 0)

local function die(msg)
    print("  FATAL: " .. msg)
    ffi.C.kill(lsp_pid, 9)
    ffi.C.waitpid(lsp_pid, nil, 0)
    os.exit(1)
end

if lsp_pid == 0 then
    -- Child: redirect [0,1] to pipes
    pffi.C.close(tonumber(stdin_pipe[1]))  -- write end not needed
    pffi.C.close(tonumber(stdout_pipe[0])) -- read end not needed

    pffi.C.dup2(tonumber(stdin_pipe[0]), 0)
    pffi.C.dup2(tonumber(stdout_pipe[1]), 1)

    pffi.C.close(tonumber(stdin_pipe[0]))
    pffi.C.close(tonumber(stdout_pipe[1]))

    ffi.C.execlp(exe, exe, nil)
    pffi.C._exit(127)
end

-- Parent: close unused pipe ends
pffi.C.close(tonumber(stdin_pipe[0]))
pffi.C.close(tonumber(stdout_pipe[1]))

local child_out = tonumber(stdout_pipe[0])
local child_in  = tonumber(stdin_pipe[1])

-- Non-blocking stdout
local flgs_o = ffi.C.fcntl(child_out, 3)
ffi.C.fcntl(child_out, 4, bit.bor(flgs_o, 4))
-- Non-blocking stdin
local flgs_i = ffi.C.fcntl(child_in, 3)
ffi.C.fcntl(child_in, 4, bit.bor(flgs_i, 4))

local server_response = nil
local incoming_count = 0

local client = lsp.create_raw(
    child_out,
    child_in,
    lsp_pid,
    function(msg)
        incoming_count = incoming_count + 1
        io.write("  [msg " .. incoming_count .. "] ")
        if msg.method ~= nil then
            io.write("method=" .. tostring(msg.method))
            if msg.params and msg.params.version then
                io.write(" ver=" .. msg.params.version)
            end
        elseif msg.id ~= nil then
            io.write("id=" .. tostring(msg.id))
            if msg.error ~= nil then
                io.write(" error=" .. tostring(msg.error.message or "?"))
            elseif msg.result ~= nil then
                local si = msg.result.serverInfo
                io.write(" result.serverInfo=" .. tostring(si and si.name or "nil"))
            end
        else
            io.write("msg=" .. tostring(msg))
        end
        io.write("\n")
        if msg.method == nil and msg.id ~= nil and msg.result ~= nil then
            server_response = msg.result
        end
    end,
    nil
)

check("spawn lsp", client ~= nil and client.running)

if client and client.running then
    -- Wait for server to initialize (lua-language-server is slow)
    ffi.C.usleep(3000000) -- 3 seconds

    -- Drain any initial messages
    local alive = client:drain()
    if not alive then die("child exited before init") end

    -- Send initialize
    local req_id = client:request("initialize", {
        processId = lsp_pid,
        rootUri = "file://" .. os.getenv("HOME"),
        capabilities = {},
    })
    print("  [sent initialize request id=" .. req_id .. "]")

    -- Poll + drain loop
    local plfds = ffi.new("struct pollfd[1]")
    plfds[0].fd = child_out
    plfds[0].events = pffi.POLLIN

    local iter = 0
    while iter < 20 do
        iter = iter + 1
        local pr = ffi.C.poll(plfds, 1, 500)

        if pr > 0 then
            io.write("  [fd ready, draining...]\n")
            local drain_alive = client:drain()
            if not drain_alive then die("child exited during polling") end
            if server_response ~= nil then
                io.write("  [RESPONSE RECEIVED]\n")
                break
            end
        elseif pr == 0 then
            -- Timeout
            if iter > 15 then
                io.write("  [timed out after " .. iter .. " polls, " .. incoming_count .. " msgs]\n")
                break
            end
        else
            break
        end
    end

    check("received initialize response",
          server_response ~= nil,
          server_response and (" serverInfo=" .. (server_response.serverInfo and server_response.serverInfo.name or "?"))
                            or "none")

    if not server_response then
        os.exit(1)
    end

    -- Graceful shutdown
    client:notify("shutdown", {})
    ffi.C.usleep(500000)
    client:notify("exit", {})
    ffi.C.waitpid(lsp_pid, nil, 0)
end

print(("\n" .. passed .. " passed, " .. failed .. " failed"))
os.exit(failed > 0 and 1 or 0)
