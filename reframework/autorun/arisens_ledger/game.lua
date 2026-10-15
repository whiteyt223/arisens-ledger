-- Arisen's Ledger: per-frame game state (player, camera, clock, HUD visibility). Read-only.
local U = require("arisens_ledger/util")
local try = U.try
local G = { ok = false, yaw = 0 }

local function S(name) return sdk.get_managed_singleton(name) end
G.S = S

local last_slow = -100

function G.update(now)
    G.ok = false
    local cm = S("app.CharacterManager")
    local pl = cm and try(function() return cm:call("get_ManualPlayer") end)
    if not pl then return end
    G.player = pl
    local tr = try(function() return pl:call("get_GameObject"):call("get_Transform") end)
    if not tr then return end
    local lp = U.pos(try(function() return tr:call("get_Position") end))
    local up = U.pos(try(function() return tr:call("get_UniversalPosition") end))
    if not (lp and up) then return end
    G.lpos, G.upos = lp, up
    G.off = { x = up.x - lp.x, y = up.y - lp.y, z = up.z - lp.z }

    local cam = try(function() return sdk.get_primary_camera() end)
    local ctr = cam and try(function() return cam:call("get_GameObject"):call("get_Transform") end)
    G.cam = ctr and U.pos(try(function() return ctr:call("get_Position") end)) or lp
    local az = ctr and U.pos(try(function() return ctr:call("get_AxisZ") end))
    local ax = ctr and U.pos(try(function() return ctr:call("get_AxisX") end))
    local ay = ctr and U.pos(try(function() return ctr:call("get_AxisY") end))
    if az and ax and ay then G.cam_r, G.cam_u, G.cam_f = ax, ay, { x = -az.x, y = -az.y, z = -az.z } end
    if az then
        -- the camera looks down -Z
        local fx, fz = -az.x, -az.z
        if fx * fx + fz * fz > 1e-6 then G.yaw = math.atan(fx, -fz) end
    end

    if now - last_slow > 0.25 then
        last_slow = now
        local tm = S("app.TimeManager")
        if tm then
            G.day = try(function() return tm:call("get_InGameDay") end) or 0
            G.hour = try(function() return tm:call("get_InGameHour") end) or 0
            G.minute = try(function() return tm:call("get_InGameMinute") end) or 0
        end
        local gui = S("app.GuiManager")
        local hide = gui and try(function() return gui:call("get_IsHideHud") end)
        local alpha = gui and try(function() return gui:call("get_HudAlpha") end)
        G.hud_alpha = (type(alpha) == "number") and U.clamp(alpha, 0, 1) or 1
        local pm = S("app.PauseManager")
        local paused = pm and try(function() return pm:call("isPausedAny") end)
        local flow = S("app.MainFlowManager")
        local ingame = flow and try(function() return flow:call("get_IsInGamePhase") end)
        G.hud_hidden = (hide == true) or (paused == true) or (ingame == false)
        G.paused = paused == true
        local bm = S("app.BattleManager")
        G.in_battle = bm and try(function() return bm:call("get_IsBattleMode") end) == true
    end
    G.update_minimap(now)
    G.ok = true
end

-- the game's minimap (app.ui020301) zooms: ~2.65x in towns, 1x in the field, and again while sprinting.
-- Ask it where a point 10 m east and 10 m north of us would be drawn, so overlay pips share its exact scale
-- and rotation (heading-up or north-up). G.mm = { ex, ey, nx, ny } in minimap panel units per metre.
local mm_comp, mm_seek = nil, -100
local scene_td = sdk.find_type_definition("via.SceneManager")
function G.update_minimap(now)
    if not mm_comp and now - mm_seek > 2 then
        mm_seek = now
        mm_comp = try(function()
            local scene = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"), scene_td, "get_CurrentScene")
            local arr = scene:call("findComponents(System.Type)", sdk.typeof("app.ui020301"))
            return arr and arr:get_size() > 0 and arr:get_element(0) or nil
        end)
    end
    if not (mm_comp and G.upos) then G.mm = nil return end
    local u = G.upos
    local pe = try(function() return mm_comp:call("getIconPos", Vector3f.new(u.x + 10, u.y, u.z)) end)
    local pn = try(function() return mm_comp:call("getIconPos", Vector3f.new(u.x, u.y, u.z - 10)) end)
    if not (pe and pn) then mm_comp, G.mm = nil, nil return end
    local ex, ey, nx, ny = pe.x / 10, pe.y / 10, pn.x / 10, pn.y / 10
    if ex * ex + ey * ey < 1e-6 then G.mm = nil return end
    G.mm = { ex = ex, ey = ey, nx = nx, ny = ny }
end

-- universal position -> Vector3f in the engine's current local frame
function G.to_local(p) return Vector3f.new(p.x - G.off.x, p.y - G.off.y, p.z - G.off.z) end

function G.screen(p, lift)
    if not G.ok then return nil end
    local v = Vector3f.new(p.x - G.off.x, p.y - G.off.y + (lift or 0), p.z - G.off.z)
    local s = try(function() return draw.world_to_screen(v) end)
    if s then return s.x, s.y end
    return nil
end

function G.dist(p) return U.dist2d(G.upos, p) end

return G
