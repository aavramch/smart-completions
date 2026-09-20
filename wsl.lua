--------------------------------------------------------------------------------
-- wsl.lua - Dynamic Clink completion for wsl.exe.
--
-- WSL's switches change as Windows and WSL are updated, so this matcher reads
-- `wsl.exe --help` lazily instead of keeping a version-specific switch list.
-- It also completes installed distributions using `wsl.exe --list --quiet`.
--------------------------------------------------------------------------------

if not clink or not clink.argmatcher then return end

local unpack_args = table.unpack or unpack
local LIVE_TTL = 4

-- wsl.exe has emitted UTF-16LE when stdout is redirected on some Windows
-- versions. Its option names and distro registration names are ASCII, so
-- removing the interleaved NUL bytes makes both UTF-16LE and normal output
-- usable without depending on a particular Clink/Lua Unicode library.
local function normalise_line(line)
    return (line:gsub('\255\254', ''):gsub('\0', ''):gsub('\r$', ''))
end

local function trim(s)
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function capture_lines(command)
    local pipe = io.popen(command .. ' 2>NUL', 'rb')
    if not pipe then return nil end

    -- Do not use pipe:lines() here.  Clink's Lua file iterator treats the NUL
    -- bytes in redirected UTF-16LE output as string terminators, reducing the
    -- first line of `wsl.exe --help` to just "C".  Reading the binary stream
    -- in one operation preserves the bytes so they can be normalized first.
    local output = pipe:read('*a')
    pipe:close()
    if not output then return nil end

    output = normalise_line(output)
    local lines = {}
    for line in (output .. '\n'):gmatch('(.-)\n') do
        lines[#lines + 1] = line:gsub('\r$', '')
    end
    return lines
end

local function ttl_cached(producer, ttl)
    local cached, cached_at
    return function(...)
        local now = os.time()
        if not cached or now - cached_at >= (ttl or LIVE_TTL) then
            local ok, value = pcall(producer, ...)
            if ok and value then cached, cached_at = value, now end
        end
        return cached or {}
    end
end

local function distro_names(executable)
    local result, seen = {}, {}
    for _, line in ipairs(capture_lines(executable .. ' --list --quiet') or {}) do
        local name = trim(line):gsub('^%*', '')
        name = trim(name)
        if name ~= '' and not seen[name] then
            seen[name] = true
            result[#result + 1] = name
        end
    end
    return result
end

-- Parse declarations such as "--distribution, -d <Distro>". Descriptive
-- prose is ignored; localized help retains the stable switch spellings.
local function parse_help(lines)
    local result = { flags = {}, value_kind = {} }
    local seen = {}

    for _, raw in ipairs(lines or {}) do
        local line = trim(raw)
        if line:match('^%-%-?[%w]') then
            local found = {}
            local long = line:match('^(%-%-[%w][%w%-]*)')
            local long_after_comma = line:match(',%s*(%-%-[%w][%w%-]*)')
            local short_at_start = line:match('^(%-[%w%?])[%s,]')
                or line:match('^(%-[%w%?])$')
            local short_after_comma = line:match(',%s*(%-[%w%?])[%s,]')
            if long then found[#found + 1] = long end
            if long_after_comma then found[#found + 1] = long_after_comma end
            if short_at_start then found[#found + 1] = short_at_start end
            if short_after_comma then found[#found + 1] = short_after_comma end

            local placeholder = line:match('[<%[]([^>%]]+)[>%]]')
            if placeholder then
                placeholder = placeholder:gsub('%.%.%.$', ''):lower()
            end

            local kind
            if placeholder and (placeholder:find('distro', 1, true)
                    or placeholder:find('distribution', 1, true)) then
                kind = 'distro'
            elseif placeholder and (placeholder:find('path', 1, true)
                    or placeholder:find('file', 1, true)
                    or placeholder:find('disk', 1, true)
                    or placeholder:find('vhd', 1, true)) then
                kind = 'file'
            elseif placeholder == 'version' then
                kind = 'version'
            elseif placeholder == 'shelltype' or placeholder == 'type' then
                kind = 'shelltype'
            elseif placeholder and placeholder ~= 'options'
                    and placeholder ~= 'option' and placeholder ~= 'commandline' then
                -- Even without suggestions this tells Clink that the switch
                -- consumes a value (for example --user or --name).
                kind = 'value'
            end

            for _, flag in ipairs(found) do
                if not seen[flag] then
                    seen[flag] = true
                    result.flags[#result.flags + 1] = flag
                end
                if kind then result.value_kind[flag] = kind end
            end
        end
    end
    return result
end

local function value_parser(matches, hint)
    return clink.argmatcher():addarg({ matches, hint = hint }):nofiles()
end

local function register(executable, ...)
    local help
    local distributions = ttl_cached(function() return distro_names(executable) end)
    local parsers = {
        distro = value_parser(distributions, 'Installed WSL distribution'),
        version = value_parser({ '1', '2' }, 'WSL version'),
        shelltype = value_parser({ 'standard', 'login', 'none' }, 'Shell type'),
        value = value_parser({}, 'Value'),
        file = clink.argmatcher():addarg(clink.filematches),
    }

    clink.argmatcher(executable, ...):setdelayinit(function(m)
        help = help or parse_help(capture_lines(executable .. ' --help') or {})
        local flags = {}
        for _, flag in ipairs(help.flags) do
            local parser = parsers[help.value_kind[flag]]
            flags[#flags + 1] = parser and (flag .. parser) or flag
        end
        if #flags > 0 then m:addflags(unpack_args(flags)) end

        -- Remaining words form a Linux command. File matching is a useful
        -- fallback and still allows arbitrary command text.
        m:addarg(clink.filematches):loop()
        m:setflagsanywhere(true)
    end)
end

register('wsl', 'wsl.exe')
