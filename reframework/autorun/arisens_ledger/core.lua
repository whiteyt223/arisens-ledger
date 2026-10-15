-- Arisen's Ledger: core. Wires the model, HUD and ledger window together and owns the settings.
for _, m in ipairs({ "util", "game", "model", "tokens", "hud", "ui" }) do package.loaded["arisens_ledger/" .. m] = nil end
local U = require("arisens_ledger/util")
local G = require("arisens_ledger/game")
local M = require("arisens_ledger/model")
local T = require("arisens_ledger/tokens")
local H = require("arisens_ledger/hud")
local ok_ui, UI = pcall(require, "arisens_ledger/ui")

local VERSION = "1.0.0"
local CFG_FILE = "arisens_ledger.json"
local DEFAULTS = {
    hud = true, compass = true, tracker = true, radar = true, markers = true, toasts = true, token_arrow = true,
    tokens_on_radar = true, chests_on_radar = true, show_givers = true, giver_range = 400, show_progress = true,
    auto_focus = true, hide_in_battle = true, radar_overlay = true, notable_chests = true, fade_distant = true, enemies_on_radar = true, clock = true, hud_scale = 1.0, hud_opacity = 1.0, radar_range = 2,
    ledger_open = true, ledger_with_menu_only = true, spoiler_safe = true, guide = true, guide_in_tracker = true,
    key_ledger = 0x77, key_radar = 0x76, key_hud = 0x75, -- F8, F7, F6
}
local cfg = json.load_file(CFG_FILE) or {}
for k, v in pairs(DEFAULTS) do if cfg[k] == nil then cfg[k] = v end end
cfg.pinned = cfg.pinned or {}

local C = { version = VERSION, cfg = cfg, err = nil, frame = 0 }
local dirty, dirty_at = false, 0
function C.save() dirty = true dirty_at = os.clock() end

local keys_down = {}
local function pressed(vk)
    local down = U.try(function() return reframework:is_key_down(vk) end) == true
    local was = keys_down[vk]
    keys_down[vk] = down
    return down and not was
end

C.perf = {}
local function guarded(name, f, ...)
    local t0 = os.clock()
    local ok, err = pcall(f, ...)
    local ms = (os.clock() - t0) * 1000
    local p = C.perf[name] or { avg = 0, max = 0 }
    p.avg = p.avg * 0.98 + ms * 0.02
    if ms > p.max then p.max = ms end
    C.perf[name] = p
    if not ok then C.err = name .. ": " .. tostring(err) end
    return ok
end

C.on_frame = function()
    local now = os.clock()
    C.frame = C.frame + 1
    if pressed(cfg.key_ledger) then cfg.ledger_open = not cfg.ledger_open C.save() end
    if pressed(cfg.key_hud) then cfg.hud = not cfg.hud C.save() end
    if pressed(cfg.key_radar) then
        cfg.radar_range = (cfg.radar_range % #H.RANGES) + 1
        C.save()
    end
    if dirty and now - dirty_at > 1.0 then dirty = false pcall(json.dump_file, CFG_FILE, cfg) end

    if not guarded("game", G.update, now) then return end
    if not G.ok then return end
    guarded("model", M.tick, now)
    if C.frame % 4 == 0 then guarded("scan", M.deep_step, now) end
    guarded("tokens", T.scan, now)
    if cfg.enemies_on_radar and cfg.radar then guarded("enemies", T.scan_enemies, now) end
    if cfg.hud and not G.hud_hidden then guarded("hud", H.draw, now, cfg) end
    if ok_ui and UI and cfg.ledger_open then
        local menu_open = U.try(function() return reframework:is_drawing_ui() end) == true
        if menu_open or not cfg.ledger_with_menu_only then guarded("ledger", UI.draw, now, C) end
    end
end

C.on_draw_ui = function()
    if imgui.tree_node("Arisen's Ledger " .. VERSION) then
        local ch, v = imgui.checkbox("Ledger window (F8)", cfg.ledger_open) if ch then cfg.ledger_open = v C.save() end
        ch, v = imgui.checkbox("HUD (F6)", cfg.hud) if ch then cfg.hud = v C.save() end
        if not ok_ui then imgui.text("Ledger failed to load: " .. tostring(UI)) end
        if C.err then imgui.text("Last error: " .. C.err) end
        if M.init_error then imgui.text("Status: " .. M.init_error) end
        imgui.tree_pop()
    end
end

C.state = function()
    return { err = C.err, ui = ok_ui or tostring(UI), ready = M.ready, init = M.init_error, scan = M.scan_error, counts = M.counts,
        focus = H.focus and H.focus.name, src = H.focus_src, wps = #H.wps, hidden = G.hud_hidden, battle = G.in_battle, tokens = #T.list, chests = #(T.chests or {}),
        baseline = M.baseline, cycle = M.scan_cycle, perf = C.perf }
end
C.H, C.M, C.G, C.T = H, M, G, T
return C
