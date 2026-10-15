-- Seeker's Token sense: a 3D arrow above the Arisen while a token's chime is in range. Read-only.
local U = require("arisens_ledger/util")
local G = require("arisens_ledger/game")
local try, C = U.try, U.C
local V = Vector2f.new
local T = { list = {}, chests = {}, enemies = {}, held = nil }
local last_enemy = -100
local last_scan, last_held = -100, -100
local F = require("arisens_ledger/fonts")
local last_chest = -100
local TOKEN_ITEM_ID = 305
-- hint states: 0 out of range, 1 far (60 m), 2 middle (30 m), 3 near (15 m), 4 close (4 m), 5 collected

-- what is inside a chest, and whether it is worth a detour
local item_cache = {}
local m_item_name = try(function() return sdk.find_type_definition("app.ItemCommonParam"):get_method("get_item_name(System.Int32)") end)
local SPECIAL = { [76] = true, [77] = true, [78] = true, [80] = true, [81] = true, [619] = true, [620] = true }
local function item_info(id)
    local hit = item_cache[id]
    if hit then return hit end
    local im = G.S("app.ItemManager")
    local dict = im and try(function() return im:call("get_ItemDataDict") end)
    local prm = dict and try(function() return dict:call("get_Item", id) end)
    local name = m_item_name and try(function() return m_item_name:call(nil, id) end)
    if type(name) == "userdata" then name = U.str(name) end
    local dtype = prm and try(function() return prm:get_field("<DataType>k__BackingField") end) or 1
    local price = prm and try(function() return prm:get_field("_BuyPrice") end) or 0
    local info = { name = (type(name) == "string" and #name > 0) and name or ("Item " .. id), gear = (dtype ~= 1), price = price,
        notable = (dtype ~= 1) or SPECIAL[id] == true or price >= 5000 }
    item_cache[id] = info
    return info
end

-- live hostile creatures around the Arisen, for the minimap
function T.scan_enemies(now)
    if now - last_enemy < 0.2 then return end
    last_enemy = now
    local out = {}
    local em = G.S("app.EnemyManager")
    local lst = em and try(function() return em:get_field("_EnemyList") end)
    local me = G.player
    for _, e in ipairs(U.list(lst)) do
        local ch = try(function() return e:call("get_Chara") end)
        if ch and try(function() return ch:call("get_IsDead") end) == false then
            local hostile = (not me) or try(function() return ch:call("isHostile", me) end) ~= false
            if hostile then
                local p = U.pos(try(function() return e:call("get_GameObject"):call("get_Transform"):call("get_UniversalPosition") end))
                if p then
                    local hp = try(function() return ch:call("get_Hp") end) or 0
                    out[#out + 1] = { pos = p, big = hp >= 30000 }
                end
            end
        end
    end
    T.enemies = out
end

function T.scan(now)
    if now - last_scan < 0.4 then return end
    last_scan = now
    local out = {}
    local gm = G.S("app.GimmickManager")
    local proofs = gm and try(function() return gm:call("get_ProofGimmicks") end)
    for _, h in ipairs(U.list(proofs)) do
        local gb = try(function() return h:get_field("_GimmickBase") end)
        if gb and U.tname(gb) == "app.Gm82_036" then
            local p = U.pos(try(function() return gb:call("get_GameObject"):call("get_Transform"):call("get_UniversalPosition") end))
            local st = try(function() return h:get_field("_NowState") end) or 0
            if p and st ~= 5 then out[#out + 1] = { pos = p, state = st } end
        end
    end
    T.list = out
    if now - last_chest > 1.5 then
        last_chest = now
        local chests = {}
        for _, c in ipairs(U.list(gm and try(function() return gm:call("get_TreasureBoxGimmicks") end))) do
            if try(function() return c:call("get_IsOpenedFreeBit") end) ~= true then
                local p = U.pos(try(function() return c:call("get_GameObject"):call("get_Transform"):call("get_UniversalPosition") end))
                if p then
                    local ch = { pos = p, items = {}, notable = false }
                    local best
                    for _, it in ipairs(U.list(try(function() return c:get_field("ItemList") end))) do
                        local iid, num = try(function() return it:get_field("ItemId") end), try(function() return it:get_field("ItemNum") end) or 1
                        if type(iid) == "number" and iid > 0 then
                            local info = item_info(iid)
                            ch.items[#ch.items + 1] = (num > 1) and (info.name .. " x" .. num) or info.name
                            if info.notable then
                                ch.notable = true
                                if not best or (info.gear and not best.gear) or (info.gear == best.gear and info.price > best.price) then best = info end
                            end
                        end
                    end
                    ch.label = best and best.name or (ch.items[1] or "Chest")
                    ch.key = string.format("%d:%d:%d", math.floor(p.x), math.floor(p.y), math.floor(p.z))
                    chests[#chests + 1] = ch
                end
            end
        end
        T.chests = chests
    end
    if now - last_held > 5 then
        last_held = now
        local im = G.S("app.ItemManager")
        T.held = im and G.player and try(function() return im:call("getHaveNum(System.Int32, app.Character)", TOKEN_ITEM_ID, G.player) end)
    end
end

function T.nearest_audible()
    local best, bd
    for _, t in ipairs(T.list) do
        if t.state >= 1 and t.state <= 4 then
            local dx, dy, dz = t.pos.x - G.upos.x, t.pos.y - G.upos.y, t.pos.z - G.upos.z
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if not bd or d < bd then best, bd = t, d end
        end
    end
    return best, bd
end

local function norm(a)
    local l = math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
    if l < 1e-6 then return nil end
    return { x = a.x / l, y = a.y / l, z = a.z / l }
end
local function cross(a, b) return { x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x } end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function add(a, b, k) return { x = a.x + b.x * k, y = a.y + b.y * k, z = a.z + b.z * k } end

local STATE_COL = {
    [1] = { 90, 200, 190 }, [2] = { 120, 225, 200 }, [3] = { 240, 200, 100 }, [4] = { 255, 236, 170 },
}
local TILT = math.rad(52) -- the dial is viewed from above and behind, so "ahead" reads as "up"
local CT, ST = math.cos(TILT), math.sin(TILT)

local function shadow_text(d, x, y, col, s)
    d:add_text(V(x + 2, y + 2), C.shadow, s)
    d:add_text(V(x, y), col, s)
end

-- opts: x, y = centre of the dial in pixels; scale; alpha
function T.draw(now, opts)
    local tok, dist = T.nearest_audible()
    if not tok or not G.cam_r then return end
    if dist > (opts.range or 15) then return end -- only pops up once the token is close
    local d = imgui.get_background_draw_list()
    local scale, alpha = opts.scale, opts.alpha
    local rgb = STATE_COL[tok.state] or STATE_COL[1]
    local speed = ({ 2.0, 3.0, 4.5, 7.0 })[tok.state] or 2.0
    local pulse = 0.5 + 0.5 * math.sin(now * speed)
    local a = math.floor(255 * alpha)
    local function col(mul, aa)
        return U.rgba(math.min(255, math.floor(rgb[1] * mul)), math.min(255, math.floor(rgb[2] * mul)), math.min(255, math.floor(rgb[3] * mul)), math.floor((aa or 1) * a))
    end
    local outline = U.rgba(0, 0, 0, math.floor(a * 0.9))

    -- ring the token itself once it is close and in view
    if dist < 12 then
        local sx, sy = G.screen(tok.pos, 0.2)
        if sx then
            local r = (10 + 6 * pulse) * scale
            d:add_circle(V(sx, sy), r + 2, U.rgba(0, 0, 0, math.floor(a * 0.7)), 32, 4.0 * scale)
            d:add_circle(V(sx, sy), r, col(1.0), 32, 2.5 * scale)
        end
    end

    -- direction from the Arisen's chest to the token, expressed in camera space, then tilted
    local w = norm({ x = tok.pos.x - G.upos.x, y = tok.pos.y - (G.upos.y + 1.2), z = tok.pos.z - G.upos.z })
    if not w then return end
    local cx, cy, cz = dot(w, G.cam_r), dot(w, G.cam_u), dot(w, G.cam_f)
    local v = norm({ x = cx, y = cy * CT + cz * ST, z = -cy * ST + cz * CT }) -- z grows away from the viewer
    if not v then return end

    local ox, oy = opts.x, opts.y
    local R = 44 * scale
    -- backing plate
    d:add_circle_filled(V(ox, oy), R * 1.42, U.rgba(10, 12, 16, math.floor(a * 0.72)), 48)
    d:add_circle(V(ox, oy), R * 1.42, U.rgba(230, 184, 92, math.floor(a * (0.55 + 0.35 * pulse))), 48, 2.0 * scale)
    -- ground ellipse, to anchor the 3D read
    do
        local ec, rx, ry, prev = U.rgba(230, 184, 92, math.floor(a * 0.30)), R * 1.02, R * 1.02 * CT, nil
        for i = 0, 36 do
            local ang = i / 36 * 2 * math.pi
            local p = V(ox + math.cos(ang) * rx, oy + R * 0.1 + math.sin(ang) * ry)
            if prev then d:add_line(prev, p, ec, 1.5 * scale) end
            prev = p
        end
    end

    local function proj(p)
        local k = 1 / (1 + 0.28 * p.z)
        return V(ox + p.x * R * k, oy - p.y * R * k), p.z
    end
    local ref = math.abs(v.y) < 0.92 and { x = 0, y = 1, z = 0 } or { x = 1, y = 0, z = 0 }
    local u1 = norm(cross(v, ref)) or { x = 1, y = 0, z = 0 }
    local u2 = norm(cross(u1, v)) or { x = 0, y = 1, z = 0 }
    local bob = 0.06 * pulse
    local tail, neck, tip = add({ x = 0, y = 0, z = 0 }, v, -0.95 + bob), add({ x = 0, y = 0, z = 0 }, v, 0.22 + bob), add({ x = 0, y = 0, z = 0 }, v, 1.08 + bob)
    local sw, hw = 0.11, 0.38

    local t1, t2, t3, t4 = proj(add(tail, u1, sw)), proj(add(tail, u1, -sw)), proj(add(tail, u2, sw)), proj(add(tail, u2, -sw))
    local n1, n2, n3, n4 = proj(add(neck, u1, sw)), proj(add(neck, u1, -sw)), proj(add(neck, u2, sw)), proj(add(neck, u2, -sw))
    local ptip = proj(tip)
    local base, bs = { add(neck, u1, hw), add(neck, u2, hw), add(neck, u1, -hw), add(neck, u2, -hw) }, {}
    for i = 1, 4 do bs[i] = proj(base[i]) end

    local function shaft()
        d:add_quad_filled(t1, n1, n2, t2, col(0.70))
        d:add_quad_filled(t3, n3, n4, t4, col(0.92))
        d:add_quad(t1, n1, n2, t2, outline, 1.5)
        d:add_quad(t3, n3, n4, t4, outline, 1.5)
    end
    local function head()
        local faces, shade = {}, { 1.12, 0.86, 0.6, 0.95 }
        for i = 1, 4 do
            local j = (i % 4) + 1
            faces[#faces + 1] = { a = bs[i], b = bs[j], depth = (base[i].z + base[j].z + tip.z) / 3, shade = shade[i] }
        end
        table.sort(faces, function(p, q) return p.depth > q.depth end)
        d:add_quad_filled(bs[1], bs[2], bs[3], bs[4], col(0.45))
        d:add_quad(bs[1], bs[2], bs[3], bs[4], outline, 1.5)
        for _, f in ipairs(faces) do
            d:add_triangle_filled(f.a, f.b, ptip, col(f.shade))
            d:add_triangle(f.a, f.b, ptip, outline, 1.5)
        end
    end
    -- whichever end is further from the viewer goes down first
    if v.z > 0 then head() shaft() else shaft() head() end

    -- distance and height under the dial
    local dy = tok.pos.y - G.upos.y
    local label = U.fmt_dist(dist)
    if dy > 3 then label = label .. "   up " .. math.floor(dy + 0.5) .. " m"
    elseif dy < -3 then label = label .. "   down " .. math.floor(-dy + 0.5) .. " m" end
    F.text_centered(d, F.bold, 17 * scale, ox, oy + R * 1.5, col(1.15), label, true)
end

return T
