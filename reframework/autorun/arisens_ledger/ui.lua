-- Arisen's Ledger: the ledger window. Custom-drawn on imgui draw lists; invisible buttons provide hit-testing.
local U = require("arisens_ledger/util")
local G = require("arisens_ledger/game")
local M = require("arisens_ledger/model")
local T = require("arisens_ledger/tokens")
local H = require("arisens_ledger/hud")
local F = require("arisens_ledger/fonts")
local C, try = U.C, U.try
local V = Vector2f.new
local CAT = M.CAT

local UI = { page = "overview", sel = nil, filter_cat = 0, f_dlc = false, f_new = false, f_main = false, sort = 1, search = "", cast = nil, cast_for = nil }
local PAGES = {
    { id = "overview", label = "Overview" }, { id = "quests", label = "Quests" }, { id = "risk", label = "At Risk" },
    { id = "timers", label = "Timers" }, { id = "explore", label = "Explore" }, { id = "settings", label = "Settings" },
}
local SORTS = { "Story order", "Nearest", "Level", "Name" }
local CAT_COL = { C.gold, C.ice, C.text_faint, C.green, C.red, C.red }
local RISK_COL = { [0] = C.text_dim, C.amber, C.amber, C.red }

local s = 1          -- ui scale for this frame
local dl = nil       -- current draw list
local cfg, core = nil, nil
local list_cache, list_key, list_at = {}, "", -100
local dist_at = -100

local function A(col, a) return U.alpha(col, a) end
local function px(v) return v * s end

local function style_push()
    local n_col, n_var = 0, 0
    local function col(idx, c) imgui.push_style_color(idx, c) n_col = n_col + 1 end
    local function var(name, v)
        local id = try(function() return imgui.ImGuiStyleVar[name] end)
        if id ~= nil and pcall(imgui.push_style_var, id, v) then n_var = n_var + 1 end
    end
    col(2, C.bg) col(3, U.rgba(0, 0, 0, 0)) col(5, C.gold_dim) col(7, U.rgba(255, 255, 255, 18)) col(8, U.rgba(255, 255, 255, 30)) col(9, U.rgba(255, 255, 255, 40))
    col(0, C.text) col(14, U.rgba(0, 0, 0, 40)) col(15, C.gold_dim) col(16, C.gold) col(17, C.gold_hi) col(18, C.gold)
    col(19, C.gold_dim) col(20, C.gold) col(21, U.rgba(255, 255, 255, 18)) col(22, U.rgba(230, 184, 92, 60)) col(23, U.rgba(230, 184, 92, 90))
    var("WindowRounding", 8.0 * s) var("WindowPadding", V(0, 0)) var("ItemSpacing", V(0, 0)) var("WindowBorderSize", 1.0)
    var("FrameRounding", 4.0 * s) var("ChildRounding", 0.0) var("ScrollbarSize", 10.0 * s) var("FramePadding", V(8 * s, 5 * s))
    return n_col, n_var
end

local function text(font, size, x, y, col, str) F.text(dl, font, size * s, x, y, col, str, false) end
local function text_w(font, size, str) return F.width(font, size * s, str) end

local function chip(x, y, label, col, filled)
    local w = text_w(F.bold, 12.5, label) + px(14)
    local h = px(20)
    if filled then dl:add_rect_filled(V(x, y), V(x + w, y + h), A(col, 0.22), px(10)) end
    dl:add_rect(V(x, y), V(x + w, y + h), A(col, 0.75), px(10), 0, 1.0)
    text(F.bold, 12.5, x + px(7), y + px(3), col, label)
    return w
end

-- a hit-tested, custom-drawn block laid out at the imgui cursor
local function block(id, w, h, draw_fn)
    local p = imgui.get_cursor_screen_pos()
    local clicked = imgui.invisible_button(id, V(w, math.max(1, h)))
    local hov = imgui.is_item_hovered()
    if draw_fn then draw_fn(p.x, p.y, w, h, hov) end
    return clicked, hov
end
local function gap(h) imgui.invisible_button("##gap" .. tostring(imgui.get_cursor_pos().y), V(1, math.max(1, px(h)))) end

local function section(w, title, right)
    block("##sec" .. title, w, px(34), function(x, y)
        text(F.title, 15, x, y + px(10), C.gold, string.upper(title))
        if right then
            local rw = text_w(F.body, 13, right)
            text(F.body, 13, x + w - rw, y + px(12), C.text_dim, right)
        end
        dl:add_line(V(x, y + px(32)), V(x + w, y + px(32)), C.line, 1.0)
    end)
    gap(6)
end

local function para(w, font, size, col, str, max_lines, indent)
    local lines = F.wrap(font, size * s, str, w - px(indent or 0), max_lines)
    if #lines == 0 then return end
    local lh = px(size + 4)
    block("##p" .. tostring(imgui.get_cursor_pos().y), w, lh * #lines, function(x, y)
        for i, ln in ipairs(lines) do text(font, size, x + px(indent or 0), y + (i - 1) * lh, col, ln) end
    end)
end

local function quest_label(q)
    if cfg.spoiler_safe and q.dlc and q.cat == CAT.LOCKED and q.clears == 0 then return "Undiscovered quest", true end
    return q.name, false
end

local function select_quest(id)
    UI.sel = id
    UI.page = "quests"
    UI.cast, UI.cast_for = nil, nil
end

local function is_pinned(id)
    for i, v in ipairs(cfg.pinned) do if v == id then return i end end
    return nil
end
local function toggle_pin(id)
    local i = is_pinned(id)
    if i then table.remove(cfg.pinned, i) else cfg.pinned[#cfg.pinned + 1] = id end
    core.save()
end

local function update_distances(now)
    if now - dist_at < 1.0 then return end
    dist_at = now
    for _, id in ipairs(M.order) do
        local q = M.quests[id]
        if q.cat == CAT.AVAILABLE or q.cat == CAT.PROGRESS then
            local w, d = M.nearest_waypoint(q)
            q.near, q.near_d = w, d
        else
            q.near, q.near_d = nil, nil
        end
    end
end

local function star(x, y, r, col, filled)
    local pts = {}
    for i = 0, 9 do
        local ang = -math.pi / 2 + i * math.pi / 5
        local rr = (i % 2 == 0) and r or r * 0.45
        pts[#pts + 1] = V(x + math.cos(ang) * rr, y + math.sin(ang) * rr)
    end
    for i = 1, 10 do
        local a, b = pts[i], pts[(i % 10) + 1]
        if filled then dl:add_triangle_filled(V(x, y), a, b, col) end
        dl:add_line(a, b, col, 1.2)
    end
end

local function hourglass(x, y, r, col)
    dl:add_triangle_filled(V(x - r, y - r), V(x + r, y - r), V(x, y), col)
    dl:add_triangle_filled(V(x - r, y + r), V(x + r, y + r), V(x, y), col)
end

---------------------------------------------------------------------------------------------------
-- quest row (shared by several pages)
---------------------------------------------------------------------------------------------------
local function quest_row(q, w, opts)
    opts = opts or {}
    local h = px(34)
    local name, masked = quest_label(q)
    local clicked = block("##q" .. (opts.tag or "") .. q.id, w, h, function(x, y, bw, bh, hov)
        local selected = (UI.sel == q.id and UI.page == "quests")
        if selected then dl:add_rect_filled(V(x, y), V(x + bw, y + bh - 1), C.bg_row_hi, px(4))
        elseif hov then dl:add_rect_filled(V(x, y), V(x + bw, y + bh - 1), C.bg_row, px(4)) end
        local cx = x + px(10)
        -- pin
        local pinned = is_pinned(q.id)
        star(cx + px(6), y + bh / 2, px(6.5), pinned and C.gold or A(C.text_faint, 0.7), pinned ~= nil)
        cx = cx + px(24)
        -- type tag
        local tag, tcol = "SIDE", C.text_faint
        if q.dlc_opener then tag, tcol = "START", C.ice
        elseif q.main then tag, tcol = "MAIN", C.gold elseif q.dlc then tag, tcol = "DLC", C.ice end
        text(F.bold, 11.5, cx, y + px(10), tcol, tag)
        cx = cx + px(44)
        -- name
        local right_w = px(262)
        local ncol = masked and C.text_faint or ((q.cat == CAT.DONE) and C.text_dim or C.text)
        text(F.body, 16.5, cx, y + px(7), ncol, F.fit(F.body, 16.5 * s, name, bw - (cx - x) - right_w))
        -- right side, laid out from the edge inward
        local rx = x + bw - px(10)
        local st_label = M.CAT_NAME[q.cat]
        local sw = text_w(F.bold, 12.5, st_label) + px(14)
        chip(rx - sw, y + px(7), st_label, CAT_COL[q.cat], q.cat == CAT.PROGRESS)
        rx = rx - px(112)
        if q.near_d then
            local dt = U.fmt_dist(q.near_d)
            text(F.body, 14.5, rx - text_w(F.body, 14.5, dt), y + px(8), C.text_dim, dt)
        end
        rx = rx - px(74)
        if q.level and q.level > 0 then
            local lt = "Lv " .. q.level
            text(F.body, 13.5, rx - text_w(F.body, 13.5, lt), y + px(9), C.text_faint, lt)
        end
        rx = rx - px(52)
        -- flags
        if q.timer then
            hourglass(rx - px(6), y + bh / 2, px(5.5), (q.timer.kind == "deadline") and C.red or ((q.timer.kind == "wait") and C.ice or C.amber))
            rx = rx - px(20)
        end
        if (q.risk or 0) >= 1 then
            dl:add_circle_filled(V(rx - px(6), y + bh / 2), px(5), RISK_COL[q.risk], 12)
            rx = rx - px(20)
        end
        if q.dead and #q.dead > 0 and (q.cat == CAT.AVAILABLE or q.cat == CAT.PROGRESS) then
            text(F.bold, 15, rx - px(10), y + px(8), C.red, "!")
            rx = rx - px(18)
        end
        local gd = cfg.guide and M.guide[q.id]
        if gd and gd.decision and not masked and (q.cat == CAT.AVAILABLE or q.cat == CAT.PROGRESS or q.cat == CAT.LOCKED) then
            local ct = "CHOICE"
            text(F.bold, 10.5, rx - text_w(F.bold, 10.5, ct), y + px(11), C.amber, ct)
            rx = rx - text_w(F.bold, 10.5, ct) - px(8)
        end
        if q.clears == 0 and q.cat ~= CAT.DONE and not masked then
            local nt = "NEW"
            text(F.bold, 10.5, rx - text_w(F.bold, 10.5, nt), y + px(11), C.violet, nt)
        end
    end)
    if clicked then
        local m = imgui.get_mouse()
        local p = imgui.get_cursor_screen_pos()
        -- a click on the star pins; anywhere else opens the quest
        local row_x = p.x
        if m and (m.x - row_x) < px(34) then toggle_pin(q.id) else select_quest(q.id) end
    end
end

---------------------------------------------------------------------------------------------------
-- pages
---------------------------------------------------------------------------------------------------
local function page_overview(w, now)
    local c = M.counts
    -- headline numbers
    block("##stats", w, px(86), function(x, y)
        local items = {
            { c.avail or 0, "Available", C.gold }, { c.prog or 0, "In progress", C.ice }, { (c.done or 0) .. " / " .. (c.total or 0), "Completed", C.green },
            { c.risk or 0, "At risk", ((c.risk or 0) > 0) and C.amber or C.text_dim }, { c.timers or 0, "On a clock", ((c.timers or 0) > 0) and C.amber or C.text_dim },
            { c.fresh or 0, "New to you", C.violet },
        }
        local cw = w / #items
        for i, it in ipairs(items) do
            local cx = x + (i - 1) * cw
            dl:add_rect_filled(V(cx + px(4), y), V(cx + cw - px(4), y + px(78)), C.panel, px(6))
            F.text_centered(dl, F.title, 26 * s, cx + cw / 2, y + px(10), it[3], tostring(it[1]), false)
            F.text_centered(dl, F.body, 13.5 * s, cx + cw / 2, y + px(50), C.text_dim, it[2], false)
        end
    end)
    gap(4)

    -- clocks
    if #M.timers > 0 then
        section(w, "On a clock", "in-game time, with the real-time equivalent")
        for i, q in ipairs(M.timers) do
            if i > 5 or not q.timer then break end
            local t = q.timer
            local clicked = block("##ot" .. q.id, w, px(30), function(x, y, bw, bh, hov)
                if hov then dl:add_rect_filled(V(x, y), V(x + bw, y + bh - 1), C.bg_row, px(4)) end
                local col = (t.kind == "deadline") and C.red or ((t.kind == "wait") and C.ice or C.amber)
                hourglass(x + px(14), y + bh / 2, px(5.5), col)
                text(F.body, 16, x + px(32), y + px(6), C.text, F.fit(F.body, 16 * s, q.name, bw * 0.45))
                local lbl = (t.kind == "deadline") and "must be done within" or ((t.kind == "wait") and "ready in about" or ((t.kind == "expires") and "may run out in" or "something changes in"))
                text(F.body, 14, x + bw * 0.5, y + px(7), C.text_dim, lbl)
                local span = U.fmt_hours(t.left) .. "   (" .. U.fmt_real(t.left) .. ")"
                text(F.bold, 15.5, x + bw - text_w(F.bold, 15.5, span) - px(10), y + px(6), col, span)
            end)
            if clicked then select_quest(q.id) end
        end
        gap(8)
    end

    -- story cut-offs
    section(w, "Before you advance the story", "from the game's own quest tree")
    local shown = 0
    for _, g in ipairs(M.groups) do
        local open = {}
        for _, id in ipairs(g.quests) do
            local q = M.quests[id]
            if q.cat == CAT.AVAILABLE or q.cat == CAT.PROGRESS then open[#open + 1] = q.name end
        end
        if #open > 0 and shown < 4 then
            shown = shown + 1
            local col = RISK_COL[g.level] or C.text_dim
            local head = "When '" .. (M.name(g.driver) or "?") .. "' completes, " .. #open .. " open quest" .. (#open > 1 and "s end" or " ends")
            local clicked = block("##og" .. g.driver, w, px(28), function(x, y, bw, bh, hov)
                if hov then dl:add_rect_filled(V(x, y), V(x + bw, y + bh - 1), C.bg_row, px(4)) end
                dl:add_circle_filled(V(x + px(14), y + bh / 2), px(5), col, 12)
                text(F.bold, 15.5, x + px(32), y + px(5), C.text, head)
                local rt = M.RISK_TEXT[g.level]
                text(F.body, 13.5, x + bw - text_w(F.body, 13.5, rt) - px(10), y + px(7), col, rt)
            end)
            if clicked then UI.page = "risk" end
            para(w, F.body, 14, C.text_dim, table.concat(open, ",  "), 2, 32)
            gap(6)
        end
    end
    if shown == 0 then para(w, F.body, 15, C.text_dim, "Nothing open is tied to a story cut-off right now.", 1, 4) end
    gap(8)

    -- nearest pick-ups
    section(w, "Closest quests to pick up", "where the game's oracle hints point")
    local near = {}
    for _, id in ipairs(M.order) do
        local q = M.quests[id]
        if q.cat == CAT.AVAILABLE and q.near_d then near[#near + 1] = q end
    end
    table.sort(near, function(a, b) return a.near_d < b.near_d end)
    for i, q in ipairs(near) do
        if i > 6 then break end
        quest_row(q, w, { tag = "ov" })
    end
    if #near == 0 then para(w, F.body, 15, C.text_dim, "No available quest has a known starting point at the moment.", 1, 4) end
    gap(10)
end

local function build_list(now)
    local key = table.concat({ UI.filter_cat, tostring(UI.f_dlc), tostring(UI.f_new), tostring(UI.f_main), UI.sort, UI.search, M.refreshed or 0 }, "|")
    if key == list_key and now - list_at < 1.0 then return list_cache end
    list_key, list_at = key, now
    local out, needle = {}, UI.search:lower()
    for _, id in ipairs(M.order) do
        local q = M.quests[id]
        local ok = true
        if UI.filter_cat == 1 then ok = q.cat == CAT.AVAILABLE
        elseif UI.filter_cat == 2 then ok = q.cat == CAT.PROGRESS
        elseif UI.filter_cat == 3 then ok = q.cat == CAT.LOCKED
        elseif UI.filter_cat == 4 then ok = q.cat == CAT.DONE
        elseif UI.filter_cat == 5 then ok = (q.cat == CAT.FAILED or q.cat == CAT.MISSED) end
        if ok and UI.f_dlc then ok = q.dlc end
        if ok and UI.f_main then ok = q.main end
        if ok and UI.f_new then ok = (q.clears == 0 and q.cat ~= CAT.DONE) end
        if ok and needle ~= "" then
            local name, masked = quest_label(q)
            ok = (not masked) and name:lower():find(needle, 1, true) ~= nil
        end
        if ok then out[#out + 1] = q end
    end
    if UI.sort == 2 then table.sort(out, function(a, b) return (a.near_d or 1e9) < (b.near_d or 1e9) end)
    elseif UI.sort == 3 then table.sort(out, function(a, b) if a.level ~= b.level then return a.level < b.level end return a.id < b.id end)
    elseif UI.sort == 4 then table.sort(out, function(a, b) return a.name < b.name end) end
    list_cache = out
    return out
end

local function filter_bar(w)
    local labels = { [0] = "All", "Available", "In progress", "Locked", "Completed", "Lost" }
    -- buttons are placed by hand along one row; nothing may sit underneath them or it would eat the clicks
    local base = imgui.get_cursor_pos()
    local row_y = base.y
    local cx = px(0)
    local function tbtn(id, label, active)
        local bw = text_w(F.bold, 13.5, label) + px(20)
        imgui.set_cursor_pos(V(base.x + cx, row_y + px(4)))
        local clicked = block(id, bw, px(26), function(x, y, _, bh, hov)
            local col = active and C.gold or C.text_dim
            if active then dl:add_rect_filled(V(x, y), V(x + bw, y + bh), A(C.gold, 0.18), px(13)) end
            dl:add_rect(V(x, y), V(x + bw, y + bh), A(col, (hov or active) and 0.9 or 0.4), px(13), 0, 1.0)
            text(F.bold, 13.5, x + px(10), y + px(5), (hov and not active) and C.text or col, label)
        end)
        cx = cx + bw + px(6)
        return clicked
    end
    for i = 0, 5 do
        if tbtn("##fc" .. i, labels[i], UI.filter_cat == i) then UI.filter_cat = i end
    end
    cx = cx + px(10)
    if tbtn("##fmain", "Main", UI.f_main) then UI.f_main = not UI.f_main end
    if tbtn("##fdlc", "DLC", UI.f_dlc) then UI.f_dlc = not UI.f_dlc end
    if tbtn("##fnew", "New to you", UI.f_new) then UI.f_new = not UI.f_new end
    cx = cx + px(10)
    if tbtn("##fsort", "Sort: " .. SORTS[UI.sort], false) then UI.sort = (UI.sort % #SORTS) + 1 end
    imgui.set_cursor_pos(V(base.x, base.y + px(34)))
    gap(1)
end

local function detail_pane(w, hgt, now)
    local q = UI.sel and M.quests[UI.sel]
    if not q then
        para(w, F.body, 15.5, C.text_dim, "Select a quest to see where to go, what it is waiting on, what it unlocks and when it is lost.", 4, 4)
        return
    end
    local name, masked = quest_label(q)
    for _, ln in ipairs(F.wrap(F.title, 21 * s, string.upper(name), w, 2)) do
        block("##dt" .. ln, w, px(28), function(x, y) text(F.title, 21, x, y, C.gold, ln) end)
    end
    block("##dchips", w, px(30), function(x, y)
        local cx = x
        cx = cx + chip(cx, y + px(4), M.CAT_NAME[q.cat], CAT_COL[q.cat], true) + px(6)
        if q.main then cx = cx + chip(cx, y + px(4), "Main quest", C.gold) + px(6) end
        if q.dlc_opener then cx = cx + chip(cx, y + px(4), "Starts Dark Arisen", C.ice, true) + px(6)
        elseif q.dlc then cx = cx + chip(cx, y + px(4), "Dark Arisen", C.ice) + px(6) end
        if q.level > 0 then cx = cx + chip(cx, y + px(4), "Level " .. q.level, C.text_dim) + px(6) end
        if q.clears == 0 and q.cat ~= CAT.DONE then cx = cx + chip(cx, y + px(4), "New to you", C.violet) + px(6)
        elseif q.clears > 0 then cx = cx + chip(cx, y + px(4), "Cleared before", C.text_faint) + px(6) end
    end)
    gap(4)
    if masked then
        para(w, F.body, 15, C.text_dim, "Details are hidden until this quest unlocks. Turn off spoiler-safe mode in Settings to see everything.", 3)
        return
    end
    -- actions
    do
        local base = imgui.get_cursor_pos()
        local cx = 0
        local function abtn(id, label, active)
            local bw = text_w(F.bold, 14, label) + px(24)
            imgui.set_cursor_pos(V(base.x + cx, base.y + px(2)))
            local clicked = block(id, bw, px(28), function(x, y, _, bh, hov)
                dl:add_rect_filled(V(x, y), V(x + bw, y + bh), A(C.gold, active and 0.30 or (hov and 0.18 or 0.08)), px(5))
                dl:add_rect(V(x, y), V(x + bw, y + bh), A(C.gold, 0.7), px(5), 0, 1.0)
                text(F.bold, 14, x + px(12), y + px(6), active and C.gold_hi or C.gold, label)
            end)
            cx = cx + bw + px(8)
            return clicked
        end
        local can_nav = (q.cat == CAT.AVAILABLE or q.cat == CAT.PROGRESS)
        if can_nav then
            if abtn("##nav", (cfg.nav_quest == q.id) and "Navigating" or "Navigate here", cfg.nav_quest == q.id) then
                cfg.nav_quest = (cfg.nav_quest ~= q.id) and q.id or nil
                core.save()
            end
        end
        if abtn("##pin", is_pinned(q.id) and "Pinned to HUD" or "Pin to HUD", is_pinned(q.id) ~= nil) then toggle_pin(q.id) end
        imgui.set_cursor_pos(V(base.x, base.y + px(34)))
        gap(1)
    end
    gap(6)
    para(w, F.body, 15, C.text_dim, q.summary, 6)
    gap(8)

    local function head(t) block("##dh" .. t, w, px(24), function(x, y) text(F.bold, 12.5, x, y + px(5), C.gold_dim, string.upper(t)) end) end
    local function line(col, str, font) para(w, font or F.body, 15, col, str, 3, 10) end

    if q.cat == CAT.PROGRESS and q.task then
        head("Current task")
        line(C.text, q.task, F.bold)
        if q.task_detail and q.task_detail ~= q.task then line(C.text_dim, q.task_detail) end
        gap(6)
    end
    if q.cat == CAT.PROGRESS and q.leads and #q.leads > 0 then
        head("Open leads")
        for _, l in ipairs(q.leads) do
            local where = l.pos and (U.fmt_dist(G.dist(l.pos)) .. " " .. U.dir_name(U.bearing(G.upos, l.pos))) or "location unknown"
            line(C.gold_hi, l.label .. "   -   " .. where)
            if l.from then line(C.text_faint, "from: " .. l.from) end
        end
        gap(6)
    end
    local gd = cfg.guide and M.guide[q.id]
    if gd and q.cat ~= CAT.DONE then
        head(gd.decision and "Guide  -  you will make a choice" or "Guide")
        if gd.how ~= "" then para(w, F.body, 15, C.text, gd.how, 6, 10) end
        if #gd.choices > 0 then
            gap(2)
            for _, ch in ipairs(gd.choices) do
                line(C.gold_hi, "- " .. (ch.option or "?"), F.bold)
                if ch.outcome and ch.outcome ~= "" then para(w, F.body, 14.5, C.text_dim, ch.outcome, 3, 22) end
                if ch.rewards and ch.rewards ~= "" then para(w, F.body, 14.5, C.green, "Rewards: " .. ch.rewards, 2, 22) end
            end
        end
        if gd.best ~= "" then gap(2) para(w, F.bold, 15, C.amber, "Best: " .. gd.best, 4, 10) end
        for _, wtxt in ipairs(gd.warnings) do line(C.red, "! " .. wtxt) end
        if gd.rewards ~= "" and #gd.choices == 0 then line(C.green, "Rewards: " .. gd.rewards) end
        if gd.follow_ups ~= "" then line(C.text_dim, "Leads to: " .. gd.follow_ups) end
        local conf = (gd.confidence == "low") and "Thin coverage online so far; treat as a best guess." or ((gd.confidence == "medium") and "Guides partly disagree; details may vary." or nil)
        line(C.text_faint, "From community walkthroughs" .. ((#gd.sources > 0) and (" (" .. #gd.sources .. " sources)") or "") .. ". " .. (conf or ""))
        gap(6)
    end
    if q.cat == CAT.PROGRESS and q.story and #q.story > 0 then
        head("Story so far")
        for i = #q.story, 1, -1 do
            local e = q.story[i]
            line(C.text, e.text, F.bold)
            if e.detail and e.detail ~= e.text then line(C.text_dim, e.detail) end
        end
        gap(6)
    end
    if q.cat == CAT.AVAILABLE or q.cat == CAT.PROGRESS then
        head("Where")
        local wps = {}
        for _, wp in ipairs(M.waypoints(q)) do if wp.pos then wps[#wps + 1] = wp end end
        M.rank_sort(wps)
        if #wps == 0 then
            line(C.text_dim, (q.cat == CAT.AVAILABLE) and "No one to talk to. It starts the way the description above says: a letter, a notice, an event, or the story." or "No marked destination for this step.")
        end
        for i, wp in ipairs(wps) do
            if i > 6 then break end
            local d = G.dist(wp.pos)
            local dy = wp.pos.y - G.upos.y
            local extra = (dy > 6) and (", up " .. math.floor(dy) .. " m") or ((dy < -6) and (", down " .. math.floor(-dy) .. " m") or "")
            block("##wp" .. i, w, px(24), function(x, y)
                dl:add_quad_filled(V(x + px(16), y + px(5)), V(x + px(22), y + px(11)), V(x + px(16), y + px(17)), V(x + px(10), y + px(11)), (wp.kind == "objective") and C.gold or C.gold_hi)
                local lbl = (wp.label or "?") .. (wp.why and ("  -  " .. wp.why) or "")
                text(i == 1 and F.bold or F.body, 15, x + px(32), y + px(2), i == 1 and C.gold_hi or ((wp.rank or 4) <= 2 and C.text or C.text_dim), F.fit(F.body, 15 * s, lbl, w * 0.62))
                local rt = U.fmt_dist(d) .. " " .. U.dir_name(U.bearing(G.upos, wp.pos)) .. extra
                text(F.body, 14.5, x + w - text_w(F.body, 14.5, rt) - px(6), y + px(2), C.text_dim, rt)
            end)
        end
        if q.windows and #q.windows > 0 and #q.windows <= 3 then
            local parts, open = {}, false
            for _, wd in ipairs(q.windows) do parts[#parts + 1] = wd.text if H.in_window(wd) then open = true end end
            line(open and C.green or C.amber, "Time of day: " .. table.concat(parts, " or ") .. (open and "  (open now)" or "  (closed now)"))
        elseif q.windows and #q.windows > 3 then
            line(C.text_dim, "Several steps depend on the time of day.")
        end
        gap(6)
    end
    if q.timer then
        head("Clock")
        local tl, tc = H.timer_line(q)
        line(tc, tl, F.bold)
        if q.timer.kind == "window" then line(C.text_dim, "The game is counting down on this quest before you have accepted it. It may expire or change when the time runs out.") end
        if q.timer.kind == "expires" then line(C.text_dim, "The game is counting down on this step and the task doesn't read like a wait, so treat it as a deadline.") end
        gap(6)
    end
    if q.items and #q.items > 0 then
        head("Items")
        for _, it in ipairs(q.items) do
            if it.need then
                local ok = (it.have or 0) >= it.need
                line(ok and C.green or C.text, string.format("%s:  have %d of %d needed", it.name, it.have or 0, it.need) .. (it.partial and "  (you can hand in part)" or ""))
                if it.options then line(C.text_dim, "Any of: " .. table.concat(it.options, ", ")) end
                if not ok then
                    local bits = {}
                    if (it.pawn or 0) > 0 then bits[#bits + 1] = "your pawn carries " .. it.pawn end
                    if (it.stored or 0) > 0 then bits[#bits + 1] = it.stored .. " in your storage (any inn)" end
                    if it.route == "shop" and it.shop then bits[#bits + 1] = "sold at " .. it.shop .. " (marked on the compass)" end
                    if #bits > 0 then line(C.gold, table.concat(bits, ";  ")) end
                end
                local ih = cfg.guide and M.guide[q.id] and M.guide[q.id].item_hints
                local hint = ih and not ok and M.item_hint(q.id, it.name)
                if hint then para(w, F.body, 14.5, C.text_dim, "Where: " .. hint, 6, 22) end
            else
                line(C.text_dim, string.format("%s:  carrying %d (amount needed isn't stated)", it.name, it.have or 0))
            end
        end
        gap(6)
    end
    if q.dead and #q.dead > 0 then
        head("Dead")
        line(C.red, table.concat(q.dead, ", ") .. ". A morgue can bring them back with a Wakestone.")
        gap(6)
    end
    if q.cutoffs and #q.cutoffs > 0 then
        head((q.end_any or #q.cutoffs == 1) and "Lost when" or "Lost when all of these are done")
        for _, cnd in ipairs(q.cutoffs) do
            local txt = M.cutoff_text(cnd) .. " completes"
            if cnd.guess then txt = txt .. "  (story marker; exact trigger not confirmed yet)" end
            line(RISK_COL[cnd.level] or C.text_dim, txt .. "   -   " .. M.RISK_TEXT[cnd.level])
        end
        gap(6)
    elseif q.cat ~= CAT.DONE and q.in_tree then
        head("Lost when")
        line(C.green, "Never. The quest tree has no cut-off for this quest.")
        gap(6)
    end
    local req = M.requirement_text(q)
    if req and q.cat == CAT.LOCKED then
        head("Unlocks after")
        line(q.unlocked and C.green or C.text, req .. (q.unlocked and "  (done; it now waits on a trigger in the world)" or ""))
        gap(6)
    end
    if q.unlocks and #q.unlocks > 0 then
        local names = {}
        for _, id in ipairs(q.unlocks) do
            local u = M.quests[id]
            if u then names[#names + 1] = (quest_label(u)) end
        end
        if #names > 0 then
            head("Completing it unlocks")
            para(w, F.body, 15, C.text, table.concat(names, ",  "), 5, 10)
            gap(6)
        end
    end
    if q.cat ~= CAT.DONE then
        if UI.cast_for ~= q.id then
            local clicked = block("##castbtn", w, px(26), function(x, y, _, _, hov)
                text(F.bold, 13.5, x, y + px(5), hov and C.gold_hi or C.gold, "Show everyone involved")
            end)
            if clicked then UI.cast, UI.cast_for = M.cast(q), q.id end
        elseif UI.cast then
            head("Everyone involved")
            for i, n in ipairs(UI.cast) do
                if i > 14 then break end
                local rt = n.dead and "dead" or (n.pos and (U.fmt_dist(G.dist(n.pos)) .. " " .. U.dir_name(U.bearing(G.upos, n.pos))) or "")
                block("##cast" .. i, w, px(22), function(x, y)
                    text(F.body, 14.5, x + px(10), y + px(2), n.dead and C.red or C.text, n.name)
                    text(F.body, 14, x + w - text_w(F.body, 14, rt) - px(6), y + px(2), n.dead and C.red or C.text_dim, rt)
                end)
            end
        end
    end
    gap(12)
end

local function page_quests(w, hgt, now)
    filter_bar(w)
    -- search
    do
        local base = imgui.get_cursor_pos()
        imgui.set_cursor_pos(V(base.x, base.y + px(2)))
        imgui.set_next_item_width(px(280))
        F.push(F.body, 15 * s)
        local ch, v = imgui.input_text("##search", UI.search)
        F.pop()
        if ch then UI.search = v or "" end
        imgui.set_cursor_pos(V(base.x, base.y + px(36)))
        gap(1)
    end
    local list = build_list(now)
    block("##count", w, px(4), function(x, y)
        dl:add_rect(V(x, y - px(34)), V(x + px(280), y - px(34) + px(28)), A(C.gold, 0.35), px(4), 0, 1.0)
        if UI.search == "" then text(F.body, 14, x + px(10), y - px(29), C.text_faint, "Search quests") end
        text(F.body, 13, x + px(292), y - px(27), C.text_faint, #list .. " shown")
    end)
    local list_w = math.floor(w * 0.56)
    local body_h = hgt - px(34 + 36 + 4 + 6)
    local base = imgui.get_cursor_pos()
    if imgui.begin_child_window("##qlist", V(list_w, body_h), false, 0) then
        local prev = dl
        dl = imgui.get_window_draw_list()
        local rw = list_w - px(14)
        for _, q in ipairs(list) do quest_row(q, rw) end
        if #list == 0 then para(rw, F.body, 15, C.text_dim, "No quests match these filters.", 2, 6) end
        dl = prev
    end
    imgui.end_child_window()
    imgui.set_cursor_pos(V(base.x + list_w + px(18), base.y))
    local dw = w - list_w - px(18)
    dl:add_line(V(imgui.get_cursor_screen_pos().x - px(9), imgui.get_cursor_screen_pos().y), V(imgui.get_cursor_screen_pos().x - px(9), imgui.get_cursor_screen_pos().y + body_h), C.line_soft, 1.0)
    if imgui.begin_child_window("##qdetail", V(dw, body_h), false, 0) then
        local prev = dl
        dl = imgui.get_window_draw_list()
        detail_pane(dw - px(14), body_h, now)
        dl = prev
    end
    imgui.end_child_window()
end

local function risk_reason(g)
    local d = M.quests[g.driver]
    if g.level >= 3 then return "This story quest is in progress. Finishing it closes the quests below." end
    if g.level == 2 then return "This story quest can be started now. Finishing it closes the quests below." end
    local req = d and M.requirement_text(d)
    if req then return "Not started. It unlocks after: " .. req .. "." end
    return "Not started yet."
end

local function risk_group(g, w)
    local col = RISK_COL[g.level] or C.text_dim
    block("##rg" .. g.driver, w, px(58), function(x, y)
        dl:add_rect_filled(V(x, y + px(4)), V(x + w, y + px(56)), C.panel, px(5))
        dl:add_rect_filled(V(x, y + px(4)), V(x + px(4), y + px(56)), col, px(2))
        text(F.title, 16, x + px(16), y + px(10), C.gold, string.upper("When '" .. (M.name(g.driver) or "?") .. "' completes"))
        local rt = (g.open or 0) .. " open quest" .. (((g.open or 0) == 1) and " is lost" or "s are lost")
        text(F.bold, 13.5, x + w - text_w(F.bold, 13.5, rt) - px(12), y + px(12), col, rt)
        text(F.body, 13.5, x + px(16), y + px(33), C.text_dim, F.fit(F.body, 13.5 * s, risk_reason(g), w - px(32)))
    end)
    for _, id in ipairs(g.quests) do
        local q = M.quests[id]
        if q.cat == CAT.AVAILABLE or q.cat == CAT.PROGRESS then quest_row(q, w, { tag = "rk" .. g.driver }) end
    end
    gap(10)
end

local CLOCK_LABEL = { deadline = "deadline", expires = "may run out", window = "running before you accept it", wait = "waiting period" }

local function page_risk(w)
    para(w, F.body, 15, C.text_dim, "Quests are lost two ways: a clock runs out, or a particular story quest completes. Both come from the game's own data.", 2, 4)
    gap(8)
    local clocks = {}
    for _, q in ipairs(M.timers) do if q.time_risk then clocks[#clocks + 1] = q end end
    if #clocks > 0 then
        section(w, "On a clock", "soonest first")
        for _, q in ipairs(clocks) do
            local t = q.timer
            local col = (t.kind == "deadline" or t.left <= 6) and C.red or C.amber
            local clicked = block("##rc" .. q.id, w, px(34), function(x, y, bw, bh, hov)
                if hov then dl:add_rect_filled(V(x, y), V(x + bw, y + bh - 1), C.bg_row, px(4)) end
                hourglass(x + px(16), y + bh / 2, px(6), col)
                text(F.body, 16.5, x + px(36), y + px(7), C.text, F.fit(F.body, 16.5 * s, q.name, bw * 0.42))
                text(F.body, 14, x + bw * 0.48, y + px(9), C.text_dim, CLOCK_LABEL[t.kind] or "")
                local span = U.fmt_hours(t.left) .. "  (" .. U.fmt_real(t.left) .. ")"
                text(F.bold, 15.5, x + bw - text_w(F.bold, 15.5, span) - px(10), y + px(8), col, span)
            end)
            if clicked then select_quest(q.id) end
        end
        gap(10)
    end
    local pressing, later, later_n = {}, {}, 0
    for _, g in ipairs(M.groups) do
        if (g.open or 0) > 0 then
            if g.level >= 1 then pressing[#pressing + 1] = g else later[#later + 1] = g later_n = later_n + g.open end
        end
    end
    section(w, "Before you advance the story", #pressing > 0 and "closest to being lost" or nil)
    if #pressing == 0 then
        para(w, F.body, 15.5, C.green, "No story quest that closes side quests is in progress, available or next in line.", 2, 4)
        gap(8)
    end
    for _, g in ipairs(pressing) do risk_group(g, w) end
    if #later > 0 then
        local clicked = block("##latertoggle", w, px(40), function(x, y, bw, bh, hov)
            dl:add_rect_filled(V(x, y + px(4)), V(x + bw, y + bh - px(4)), hov and C.bg_row_hi or C.bg_row, px(5))
            local label = (UI.risk_all and "Hide" or "Show") .. " what is tied to later story points  (" .. #later .. " story quests; safe for now)"
            text(F.bold, 14.5, x + px(16), y + px(11), hov and C.gold_hi or C.gold, label)
        end)
        if clicked then UI.risk_all = not UI.risk_all end
        gap(6)
        if UI.risk_all then for _, g in ipairs(later) do risk_group(g, w) end end
    end
end

local function page_timers(w)
    para(w, F.body, 15, C.text_dim, "Clocks the game is running on your quests right now. One in-game hour is two real minutes; resting or dozing on a bench moves them forward.", 3, 4)
    gap(8)
    if #M.timers == 0 then para(w, F.body, 15.5, C.text, "No quest is on a clock.", 1, 4) return end
    for _, q in ipairs(M.timers) do
        local t = q.timer or { kind = "wait", left = 0, total = 1 }
        local col = (t.kind == "deadline") and C.red or ((t.kind == "wait") and C.ice or C.amber)
        local clicked = block("##tm" .. q.id, w, px(62), function(x, y, bw, bh, hov)
            dl:add_rect_filled(V(x, y), V(x + bw, y + bh - px(6)), hov and U.rgba(34, 38, 46, 240) or C.panel, px(6))
            hourglass(x + px(20), y + px(20), px(7), col)
            text(F.bold, 17, x + px(42), y + px(8), C.text, F.fit(F.bold, 17 * s, q.name, bw * 0.5))
            local kind = (t.kind == "deadline") and "Deadline" or ((t.kind == "wait") and "Waiting period" or ((t.kind == "expires") and "May run out" or "Running before you accept it"))
            text(F.body, 13.5, x + px(42), y + px(30), C.text_dim, kind .. (q.task and ("  -  " .. F.fit(F.body, 13.5 * s, q.task, bw * 0.4)) or ""))
            local span = U.fmt_hours(t.left)
            text(F.title, 20, x + bw - text_w(F.title, 20, span) - px(14), y + px(6), col, span)
            local real = U.fmt_real(t.left)
            text(F.body, 13, x + bw - text_w(F.body, 13, real) - px(14), y + px(32), C.text_dim, real)
            -- progress
            local frac = U.clamp(1 - t.left / math.max(t.total, 0.01), 0, 1)
            local bx0, bx1, by = x + px(42), x + bw - px(170), y + px(49)
            dl:add_rect_filled(V(bx0, by), V(bx1, by + px(3)), C.line_soft, px(2))
            dl:add_rect_filled(V(bx0, by), V(bx0 + (bx1 - bx0) * frac, by + px(3)), col, px(2))
        end)
        if clicked then select_quest(q.id) end
    end
end

local function toggle_row(w, key, label, hint)
    local clicked = block("##tg" .. key, w, px(hint and 46 or 32), function(x, y, bw, bh, hov)
        if hov then dl:add_rect_filled(V(x, y), V(x + bw, y + bh - 1), C.bg_row, px(4)) end
        local on = cfg[key] == true
        local sx, sy = x + px(10), y + px(8)
        dl:add_rect_filled(V(sx, sy), V(sx + px(34), sy + px(16)), on and A(C.gold, 0.85) or U.rgba(255, 255, 255, 40), px(8))
        dl:add_circle_filled(V(sx + (on and px(26) or px(8)), sy + px(8)), px(6), on and C.bg or C.text_dim, 16)
        text(F.body, 16, x + px(58), y + px(5), C.text, label)
        if hint then text(F.body, 13, x + px(58), y + px(25), C.text_faint, hint) end
    end)
    if clicked then cfg[key] = not cfg[key] core.save() end
end

local function page_explore(w)
    section(w, "Seeker's Tokens")
    local audible = 0
    for _, t in ipairs(T.list) do if t.state >= 1 and t.state <= 4 then audible = audible + 1 end end
    para(w, F.body, 15.5, C.text, "Carrying " .. tostring(T.held or 0) .. ".   In chime range right now: " .. audible .. ".", 1, 4)
    para(w, F.body, 14, C.text_dim, "The dial beside the minimap appears when the nearest token is within 15 m and points at it in 3D. The compass and minimap show tokens from when the chime starts, about 60 m out. It only knows about tokens the game has loaded around you, so it is a sense, not a map.", 3, 4)
    gap(4)
    for i, t in ipairs(T.list) do
        if i > 8 then break end
        local d = G.dist(t.pos)
        local dy = t.pos.y - G.upos.y
        block("##tk" .. i, w, px(24), function(x, y)
            dl:add_circle_filled(V(x + px(16), y + px(11)), px(5), C.teal, 12)
            text(F.body, 15, x + px(32), y + px(2), C.text, "Token  " .. U.fmt_dist(d) .. " " .. U.dir_name(U.bearing(G.upos, t.pos)) .. ((math.abs(dy) > 3) and ((dy > 0) and (", up " .. math.floor(dy) .. " m") or (", down " .. math.floor(-dy) .. " m")) or ""))
        end)
    end
    gap(6)
    toggle_row(w, "token_arrow", "Token dial beside the minimap")
    toggle_row(w, "tokens_on_radar", "Show tokens in chime range on the compass and radar")
    gap(10)
    section(w, "Chests")
    local notable = {}
    for _, ch in ipairs(T.chests or {}) do if ch.notable then notable[#notable + 1] = ch end end
    table.sort(notable, function(a, b) return G.dist(a.pos) < G.dist(b.pos) end)
    para(w, F.body, 15.5, C.text, "Unopened chests loaded around you: " .. #(T.chests or {}) .. ", of which " .. #notable .. " hold a weapon, armour or another prize.", 1, 4)
    for i, ch in ipairs(notable) do
        if i > 10 then break end
        block("##ch" .. i, w, px(24), function(x, y)
            dl:add_rect_filled(V(x + px(10), y + px(6)), V(x + px(22), y + px(16)), C.orange, px(2))
            text(F.body, 15, x + px(32), y + px(2), C.text, F.fit(F.body, 15 * s, table.concat(ch.items, ", "), w * 0.68))
            local rt = U.fmt_dist(G.dist(ch.pos)) .. " " .. U.dir_name(U.bearing(G.upos, ch.pos))
            text(F.body, 14.5, x + w - text_w(F.body, 14.5, rt) - px(6), y + px(2), C.text_dim, rt)
        end)
    end
    gap(6)
    toggle_row(w, "notable_chests", "Show chests holding weapons, armour and other prizes on the minimap", "An orange square on the minimap once the chest is in its range (about 40 m). Nothing else.")
    toggle_row(w, "chests_on_radar", "Also show every other unopened chest on the minimap", "Same orange square, slightly smaller than chests holding gear.")
end

local function page_settings(w)
    section(w, "HUD")
    toggle_row(w, "hud", "Show the HUD", "F6 toggles everything at once.")
    toggle_row(w, "compass", "Compass strip")
    toggle_row(w, "tracker", "Quest tracker card")
    toggle_row(w, "tracker_left", "Put the tracker card in the top-left corner instead of the top-right")
    toggle_row(w, "radar", "Radar pips")
    toggle_row(w, "enemies_on_radar", "Enemies as red dots on the minimap", "Living hostiles only; larger dots for big monsters.")
    toggle_row(w, "radar_overlay", "Draw them on the game's minimap", "Off gives a separate radar above the minimap; F7 cycles its range from 60 m to 4 km.")
    toggle_row(w, "markers", "Markers in the world")
    toggle_row(w, "clock", "24-hour clock under the minimap")
    toggle_row(w, "fade_distant", "Fade goals in the distance", "Compass pips and world markers start fading past 150 m and are at about a third by 1.5 km.")
    toggle_row(w, "toasts", "Notices", "New quests, clocks running low, cut-offs coming up, deaths.")
    toggle_row(w, "hide_in_battle", "Step aside in combat", "Hides the compass, radar and tracker while a fight is on.")
    gap(8)
    section(w, "What the HUD follows")
    toggle_row(w, "auto_focus", "Follow the nearest objective when nothing is tracked", "Navigate always wins, then your priority quest, then pins.")
    toggle_row(w, "show_progress", "Show other quests in progress on the compass and radar")
    toggle_row(w, "show_givers", "Show quest-givers who are ready to talk", "Hollow diamonds on the minimap, only for people the game says will start a quest conversation right now.")
    gap(8)
    section(w, "Ledger")
    toggle_row(w, "guide", "Walkthrough notes", "Steps, choices and their outcomes, best path and warnings for each quest, from community guides. Shown in the quest details; quests with a decision get a CHOICE flag.")
    toggle_row(w, "guide_in_tracker", "Choice and warning hints on the tracker", "One amber line on the tracker card: the best way through a choice, or the main thing that can go wrong.")
    toggle_row(w, "spoiler_safe", "Spoiler-safe mode", "Hides the names and details of locked Dark Arisen quests you have never cleared.")
    toggle_row(w, "ledger_with_menu_only", "Only show this window with the REFramework menu", "The window needs that menu open for the mouse anyway. F8 hides it entirely.")
    gap(8)
    section(w, "Size")
    do
        local base = imgui.get_cursor_pos()
        block("##scale", px(150), px(40), function(x, y)
            text(F.body, 15.5, x + px(10), y + px(8), C.text, "HUD scale")
        end)
        imgui.set_cursor_pos(V(base.x + px(160), base.y + px(4)))
        imgui.set_next_item_width(px(260))
        local ch, v = imgui.slider_float("##hudscale", cfg.hud_scale, 0.7, 1.6)
        if ch then cfg.hud_scale = v core.save() end
        imgui.set_cursor_pos(V(base.x, base.y + px(40)))
        gap(1)
    end
    do
        local base = imgui.get_cursor_pos()
        block("##opac", px(150), px(40), function(x, y)
            text(F.body, 15.5, x + px(10), y + px(8), C.text, "HUD opacity")
        end)
        imgui.set_cursor_pos(V(base.x + px(160), base.y + px(4)))
        imgui.set_next_item_width(px(260))
        local ch, v = imgui.slider_float("##hudopac", cfg.hud_opacity, 0.3, 1.0)
        if ch then cfg.hud_opacity = v core.save() end
        imgui.set_cursor_pos(V(base.x, base.y + px(40)))
        gap(1)
    end
    do
        local base = imgui.get_cursor_pos()
        block("##lscale", px(150), px(40), function(x, y)
            text(F.body, 15.5, x + px(10), y + px(8), C.text, "Ledger scale")
        end)
        imgui.set_cursor_pos(V(base.x + px(160), base.y + px(4)))
        imgui.set_next_item_width(px(260))
        local ch, v = imgui.slider_float("##ledgerscale", cfg.ui_scale or 1.0, 0.8, 1.4)
        if ch then cfg.ui_scale = math.floor(v * 20 + 0.5) / 20 core.save() end
        imgui.set_cursor_pos(V(base.x, base.y + px(40)))
        gap(1)
    end
    gap(8)
    section(w, "About")
    para(w, F.body, 14, C.text_dim, "Arisen's Ledger " .. core.version .. ". Everything shown is read live from the game; the mod never writes to your save or to the game's state. Keys: F8 ledger, F7 radar range, F6 HUD.", 3, 4)
    if core.err then para(w, F.body, 14, C.red, "Last error: " .. core.err, 3, 4) end
    if M.scan_error then para(w, F.body, 14, C.red, "Scan error: " .. M.scan_error, 3, 4) end
end

---------------------------------------------------------------------------------------------------
function UI.draw(now, core_)
    core, cfg = core_, core_.cfg
    local size = imgui.get_display_size()
    s = (size.y / 1080) * (cfg.ui_scale or 1.0)
    local W, Hh = px(1180), px(760)
    imgui.set_next_window_size(V(W, Hh), 1)
    imgui.set_next_window_pos(V((size.x - W) / 2, (size.y - Hh) / 2), 4)
    local n_col, n_var = style_push()
    local open = imgui.begin_window("Arisen's Ledger", true, 1 | 2 | 32 | 8 | 16)
    local ok, err = pcall(function()
        if not open then cfg.ledger_open = false core.save() return end
        dl = imgui.get_window_draw_list()
        local wp, ws = imgui.get_window_pos(), imgui.get_window_size()
        local x0, y0, ww, wh = wp.x, wp.y, ws.x, ws.y
        update_distances(now)

        -- header
        local hh = px(62)
        dl:add_rect_filled(V(x0, y0), V(x0 + ww, y0 + hh), U.rgba(20, 22, 28, 255), px(8))
        text(F.title, 25, x0 + px(24), y0 + px(15), C.gold, "ARISEN'S LEDGER")
        local clock = "Day " .. tostring((G.day or 0) + 1) .. "   " .. U.fmt_clock(G.hour, G.minute)
        text(F.body, 15, x0 + px(292), y0 + px(24), C.text_dim, clock)
        local c = M.counts
        local hx = x0 + ww - px(64)
        local function hchip(label, col, filled)
            local cw = text_w(F.bold, 12.5, label) + px(14)
            hx = hx - cw
            chip(hx, y0 + px(21), label, col, filled)
            hx = hx - px(8)
        end
        if (c.timers or 0) > 0 then hchip(c.timers .. " on a clock", C.amber, true) end
        if (c.risk or 0) > 0 then hchip(c.risk .. " at risk", C.amber, true) end
        hchip((c.done or 0) .. " / " .. (c.total or 0) .. " done", C.green)
        hchip((c.prog or 0) .. " in progress", C.ice)
        hchip((c.avail or 0) .. " available", C.gold)
        dl:add_line(V(x0, y0 + hh), V(x0 + ww, y0 + hh), C.line, 1.0)
        -- close
        imgui.set_cursor_pos(V(ww - px(46), px(16)))
        local closed = block("##close", px(30), px(30), function(x, y, bw, bh, hov)
            local col = hov and C.gold_hi or C.text_dim
            dl:add_line(V(x + px(9), y + px(9)), V(x + bw - px(9), y + bh - px(9)), col, 2.0)
            dl:add_line(V(x + bw - px(9), y + px(9)), V(x + px(9), y + bh - px(9)), col, 2.0)
        end)
        if closed then cfg.ledger_open = false core.save() end

        -- navigation rail
        local nav_w = px(176)
        dl:add_rect_filled(V(x0, y0 + hh + 1), V(x0 + nav_w, y0 + wh), U.rgba(18, 20, 25, 255), px(8))
        dl:add_line(V(x0 + nav_w, y0 + hh), V(x0 + nav_w, y0 + wh), C.line_soft, 1.0)
        for i, p in ipairs(PAGES) do
            imgui.set_cursor_pos(V(0, hh + px(14) + (i - 1) * px(44)))
            local clicked = block("##nav" .. p.id, nav_w, px(42), function(x, y, bw, bh, hov)
                local active = (UI.page == p.id)
                if active then
                    dl:add_rect_filled(V(x, y + px(2)), V(x + bw, y + bh - px(2)), A(C.gold, 0.13), 0)
                    dl:add_rect_filled(V(x, y + px(2)), V(x + px(4), y + bh - px(2)), C.gold, 0)
                elseif hov then dl:add_rect_filled(V(x, y + px(2)), V(x + bw, y + bh - px(2)), C.bg_row, 0) end
                text(active and F.bold or F.body, 16.5, x + px(26), y + px(11), active and C.gold_hi or (hov and C.text or C.text_dim), p.label)
                local badge
                if p.id == "risk" and (c.risk or 0) > 0 then badge = c.risk elseif p.id == "timers" and (c.timers or 0) > 0 then badge = c.timers end
                if badge then
                    local bx = x + bw - px(30)
                    dl:add_circle_filled(V(bx, y + bh / 2), px(10), A(C.amber, 0.9), 16)
                    F.text_centered(dl, F.bold, 12.5 * s, bx, y + bh / 2 - px(8), C.bg, tostring(badge), false)
                end
            end)
            if clicked then UI.page = p.id end
        end
        text(F.body, 12, x0 + px(22), y0 + wh - px(52), C.text_faint, "F8  ledger")
        text(F.body, 12, x0 + px(22), y0 + wh - px(38), C.text_faint, "F7  radar range")
        text(F.body, 12, x0 + px(22), y0 + wh - px(24), C.text_faint, "F6  HUD")

        -- content
        local pad = px(22)
        local cw, ch = ww - nav_w - pad * 2, wh - hh - pad - px(10)
        imgui.set_cursor_pos(V(nav_w + pad, hh + px(14)))
        if not M.ready then
            para(cw, F.body, 16, C.text_dim, "Waiting for a loaded save...  " .. (M.init_error or ""), 2)
        elseif UI.page == "quests" then
            if imgui.begin_child_window("##pageq", V(cw + px(12), ch), false, 8 | 16) then
                local prev = dl
                dl = imgui.get_window_draw_list()
                page_quests(cw, ch, now)
                dl = prev
            end
            imgui.end_child_window()
        else
            if imgui.begin_child_window("##page", V(cw + px(12), ch), false, 0) then
                local prev = dl
                dl = imgui.get_window_draw_list()
                if UI.page == "overview" then page_overview(cw, now)
                elseif UI.page == "risk" then page_risk(cw)
                elseif UI.page == "timers" then page_timers(cw)
                elseif UI.page == "explore" then page_explore(cw)
                elseif UI.page == "settings" then page_settings(cw) end
                dl = prev
            end
            imgui.end_child_window()
        end
    end)
    imgui.end_window()
    imgui.pop_style_var(n_var)
    imgui.pop_style_color(n_col)
    if not ok then error(err) end
end

return UI
