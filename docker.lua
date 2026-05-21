--------------------------------------------------------------------------------
-- docker.lua  -  Dynamic Clink argmatcher / completion script for `docker`.
--
-- Target: Clink v1.3.10+ (uses :setdelayinit, :addflags, :addarg, ...)
--         https://github.com/chrisant996/clink
--
-- How it works
-- ------------
-- Nothing about docker's CLI is hard-coded. The script discovers commands
-- and flags at completion-time by parsing docker's own --help output.
--
--   1. First tab on `docker` -> shell out to `docker --help`, parse the
--      "Commands:" sections (subcommand list) and "Global Options:" section
--      (top-level flags).
--   2. First tab on `docker <sub>` -> shell out to `docker <sub> --help`,
--      parse its "Options:" section. If <sub> is a management command
--      (e.g. container, image, network), its "Commands:" section is parsed
--      too and the recursion continues.
--   3. The Usage line is inspected for ALL-CAPS placeholders -- CONTAINER,
--      IMAGE, NETWORK, VOLUME, CONTEXT, SERVICE, NODE, PLUGIN -- and the
--      matching arg slot is wired to a live producer that runs
--      `docker ps` / `docker images` / etc.
--   4. Everything is wrapped in :setdelayinit() so the cost is paid lazily,
--      only when the user actually tab-completes that part of the line.
--      Clink startup stays fast even though we shell out to docker.
--
-- Because the structure is discovered, the script keeps working when new
-- subcommands appear, when flags are added/renamed, when docker plugins
-- like compose or buildx are installed, etc.
--
-- Install
-- -------
-- Drop this file in any Clink completions directory, e.g.
--     %LOCALAPPDATA%\clink\completions\docker.lua
-- (or a directory listed in %CLINK_COMPLETIONS_DIR%). It is loaded on demand
-- the first time you type `docker`.
--------------------------------------------------------------------------------

if not clink or not clink.argmatcher then return end

-- The command we invoke for both completion-discovery and for live data.
local DOCKER   = 'docker'
-- TTL for the live caches (containers, images, ...). Help text is parsed
-- once per session per subcommand path.
local LIVE_TTL = 4

--------------------------------------------------------------------------------
-- 1. Shell helpers
--------------------------------------------------------------------------------

-- Run a command (via cmd.exe), return stdout as a list of lines, or nil.
local function capture_lines(cmdline)
    local pipe = io.popen(cmdline .. ' 2>NUL')
    if not pipe then return nil end
    local lines = {}
    for line in pipe:lines() do
        lines[#lines + 1] = line
    end
    pipe:close()
    return lines
end

local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end

-- Wrap a producer with a TTL cache. Keeps tab completion snappy when the
-- user hits TAB repeatedly while exploring.
local function ttl_cached(producer, ttl)
    ttl = ttl or LIVE_TTL
    local at, val = 0, nil
    return function(...)
        local now = os.time()
        if not val or (now - at) >= ttl then
            local ok, v = pcall(producer, ...)
            if ok and v then val, at = v, now end
        end
        return val or {}
    end
end

--------------------------------------------------------------------------------
-- 2. Live match producers (containers, images, networks, ...)
--
-- These shell out to docker with a --format template so we get one name per
-- line, then filter out blanks and `<none>` dangling entries.
--------------------------------------------------------------------------------

local function names_from(args)
    local out, lines = {}, capture_lines(DOCKER .. ' ' .. args) or {}
    for _, l in ipairs(lines) do
        l = trim(l)
        if l ~= '' and not l:find('<none>') then
            out[#out + 1] = l
        end
    end
    return out
end

local running_containers = ttl_cached(function() return names_from('ps --format "{{.Names}}"') end)
local all_containers     = ttl_cached(function() return names_from('ps -a --format "{{.Names}}"') end)
local local_images       = ttl_cached(function() return names_from('images --format "{{.Repository}}:{{.Tag}}"') end)
local networks_list      = ttl_cached(function() return names_from('network ls --format "{{.Name}}"') end)
local volumes_list       = ttl_cached(function() return names_from('volume ls --format "{{.Name}}"') end)
local contexts_list      = ttl_cached(function() return names_from('context ls --format "{{.Name}}"') end)
local services_list      = ttl_cached(function() return names_from('service ls --format "{{.Name}}"') end)
local nodes_list         = ttl_cached(function() return names_from('node ls --format "{{.Hostname}}"') end)
local plugins_list       = ttl_cached(function() return names_from('plugin ls --format "{{.Name}}"') end)

--------------------------------------------------------------------------------
-- 2b. SSH host completer for `-H` / `--host`.
--
-- Parses ~/.ssh/config for `Host` entries and returns them as `ssh://name`,
-- which is the form docker's `-H` flag accepts. Wildcards (`*`, `?`, `!`) are
-- excluded because they aren't real hosts. If the file is missing or empty,
-- an empty list is returned -- but the flag is *still* wired to a parser, so
-- Clink doesn't fall through to the subcommand list.
--------------------------------------------------------------------------------

local function ssh_config_path()
    local home = os.getenv('USERPROFILE') or os.getenv('HOME')
    if not home or home == '' then return nil end
    return home .. '\\.ssh\\config'
end

-- Pure-function parser; takes a list of lines so it can be unit-tested
-- without touching the filesystem.
local function parse_ssh_hosts(lines)
    local seen, hosts = {}, {}
    for _, line in ipairs(lines) do
        line = line:gsub('#.*$', '')   -- strip inline / full-line comments
        -- `Host name1 name2 ...`  (keyword is case-insensitive in OpenSSH)
        local rest = line:match('^%s*[Hh][Oo][Ss][Tt]%s+(.+)$')
        if rest then
            for name in rest:gmatch('%S+') do
                -- Skip pattern entries (`*`, `?`, `!` negation).
                if not name:find('[%*%?%!]') and not seen[name] then
                    seen[name] = true
                    hosts[#hosts + 1] = 'ssh://' .. name
                end
            end
        end
    end
    return hosts
end

local function read_ssh_config()
    local path = ssh_config_path()
    if not path then return {} end
    local f = io.open(path, 'r')
    if not f then return {} end
    local lines = {}
    for line in f:lines() do lines[#lines + 1] = line end
    f:close()
    return parse_ssh_hosts(lines)
end

-- SSH config rarely changes; a longer TTL is fine.
local ssh_hosts = ttl_cached(read_ssh_config, 30)

-- Map a placeholder name (parsed from a Usage line) to a live producer.
-- The full subcommand `path` is available so CONTAINER can prefer running
-- containers for commands where stopped ones make no sense (`exec`, ...).
local RUNNING_ONLY = {
    exec = true, attach = true, logs = true, top = true, pause = true,
    unpause = true, stats = true, kill = true, port = true, wait = true,
}

local function completer_for(placeholder, path)
    if placeholder == 'CONTAINER' then
        local last = path:match('(%S+)$') or ''
        return RUNNING_ONLY[last] and running_containers or all_containers
    end
    return ({
        IMAGE   = local_images,
        IMAGES  = local_images,
        NETWORK = networks_list,
        VOLUME  = volumes_list,
        CONTEXT = contexts_list,
        SERVICE = services_list,
        NODE    = nodes_list,
        PLUGIN  = plugins_list,
    })[placeholder]
end

--------------------------------------------------------------------------------
-- 3. Help-text parser
--
-- Parses docker's --help output into three pieces:
--   * commands     : list of subcommand names (from any "*Commands:" section)
--   * flags        : list of flag strings, both short and long forms
--   * positionals  : ALL-CAPS placeholders pulled from the Usage line
--   * variadic_at  : index in `positionals` of a `[FOO...]` variadic arg
--
-- The format docker uses is consistent enough across versions that simple
-- pattern matching works. We deliberately tolerate slight variations.
--------------------------------------------------------------------------------

local function parse_help(lines)
    local r = {
        flags         = {},   -- list of flag strings (e.g. "-d", "--debug")
        commands      = {},   -- list of subcommand names
        positionals   = {},   -- list of ALL-CAPS placeholders from Usage line
        variadic_at   = nil,
        flag_desc     = {},   -- flag-string -> description
        cmd_desc      = {},   -- command-name -> description
    }
    if not lines or #lines == 0 then return r end

    -- 3a. Usage line: "Usage:  docker run [OPTIONS] IMAGE [COMMAND] [ARG...]"
    for _, line in ipairs(lines) do
        local usage = line:match('^Usage:%s+(.+)$')
        if usage then
            for tok in usage:gmatch('%S+') do
                local stripped = tok:gsub('^%[', ''):gsub('%]$', '')
                local variadic = stripped:find('%.%.%.$') ~= nil
                stripped = stripped:gsub('%.%.%.$', '')
                if  stripped:match('^[A-Z][A-Z_]+$')
                and stripped ~= 'OPTIONS'
                and stripped ~= 'COMMAND'
                and stripped ~= 'ARG' then
                    r.positionals[#r.positionals + 1] = stripped
                    if variadic then r.variadic_at = #r.positionals end
                end
            end
            break
        end
    end

    -- 3b. Walk the rest looking for "Commands:" and "Options:" sections.
    local section = nil
    for _, line in ipairs(lines) do
        if line:match('Commands:%s*$') then
            section = 'commands'
        elseif line:match('^Options:%s*$') or line:match('^Global Options:%s*$') then
            section = 'options'
        elseif line == '' or line:match('^%s*$') then
            -- blank line: keep current section
        elseif line:match('^%S') then
            -- non-indented, non-empty line ends any active section
            section = nil
        elseif section == 'commands' then
            -- "  cmdname     description"  or  "  cmdname*    ..."
            local name, desc = line:match('^%s+([%w%-_]+)%*?%s+(.+)$')
            if name then
                r.commands[#r.commands + 1] = name
                if desc then
                    desc = desc:gsub('%s+$', '')
                    if desc ~= '' then r.cmd_desc[name] = desc end
                end
            end
        elseif section == 'options' then
            -- "  -a, --attach list      Attach to STDIN, STDOUT or STDERR"
            -- "      --add-host list    Add a custom host-to-IP mapping"
            -- NB: in Lua patterns `--` is NOT two literal dashes -- the second
            -- `-` is a lazy "0+" quantifier on the first.  Escape both as %-%-.
            local short, long, rest = line:match('^%s+(%-%a),%s+(%-%-[%w%-_]+)%s*(.*)$')
            if not (short and long) then
                long, rest = line:match('^%s+(%-%-[%w%-_]+)%s*(.*)$')
                short = nil
            end
            if long then
                if short then r.flags[#r.flags + 1] = short end
                r.flags[#r.flags + 1] = long
                -- `rest` is whatever follows the long flag. It typically has
                -- the shape "<arginfo>  <description>" (separated by 2+ spaces)
                -- or just "<description>" if the flag is a boolean switch.
                if rest and rest ~= '' then
                    -- Try the "arginfo  description" form first.
                    local desc = rest:match('^%S+%s%s+(.+)$')
                    -- Otherwise treat rest as a plain description, but only if
                    -- it contains a space (else it's probably just arginfo).
                    if not desc and rest:find(' ') then desc = rest end
                    if desc then
                        desc = desc:gsub('%s+$', '')
                        if desc ~= '' then
                            if short then r.flag_desc[short] = desc end
                            r.flag_desc[long] = desc
                        end
                    end
                end
            end
        end
    end
    return r
end

-- Memoize parsed help per subcommand path so repeat tabs don't re-shell.
local help_cache = {}
local function help_for(path)
    if help_cache[path] then return help_cache[path] end
    local parsed = parse_help(capture_lines(path .. ' --help') or {})
    help_cache[path] = parsed
    return parsed
end

--------------------------------------------------------------------------------
-- 4. Argmatcher construction (recursive, delay-initialized)
--
-- For each (sub)command we build a matcher whose contents are filled in the
-- first time matches are requested for it. That callback shells out to
-- `docker <path> --help`, parses it, and wires up flags + arg slots +
-- nested sub-parsers as appropriate.
--------------------------------------------------------------------------------

-- Parser used as the *value* of `-H` / `--host`. Attaching this parser
-- (rather than leaving the flag as a bare string) tells Clink the flag
-- consumes the next word; without it, Clink would treat the next word as
-- a positional and show the subcommand list.
local host_value_parser = clink.argmatcher()
    :addarg({
        ssh_hosts,
        hint = 'Docker daemon socket (e.g. ssh://host, tcp://host:port)',
    })
    :nofiles()

-- Map of flag-string -> value-parser. To add completion for another flag's
-- value (e.g. `--context` -> contexts_list), just add an entry here.
local FLAG_VALUE_COMPLETERS = {
    ['-H']     = host_value_parser,
    ['--host'] = host_value_parser,
}

-- Rewrite a flag list, attaching a value-parser to any flag we know how to
-- complete. Flags not in the registry pass through unchanged.
local function apply_flag_completers(flags)
    local out = {}
    for _, f in ipairs(flags) do
        local vp = FLAG_VALUE_COMPLETERS[f]
        out[#out + 1] = vp and (f .. vp) or f
    end
    return out
end

local build_parser  -- forward declaration for recursion

build_parser = function(path)
    local matcher = clink.argmatcher()
    matcher:setdelayinit(function(m)
        local h = help_for(path)

        if #h.flags > 0 then
            m:addflags(table.unpack(apply_flag_completers(h.flags)))
            m:hideflags('-h', '--help')   -- accept them, but hide from default tab
            if next(h.flag_desc) then
                m:adddescriptions(h.flag_desc)
            end
        end

        if #h.commands > 0 then
            -- Management command: link each sub-subcommand to its own parser.
            local arg_table = {}
            for _, name in ipairs(h.commands) do
                arg_table[#arg_table + 1] = name .. build_parser(path .. ' ' .. name)
            end
            m:addarg(arg_table)
            if next(h.cmd_desc) then
                m:adddescriptions(h.cmd_desc)
            end

        elseif #h.positionals > 0 then
            -- Leaf command. Wire up an arg slot per positional placeholder.
            for i, ph in ipairs(h.positionals) do
                local c = completer_for(ph, path)
                m:addarg(c or clink.filematches)
                if i == h.variadic_at then
                    m:loop(i)   -- e.g. `docker rm CONTAINER [CONTAINER...]`
                    return
                end
            end
            -- After known positionals, accept arbitrary trailing args
            -- (covers e.g. `docker run IMAGE [COMMAND] [ARG...]`).
            m:addarg(clink.filematches):loop(#h.positionals + 1)

        else
            -- Flags only, no positional info: be permissive.
            m:addarg(clink.filematches):loop()
        end
    end)
    return matcher
end

--------------------------------------------------------------------------------
-- 5. Top-level registration
--
-- Register `docker` (and `docker-compose` for users with the standalone
-- Compose v1 binary). If a binary isn't installed, the delayed init produces
-- no matches and silently does nothing -- no errors.
--------------------------------------------------------------------------------

local function register(name)
    clink.argmatcher(name):setdelayinit(function(m)
        local h = help_for(name)

        if #h.flags > 0 then
            m:addflags(table.unpack(apply_flag_completers(h.flags)))
            m:hideflags('-h', '--help')
            if next(h.flag_desc) then
                m:adddescriptions(h.flag_desc)
            end
        end

        if #h.commands > 0 then
            local arg_table = {}
            for _, sub in ipairs(h.commands) do
                arg_table[#arg_table + 1] = sub .. build_parser(name .. ' ' .. sub)
            end
            m:addarg(arg_table)
            if next(h.cmd_desc) then
                m:adddescriptions(h.cmd_desc)
            end
        end

        -- Allow global flags like -H, --host, --context to appear anywhere on
        -- the command line, not just before the subcommand.
        m:setflagsanywhere(true)
    end)
end

register(DOCKER)
register('docker-compose')
