-- Arisen's Ledger: shared helpers. No game writes anywhere in this mod.
local U = {}

function U.try(f, ...)
    local ok, r = pcall(f, ...)
    if ok then return r end
    return nil
end
local try = U.try

function U.tname(o) return try(function() return o:get_type_definition():get_full_name() end) end

function U.str(v)
    if type(v) == "string" then return v end
    if type(v) == "userdata" then return try(function() return v:call("ToString") end) end
    return nil
end

local msg_get = try(function() return sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)") end)
function U.msg(guid)
    if not (msg_get and guid) then return nil end
    local s = U.str(try(function() return msg_get:call(nil, guid) end))
    if s and #s > 0 and not s:find("^<COLOR FF0000>#Rejected#") then return s end
    return nil
end

-- strip the game's inline markup (<VAL>, <ORCARA>, colour tags) and line breaks
function U.clean(s)
    if not s then return nil end
    s = s:gsub("\r\n", " "):gsub("\n", " "):gsub("<[^>]->", ""):gsub("%s+", " ")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function U.enum(name)
    local by_val, by_name = {}, {}
    local td = sdk.find_type_definition(name)
    if not td then return by_val, by_name end
    for _, f in ipairs(try(function() return td:get_fields() end) or {}) do
        if try(function() return f:is_static() end) then
            local n, v = try(function() return f:get_name() end), try(function() return f:get_data(nil) end)
            if n and type(v) == "number" then by_val[v] = n by_name[n] = v end
        end
    end
    return by_val, by_name
end

function U.list(list, fn)
    local out = {}
    local n = list and try(function() return list:call("get_Count") end) or 0
    for i = 0, (n or 0) - 1 do
        local v = try(function() return list:call("get_Item", i) end)
        if fn then v = fn(v, i) end
        if v ~= nil then out[#out + 1] = v end
    end
    return out
end

function U.array(arr, fn)
    local out = {}
    local n = arr and try(function() return arr:get_size() end) or 0
    for i = 0, (n or 0) - 1 do
        local v = try(function() return arr:get_element(i) end)
        if fn then v = fn(v, i) end
        if v ~= nil then out[#out + 1] = v end
    end
    return out
end

function U.dict(dict, fn)
    local entries = dict and try(function() return dict:get_field("_entries") end)
    local count = dict and try(function() return dict:get_field("_count") end) or 0
    for i = 0, count - 1 do
        local e = entries and try(function() return entries:get_element(i) end)
        if e then fn(try(function() return e:get_field("key") end), try(function() return e:get_field("value") end), i) end
    end
    return count
end

function U.pos(p)
    if not p then return nil end
    local x, y, z = try(function() return p.x end), try(function() return p.y end), try(function() return p.z end)
    if type(x) == "number" and type(y) == "number" and type(z) == "number" then return { x = x, y = y, z = z } end
    return nil
end

function U.is_zero(p) return (not p) or (p.x == 0 and p.y == 0 and p.z == 0) end

-- colours: imgui wants 0xAABBGGRR
function U.rgba(r, g, b, a)
    a = a or 255
    return ((a & 0xFF) << 24) | ((b & 0xFF) << 16) | ((g & 0xFF) << 8) | (r & 0xFF)
end
function U.alpha(col, mul)
    local a = math.floor(((col >> 24) & 0xFF) * mul + 0.5)
    if a < 0 then a = 0 elseif a > 255 then a = 255 end
    return (col & 0x00FFFFFF) | (a << 24)
end

local rgba = U.rgba
U.C = {
    gold = rgba(230, 184, 92), gold_dim = rgba(150, 120, 64), gold_hi = rgba(255, 222, 150),
    text = rgba(236, 230, 216), text_dim = rgba(168, 160, 146), text_faint = rgba(112, 108, 100),
    bg = rgba(14, 16, 20, 236), bg_soft = rgba(14, 16, 20, 190), bg_row = rgba(255, 255, 255, 10), bg_row_hi = rgba(230, 184, 92, 38),
    panel = rgba(24, 27, 33, 240), line = rgba(230, 184, 92, 90), line_soft = rgba(255, 255, 255, 26),
    red = rgba(232, 84, 70), amber = rgba(240, 160, 60), orange = rgba(255, 128, 16), green = rgba(120, 200, 120), teal = rgba(90, 200, 190),
    ice = rgba(140, 200, 245), violet = rgba(180, 150, 235), white = rgba(255, 255, 255), black = rgba(0, 0, 0),
    shadow = rgba(0, 0, 0, 200),
}

function U.dist2d(a, b)
    local dx, dz = a.x - b.x, a.z - b.z
    return math.sqrt(dx * dx + dz * dz)
end

function U.fmt_dist(m)
    if not m then return "?" end
    if m < 1000 then return string.format("%d m", math.floor(m + 0.5)) end
    return string.format("%.1f km", m / 1000)
end

-- bearing: 0 = north (-z), clockwise; +x is east
function U.bearing(from, to) return math.atan(to.x - from.x, -(to.z - from.z)) end
local DIRS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
function U.dir_name(rad)
    local deg = math.deg(rad) % 360
    return DIRS[(math.floor((deg + 22.5) / 45) % 8) + 1]
end

-- game hours -> "2d 4h" / "5h 20m" / "40m"
function U.fmt_hours(h)
    if not h then return "?" end
    if h < 0 then h = 0 end
    local total_min = math.floor(h * 60 + 0.5)
    local d = total_min // 1440
    local hh = (total_min % 1440) // 60
    local mm = total_min % 60
    if d > 0 then return string.format("%dd %dh", d, hh) end
    if hh > 0 then return string.format("%dh %02dm", hh, mm) end
    return string.format("%dm", mm)
end
-- one in-game hour lasts two real minutes
function U.fmt_real(h)
    if not h then return "?" end
    local min = h * 2
    if min >= 90 then return string.format("%.1f h real", min / 60) end
    if min >= 1 then return string.format("%d min real", math.floor(min + 0.5)) end
    return "under a minute"
end
function U.fmt_clock(hour, minute) return string.format("%02d:%02d", hour or 0, minute or 0) end

function U.clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
function U.lerp(a, b, t) return a + (b - a) * t end

return U
