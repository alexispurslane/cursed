package = "cursed"
version = "dev-1"

source = {
    url = ".",
}

description = {
    summary = "A cursed LuaJIT project",
    detailed = "Standalone LuaJIT binary with ahead-of-time bytecode compilation. Written in Teal, compiled to Lua via tl gen.",
    homepage = "https://github.com/example/cursed",
    license = "MIT",
}

dependencies = {
    "lua == 5.1",
    "tl >= 0.24.8",
    "luajit-tl-type",
}

build = {
    type = "builtin",
    modules = {
        cursed = "src/main.lua",
    },
}
