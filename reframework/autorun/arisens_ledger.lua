-- Arisen's Ledger for Dragon's Dogma 2 (REFramework script)
-- Quest ledger, tracker, compass, minimap overlay, clocks and walkthrough notes.
-- Read-only: it reads quest, NPC, time and map state from the game and draws over it.
-- It never writes to your save or changes the game. The only file it writes is its own
-- settings: reframework/data/arisens_ledger.json
local CORE = "arisens_ledger/core"
local core, load_error = nil, nil

do
    local ok, res = pcall(require, CORE)
    if ok and type(res) == "table" then core = res else load_error = tostring(res) end
    log.info("[Arisen's Ledger] " .. (load_error and ("failed to load: " .. load_error) or "loaded"))
end

re.on_frame(function()
    if not (core and core.on_frame) then return end
    local ok, err = pcall(core.on_frame)
    if not ok and not load_error then
        load_error = "runtime: " .. tostring(err)
        log.error("[Arisen's Ledger] " .. load_error)
    end
end)

re.on_draw_ui(function()
    if core and core.on_draw_ui then pcall(core.on_draw_ui) end
    if load_error and imgui.tree_node("Arisen's Ledger (error)") then
        imgui.text(load_error)
        imgui.tree_pop()
    end
end)
