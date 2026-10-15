-- Arisen's Ledger: in-world HUD (compass, tracker card, radar, world markers, notices). Draw-only.
local U = require("arisens_ledger/util")
local G = require("arisens_ledger/game")
local M = require("arisens_ledger/model")
local T = require("arisens_ledger/tokens")
local F = require("arisens_ledger/fonts")
local C, try = U.C, U.try
local V = Vector2f.new
local CAT = M.CAT

local H = { focus = nil, focus_src = nil, wps = {}, toasts = {}, event_idx = 0 }
H.RANGES = { 60, 150, 400, 1200, 4000 }

local KIND_COL = {
    objective = C.gold, person = C.gold_hi, giver = C.text, pinned = C.gold, token = C.teal, chest = C.orange,
}
local TOAST_COL = { new = C.gold, start = C.ice, done = C.green, fail = C.red, risk = C.amber, timer = C.red, dead = C.red, info = C.text_dim }

local function A(col, a) return U.alpha(col, a) end
H.fade_on = true
-- goals far away recede: full strength to 150 m, easing to 35% by 1.5 km (the main target keeps at least 60%)
local function fade(dist, is_main)
    if not H.fade_on or not dist then return 1 end
    local f = 1 - U.clamp((dist - 150) / 1350, 0, 1) * 0.65
    if is_main and f < 0.6 then f = 0.6 end
    return f
end

local function diamond(d, x, y, r, col, filled, thick)
    local p1, p2, p3, p4 = V(x, y - r), V(x + r, y), V(x, y + r), V(x - r, y)
    if filled then d:add_quad_filled(p1, p2, p3, p4, col) else d:add_quad(p1, p2, p3, p4, col, thick or 2.0) end
end

local function icon(d, kind, x, y, r, a, strong)
    local col = A(KIND_COL[kind] or C.text, a)
    local dark = A(C.black, a * 0.85)
    if kind == "token" then
        d:add_circle_filled(V(x, y), r * 0.8 + 1.5, dark, 16)
        d:add_circle_filled(V(x, y), r * 0.8, col, 16)
    elseif kind == "chest" then
        d:add_rect_filled(V(x - r * 0.8 - 1.5, y - r * 0.6 - 1.5), V(x + r * 0.8 + 1.5, y + r * 0.6 + 1.5), dark, 2.0)
        d:add_rect_filled(V(x - r * 0.8, y - r * 0.6), V(x + r * 0.8, y + r * 0.6), col, 2.0)
    elseif kind == "giver" then
        diamond(d, x, y, r + 1.5, dark, true)
        diamond(d, x, y, r, A(C.bg, a), true)
        diamond(d, x, y, r, col, false, 2.0)
    else
        diamond(d, x, y, r + 2, dark, true)
        diamond(d, x, y, r, col, true)
        if strong then diamond(d, x, y, r * 0.42, A(C.bg, a), true) end
    end
end

local function wrap_deg(x)
    x = (x + 180) % 360 - 180
    return x
end

---------------------------------------------------------------------------------------------------
-- what the HUD is following
---------------------------------------------------------------------------------------------------
local last_build, last_people = -100, -100

local function pick_focus(cfg)
    -- an explicit "Navigate here" in the ledger beats the game's priority quest
    local q
    if cfg.nav_quest then
        q = M.quests[cfg.nav_quest]
        if q and (q.cat == CAT.PROGRESS or q.cat == CAT.AVAILABLE) then return q, "Navigating" end
        if q and M.refreshed and (q.cat == CAT.DONE or q.cat == CAT.FAILED or q.cat == CAT.MISSED) then cfg.nav_quest = nil end
    end
    q = M.quests[M.tracked]
    if q and (q.cat == CAT.PROGRESS or q.cat == CAT.AVAILABLE) then return q, "Priority quest" end
    for _, id in ipairs(cfg.pinned or {}) do
        q = M.quests[id]
        if q and (q.cat == CAT.PROGRESS or q.cat == CAT.AVAILABLE) then return q, "Pinned" end
    end
    if cfg.auto_focus then
        local best, bd
        for _, id in ipairs(M.order) do
            q = M.quests[id]
            if q.cat == CAT.PROGRESS then
                local _, d = M.nearest_waypoint(q)
                if d and (not bd or d < bd) then best, bd = q, d end
            end
        end
        if best then return best, "Nearest objective" end
    end
    return nil, nil
end

local function build(now, cfg)
    if now - last_build < 0.25 then return end
    last_build = now
    local people_due = now - last_people > 1.0
    if people_due then last_people = now end

    local focus, src = pick_focus(cfg)
    H.focus, H.focus_src = focus, src
    local wps, seen = {}, {}
    local function push(w, role)
        local d = G.dist(w.pos)
        wps[#wps + 1] = { pos = w.pos, label = w.label, kind = w.kind, quest = w.quest, role = role, dist = d, ready = w.ready, priority = w.priority,
            brg = U.bearing(G.upos, w.pos), dy = w.pos.y - G.upos.y }
    end
    if focus then
        if people_due then M.refresh_people(focus) end
        for _, w in ipairs(M.waypoints(focus)) do
            -- hollow diamonds are reserved for "ready to offer you a quest"; a chosen target is always gold
            if w.kind == "giver" then w.kind = "person" end
            push(w, "focus")
        end
        seen[focus.id] = true
    end
    for _, id in ipairs(cfg.pinned or {}) do
        local q = M.quests[id]
        if q and not seen[id] and (q.cat == CAT.PROGRESS or q.cat == CAT.AVAILABLE) then
            seen[id] = true
            if people_due then M.refresh_people(q) end
            local w = M.nearest_waypoint(q)
            if w then
                w.label = q.name
                if w.kind == "giver" then w.kind = "person" end
                push(w, "pinned")
            end
        end
    end
    local max_r = H.RANGES[#H.RANGES]
    if cfg.show_progress then
        for _, id in ipairs(M.order) do
            local q = M.quests[id]
            if q.cat == CAT.PROGRESS and not seen[id] then
                seen[id] = true
                local w, d = M.nearest_waypoint(q)
                if w and d <= max_r then w.label = q.name push(w, "other") end
            end
        end
    end
    if cfg.show_givers then
        for _, id in ipairs(M.order) do
            local q = M.quests[id]
            if q.cat == CAT.AVAILABLE and not seen[id] then
                -- only people the game says will start this quest's conversation right now
                local best, bd
                for _, w in ipairs(M.waypoints(q)) do
                    if w.kind == "giver" and w.ready then
                        local d = G.dist(w.pos)
                        if d <= cfg.giver_range and (not bd or d < bd) then best, bd = w, d end
                    end
                end
                if best then best.label = q.name push(best, "giver") end
            end
        end
    end
    if cfg.tokens_on_radar then
        for _, t in ipairs(T.list) do
            if t.state >= 1 and t.state <= 4 then push({ pos = t.pos, label = "Seeker's Token", kind = "token" }, "token") end
        end
    end
    H.chest_seen = H.chest_seen or {}
    for _, c in ipairs(T.chests or {}) do
        local d = G.dist(c.pos)
        if cfg.notable_chests and c.notable and d <= 80 then
            -- minimap only: no notice, compass pip or world marker
            push({ pos = c.pos, label = c.label, kind = "chest" }, "chest")
        elseif cfg.chests_on_radar then
            push({ pos = c.pos, label = c.label, kind = "chest" }, "chest_plain")
        end
    end
    table.sort(wps, function(a, b) return a.dist > b.dist end) -- far first, so near pips draw on top
    H.wps = wps
    -- the single waypoint the tracker and compass call out
    local main, md
    -- an errand for missing items (storage or a shop) leads; otherwise the nearest goal
    for _, w in ipairs(wps) do
        if w.role == "focus" and w.priority and (not md or w.dist < md) then main, md = w, w.dist end
    end
    if not main then
        for _, w in ipairs(wps) do
            if w.role == "focus" and (not md or w.dist < md) then main, md = w, w.dist end
        end
    end
    H.main = main
end

---------------------------------------------------------------------------------------------------
-- compass
---------------------------------------------------------------------------------------------------
local CARD = { [0] = "N", [45] = "NE", [90] = "E", [135] = "SE", [180] = "S", [225] = "SW", [270] = "W", [315] = "NW" }

local function draw_compass(d, cfg, L, a)
    local s = L.s
    local cx, y = L.w / 2, (cfg.compass_y or 30) * s
    local half = 330 * s
    local h = 30 * s
    local yaw = math.deg(G.yaw)
    -- backing: fades out toward both ends
    local dark, clear = A(C.bg, a * 0.80), A(C.bg, 0)
    d:add_rect_filled_multi_color(V(cx - half, y), V(cx, y + h), clear, dark, dark, clear)
    d:add_rect_filled_multi_color(V(cx, y), V(cx + half, y + h), dark, clear, clear, dark)
    d:add_line(V(cx - half * 0.86, y + h), V(cx + half * 0.86, y + h), A(C.line, a), 1.0)
    for deg = 0, 345, 15 do
        local rel = wrap_deg(deg - yaw)
        if math.abs(rel) <= 88 then
            local x = cx + rel / 90 * half
            local edge = 1 - (math.abs(rel) / 90) ^ 3
            local name = CARD[deg]
            if name and #name == 1 then
                F.text_centered(d, F.title, 21 * s, x, y + 2 * s, A(name == "N" and C.white or C.gold_hi, a * edge), name, true)
            elseif name then
                F.text_centered(d, F.bold, 13.5 * s, x, y + 8 * s, A(C.text, a * edge), name, true)
            else
                d:add_line(V(x, y + h - 8 * s), V(x, y + h - 1), A(C.text_dim, a * edge), 1.5)
            end
        end
    end
    -- centre notch
    d:add_triangle_filled(V(cx - 6 * s, y - 5 * s), V(cx + 6 * s, y - 5 * s), V(cx, y + 3 * s), A(C.gold, a))

    -- waypoint pips ride along the bottom edge
    local py = y + h
    for _, w in ipairs(H.wps) do
        if w.dist > 2.5 and w.role ~= "giver" and w.role ~= "chest_plain" and w.role ~= "chest" then -- pick-ups stay on the radar; the compass is for where you are going
            local rel = wrap_deg(math.deg(w.brg) - yaw)
            local clamped = U.clamp(rel, -86, 86)
            local x = cx + clamped / 90 * half
            local off = (clamped ~= rel)
            local is_main = (w == H.main)
            local r = (is_main and 8.5 or ((w.role == "giver") and 4 or 6)) * s
            local pa = a * (off and 0.55 or 1) * ((w.role == "giver") and 0.8 or 1) * fade(w.dist, is_main)
            icon(d, w.kind, x, py, r, pa, is_main)
            if off then
                local dirx = (rel > 0) and 1 or -1
                local ex = x + dirx * (r + 5 * s)
                d:add_triangle_filled(V(ex, py - 4 * s), V(ex, py + 4 * s), V(ex + dirx * 6 * s, py), A(KIND_COL[w.kind] or C.text, pa))
            end
        end
    end
    -- call-out for the main waypoint
    local m = H.main
    if m and m.dist > 2.5 then
        local rel = wrap_deg(math.deg(m.brg) - yaw)
        local x = cx + U.clamp(rel, -86, 86) / 90 * half
        local txt = U.fmt_dist(m.dist)
        if m.dy > 6 then txt = txt .. "  up" elseif m.dy < -6 then txt = txt .. "  down" end
        local label = F.fit(F.bold, 15 * s, m.label or "", 240 * s) .. "   " .. txt
        local wdt = F.width(F.bold, 15 * s, label)
        local lx = U.clamp(x, cx - half + wdt / 2, cx + half - wdt / 2)
        F.text_centered(d, F.bold, 15 * s, lx, py + 12 * s, A(C.gold_hi, a), label, true)
    end
end

---------------------------------------------------------------------------------------------------
-- tracker card
---------------------------------------------------------------------------------------------------
local function timer_line(q)
    local t = q.timer
    if not t then return nil end
    local span = U.fmt_hours(t.left) .. "  (" .. U.fmt_real(t.left) .. ")"
    if t.kind == "deadline" then return "Time left: " .. span, (t.left <= 6) and C.red or C.amber end
    if t.kind == "wait" then return "Ready in about " .. span, C.ice end
    if t.kind == "expires" then return "May run out in " .. span, (t.left <= 6) and C.red or C.amber end
    return "Something changes in " .. span, C.amber
end
H.timer_line = timer_line

local function in_window(w)
    local hr = G.hour or 0
    if w.sh <= w.eh then return hr >= w.sh and hr <= w.eh end
    return hr >= w.sh or hr <= w.eh
end
H.in_window = in_window

local function tracker_lines(cfg, L)
    local s, q = L.s, H.focus
    local W = 300 * s
    local lines = {}
    -- every line wraps to the card's width, so nothing runs off the edge of the screen
    local function add(font, size, col, text, gap, mark, maxl)
        if mark == "sep" or not text or text == "" then
            lines[#lines + 1] = { font = font, size = size * s, col = col, text = text or "", gap = (gap or 3) * s, mark = mark }
            return
        end
        local avail = W - ((mark and mark ~= "sep") and 20 * s or 0)
        local parts = F.wrap(font, size * s, text, avail, maxl or 3)
        for i, ln in ipairs(parts) do
            lines[#lines + 1] = { font = font, size = size * s, col = col, text = ln, gap = ((i == #parts) and (gap or 3) or 1) * s,
                mark = (i == 1) and mark or nil, indent = (i > 1 and mark) and 20 * s or nil }
        end
    end
    if q then
        add(F.body, 12.5, C.text_faint, string.upper(H.focus_src or "Tracking"), 1)
        for _, ln in ipairs(F.wrap(F.title, 18 * s, string.upper(q.name), W, 2)) do add(F.title, 18, C.gold, ln, 2) end
        local task = q.task
        if not task and q.cat == CAT.AVAILABLE then
            task = H.main and ("Not started. Find " .. (H.main.label or "them") .. " to begin.") or "Not started yet."
        end
        add(F.body, 16.5, C.text, task, 1, nil, 5)
        if q.cat == CAT.PROGRESS and q.task_detail and q.task_detail ~= q.task then add(F.body, 14.5, C.text_dim, q.task_detail, 3, nil, 8) end
        if q.cat == CAT.PROGRESS and q.leads and #q.leads > 0 then
            local parts = {}
            for _, l in ipairs(q.leads) do if not l.pos then parts[#parts + 1] = l.label end end
            if #parts > 0 then add(F.bold, 14.5, C.gold, "Leads (location unknown): " .. table.concat(parts, ",  "), 3) end
        end
        local fg = M.forgery
        if fg and (q.id == 20350 or q.id == 30160 or q.id == 30150) then
            add(F.bold, 14.5, fg.done and C.green or C.ice, fg.done and ("Forgery of " .. fg.item .. " is ready at Ibrahim's.")
                or ("Forgery of " .. fg.item .. " ready in " .. U.fmt_hours(fg.left) .. " (" .. U.fmt_real(fg.left) .. ")"), 3)
        end
        local gd = cfg.guide and cfg.guide_in_tracker and M.guide[q.id]
        if gd and (q.cat == CAT.PROGRESS or q.cat == CAT.AVAILABLE) then
            if gd.decision and gd.best ~= "" then add(F.bold, 14.5, C.amber, "Choice ahead: " .. gd.best, 3, nil, 6)
            elseif gd.warnings[1] then add(F.body, 14.5, C.amber, "Heads up: " .. gd.warnings[1], 3, nil, 6) end
        end
        local m = H.main
        -- every person and place for this quest, nearest first, stacked; the one the compass follows is bright
        local all = {}
        for _, w in ipairs(M.waypoints(q) or {}) do if w.pos then all[#all + 1] = w end end
        table.sort(all, function(a, b) return G.dist(a.pos) < G.dist(b.pos) end)
        local shown = 0
        for _, w in ipairs(all) do
            if shown >= 8 then add(F.body, 13.5, C.text_faint, "+" .. (#all - shown) .. " more in the ledger (F8)", 2) break end
            local dist, dy = G.dist(w.pos), w.pos.y - G.upos.y
            local is_main = m and m.pos and math.abs(m.pos.x - w.pos.x) < 0.5 and math.abs(m.pos.z - w.pos.z) < 0.5
            local txt = F.fit(F.bold, 15.5 * s, w.label or "?", W * 0.55) .. "   " .. U.fmt_dist(dist) .. " " .. U.dir_name(U.bearing(G.upos, w.pos))
            if dy > 6 then txt = txt .. ", up " .. math.floor(dy) .. " m" elseif dy < -6 then txt = txt .. ", down " .. math.floor(-dy) .. " m" end
            add(is_main and F.bold or F.body, is_main and 16 or 15, is_main and C.gold_hi or C.text, txt, 2, w.kind)
            shown = shown + 1
        end
        if shown > 0 then
        elseif q.cat == CAT.AVAILABLE then
            add(F.body, 15, C.text_dim, "No one to talk to. How it starts, in the game's words:", 2)
            add(F.body, 14.5, C.text, q.summary or "Unknown.", 3)
        end
        if m and q.cat == CAT.AVAILABLE and m.ready == false then
            add(F.body, 15, C.amber, "Not offering this yet. Try another time of day, or it may need more story first.", 2)
        end
        local tl, tc = timer_line(q)
        if tl then add(F.bold, 15.5, tc, tl, 3) end
        if q.cat == CAT.AVAILABLE and q.windows and #q.windows >= 1 and #q.windows <= 2 then
            local parts, open = {}, false
            for _, w in ipairs(q.windows) do parts[#parts + 1] = w.text if in_window(w) then open = true end end
            add(F.body, 15, open and C.green or C.amber, "Starts " .. table.concat(parts, " or ") .. (open and "  (now)" or "  (not now)"), 3)
        end
        local ih = cfg.guide and M.guide[q.id] and M.guide[q.id].item_hints
        for _, it in ipairs(q.items or {}) do
            if it.need then
                local ok = (it.have or 0) >= it.need
                local txt = string.format("%s:  have %d of %d", it.name, it.have or 0, it.need)
                if not ok and it.partial and (it.have or 0) > 0 then txt = txt .. " (can hand in part)" end
                add(F.body, 15, ok and C.green or C.text, txt, 2)
                if not ok then
                    local bits = {}
                    if (it.pawn or 0) > 0 then bits[#bits + 1] = "pawn carries " .. it.pawn end
                    if (it.stored or 0) > 0 then bits[#bits + 1] = it.stored .. " in storage" end
                    if it.route == "shop" and it.shop then bits[#bits + 1] = "sold at " .. it.shop end
                    if #bits > 0 then add(F.bold, 14, C.gold, table.concat(bits, ",  "), 2) end
                end
                local hint = (not ok) and ih and M.item_hint(q.id, it.name)
                if hint then add(F.body, 13.5, C.text_dim, "Where: " .. hint, 3, nil, 6) end
            else
                add(F.body, 15, C.text_dim, string.format("%s:  carrying %d", it.name, it.have or 0), 2)
            end
        end
        if q.dead and #q.dead > 0 then add(F.bold, 15, C.red, "Dead: " .. table.concat(q.dead, ", "), 3) end
        if (q.risk or 0) >= 1 and q.cutoffs and q.cutoffs[1] then
            local top = q.cutoffs[1]
            for _, c in ipairs(q.cutoffs) do if c.level > top.level then top = c end end
            local col = (top.level >= 3) and C.red or C.amber
            for _, ln in ipairs(F.wrap(F.body, 15 * s, "Lost when " .. M.cutoff_text(top) .. " completes (" .. M.RISK_TEXT[top.level] .. ")", W, 2)) do add(F.body, 15, col, ln, 1) end
        end
    end
    -- other pressing things
    local urgent = {}
    for _, tq in ipairs(M.timers) do
        if tq ~= q and tq.timer and tq.timer.kind ~= "wait" and tq.timer.left <= 24 and #urgent < 3 then
            urgent[#urgent + 1] = { text = tq.name, right = U.fmt_hours(tq.timer.left), col = (tq.timer.kind == "deadline") and C.red or C.amber }
        end
    end
    for _, g in ipairs(M.groups) do
        if g.level >= 2 and #urgent < 4 then
            local open = 0
            for _, id in ipairs(g.quests) do local x = M.quests[id] if x.cat == CAT.AVAILABLE or x.cat == CAT.PROGRESS then open = open + 1 end end
            if open > 0 then urgent[#urgent + 1] = { text = open .. " quest(s) end with " .. (M.name(g.driver) or "?"), right = "", col = (g.level >= 3) and C.red or C.amber } end
        end
    end
    if #urgent > 0 then
        add(F.body, 12.5, C.text_faint, "ALSO PRESSING", 2, "sep")
        for _, u in ipairs(urgent) do
            lines[#lines + 1] = { font = F.body, size = 15 * s, col = u.col, text = F.fit(F.body, 15 * s, u.text, W - 80 * s), right = u.right, gap = 2 * s }
        end
    end
    return lines, W
end

local function draw_tracker(d, cfg, L, a)
    local lines, W = tracker_lines(cfg, L)
    if #lines == 0 then return end
    local s = L.s
    local pad = 14 * s
    local total = pad * 2
    for _, ln in ipairs(lines) do total = total + ln.size + ln.gap + ((ln.mark == "sep") and 10 * s or 0) end
    -- top-right corner of the real screen; on ultrawide that is outside the game's own HUD area
    local x1 = L.w - (cfg.tracker_x or 22) * s
    local x0 = x1 - W - pad * 2
    if cfg.tracker_left then x0 = (cfg.tracker_x or 22) * s x1 = x0 + W + pad * 2 end
    local y0 = (cfg.tracker_y or 96) * s
    d:add_rect_filled(V(x0, y0), V(x1, y0 + total), A(C.bg, a * 0.5), 6 * s)
    d:add_rect_filled(V(x0, y0), V(x0 + 3 * s, y0 + total), A(C.gold, a), 2 * s)
    local y = y0 + pad
    for _, ln in ipairs(lines) do
        local x = x0 + pad
        if ln.mark == "sep" then
            d:add_line(V(x, y + 3 * s), V(x1 - pad, y + 3 * s), A(C.line_soft, a), 1.0)
            y = y + 10 * s
        elseif ln.mark then
            icon(d, ln.mark, x + 7 * s, y + ln.size * 0.55, 6 * s, a, true)
            x = x + 20 * s
        elseif ln.indent then
            x = x + ln.indent
        end
        F.text(d, ln.font, ln.size, x, y, A(ln.col, a), ln.text, true)
        if ln.right and ln.right ~= "" then
            local rw = F.width(F.bold, ln.size, ln.right)
            F.text(d, F.bold, ln.size, x1 - pad - rw, y, A(ln.col, a), ln.right, true)
        end
        y = y + ln.size + ln.gap
    end
end

---------------------------------------------------------------------------------------------------
-- radar
---------------------------------------------------------------------------------------------------
-- geometry of the game's own minimap, in 1080p units from the 16:9 area's left edge
H.MM = { x = 252, y = 848, r = 112, k = 2.66, unit = 1.004, heading_up = true } -- measured against the game's own minimap icons
-- unit: 1080p pixels per minimap panel unit (k 2.66 was measured while the game's map scale was 2.65)

local function draw_radar(d, cfg, L, a)
    local s = L.s
    local overlay = cfg.radar_overlay
    local R = (cfg.radar_size or 96) * s
    local cx, cy = L.left + (cfg.radar_x or 274) * s, (cfg.radar_y or 600) * s
    local range = H.RANGES[cfg.radar_range or 2] or 150
    local yaw = G.yaw
    if overlay then
        -- sit exactly on the game's minimap and use its scale, so pips line up with its streets
        local mm = H.MM
        R = mm.r * s
        cx, cy = L.left + mm.x * s, mm.y * s
        range = mm.r / mm.k
        if not mm.heading_up then yaw = 0 end
    else
        d:add_circle_filled(V(cx, cy), R, A(C.bg, a * 0.55), 64)
        d:add_circle(V(cx, cy), R, A(C.gold, a * 0.8), 64, 1.5 * s)
        d:add_circle(V(cx, cy), R * 0.5, A(C.line_soft, a), 48, 1.0)
    end
    local cy_, sy_ = math.cos(yaw), math.sin(yaw)
    local gm = overlay and G.mm
    local unit = gm and (H.MM.unit or 1) * s
    -- world offset (east, north in metres) -> pixel offset from the radar centre
    local function project(east, north)
        if gm then return (east * gm.ex + north * gm.nx) * unit, (east * gm.ey + north * gm.ny) * unit end
        local k = R / range
        return (east * cy_ - north * sy_) * k, -(east * sy_ + north * cy_) * k
    end
    if cfg.enemies_on_radar then
        for _, e in ipairs(T.enemies or {}) do
            local east, north = e.pos.x - G.upos.x, -(e.pos.z - G.upos.z)
            local px, py = project(east, north)
            if px * px + py * py <= (R - 4 * s) * (R - 4 * s) then
                local r = (e.big and 5.5 or 3.5) * s
                d:add_circle_filled(V(cx + px, cy + py), r + 1.5 * s, A(C.black, a * 0.85), 12)
                d:add_circle_filled(V(cx + px, cy + py), r, A(C.red, a), 12)
            end
        end
    end
    -- north marker on the rim
    if not overlay then
        local nx, ny = cx - sy_ * R, cy - cy_ * R
        d:add_circle_filled(V(nx, ny), 9 * s, A(C.bg, a), 16)
        F.text_centered(d, F.title, 13 * s, nx, ny - 8 * s, A(C.gold_hi, a), "N", false)
    end
    for _, w in ipairs(H.wps) do
        local east, north = w.pos.x - G.upos.x, -(w.pos.z - G.upos.z)
        local px, py = project(east, north)
        local len = math.sqrt(px * px + py * py)
        local is_main = (w == H.main)
        if len > R - 7 * s and overlay then
            -- on the game's minimap, anything out of range is simply not drawn
        elseif len > R - 7 * s then
            -- beyond range: a tick on the rim pointing outward
            local ux, uy = px / len, py / len
            local bx, by = cx + ux * (R - 12 * s), cy + uy * (R - 12 * s)
            local tx, ty = -uy, ux
            local col = A(KIND_COL[w.kind] or C.text, a * ((w.role == "giver") and 0.8 or 1))
            local sz = (is_main and 13 or ((w.role == "giver") and 8 or 10.5)) * s
            local function tri(k, c)
                -- a slim dart: long toward the target, narrow across, so its direction is unmistakable
                d:add_triangle_filled(V(bx + ux * sz * 1.25 * k, by + uy * sz * 1.25 * k), V(bx - ux * sz * 0.75 * k + tx * sz * 0.5 * k, by - uy * sz * 0.75 * k + ty * sz * 0.5 * k),
                    V(bx - ux * sz * 0.75 * k - tx * sz * 0.5 * k, by - uy * sz * 0.75 * k - ty * sz * 0.5 * k), c)
            end
            tri(1.3, A(C.black, a * 0.9))
            tri(1.0, col)
        else
            local r = is_main and 8.5 or ((w.role == "giver" or w.role == "chest_plain") and 5 or 6.5)
            icon(d, w.kind, cx + px, cy + py, r * s, a * ((w.role == "giver") and 0.85 or 1), is_main)
            if math.abs(w.dy) > 8 then
                local up = w.dy > 0
                local ax, ay = cx + px + 9 * s, cy + py
                local dir = up and -1 or 1
                d:add_triangle_filled(V(ax - 3.5 * s, ay - dir * 2.5 * s), V(ax + 3.5 * s, ay - dir * 2.5 * s), V(ax, ay + dir * 3.5 * s), A(C.text, a))
            end
        end
    end
    if overlay then return end
    -- the Arisen: fixed at the centre, facing up (the radar turns with the camera)
    d:add_triangle_filled(V(cx, cy - 7 * s), V(cx + 5 * s, cy + 5 * s), V(cx - 5 * s, cy + 5 * s), A(C.white, a))
    local label = (range >= 1000) and string.format("%.1f km", range / 1000) or (range .. " m")
    F.text_centered(d, F.body, 12.5 * s, cx, cy + R + 4 * s, A(C.text_dim, a), label, true)
end

---------------------------------------------------------------------------------------------------
-- world markers
---------------------------------------------------------------------------------------------------
local function draw_markers(d, cfg, L, a)
    local s = L.s
    local shown = 0
    for i = #H.wps, 1, -1 do -- nearest first
        local w = H.wps[i]
        local is_chest = false
        if (w.role == "focus" or w.role == "pinned" or is_chest) and (w.dist > 3 or is_chest) and shown < 5 then
            local sx, sy = G.screen(w.pos, is_chest and 1.0 or ((w.kind == "objective") and 1.2 or 2.1))
            if sx and sx > 0 and sx < L.w and sy > 0 and sy < L.h then
                shown = shown + 1
                local near = U.clamp(1.25 - w.dist / 400, 0.75, 1.15)
                local r = 9 * s * near
                local fa = a * ((w.role == "focus") and 1 or 0.8) * fade(w.dist, w == H.main)
                icon(d, w.kind, sx, sy, r, fa, w == H.main)
                local label = (w.label or "") .. "  " .. U.fmt_dist(w.dist)
                F.text_centered(d, F.bold, 15 * s * near, sx, sy + r + 4 * s, A(C.gold_hi, fa), label, true)
            end
        end
    end
end

---------------------------------------------------------------------------------------------------
-- notices
---------------------------------------------------------------------------------------------------
function H.notify(kind, text, sub)
    H.toasts[#H.toasts + 1] = { kind = kind, text = text, sub = sub, born = os.clock() }
end

local function draw_toasts(d, cfg, L, a, now)
    -- pull new model events
    while H.event_idx < #M.events do
        H.event_idx = H.event_idx + 1
        local e = M.events[H.event_idx]
        if cfg["toast_" .. e.kind] ~= false then H.toasts[#H.toasts + 1] = { kind = e.kind, text = e.text, sub = e.sub, born = now } end
    end
    if H.event_idx > #M.events then H.event_idx = #M.events end
    local s = L.s
    local y = (cfg.toast_y or 112) * s
    local shown = 0
    local i = 1
    while i <= #H.toasts do
        local t = H.toasts[i]
        local life = (t.kind == "risk" or t.kind == "timer" or t.kind == "dead") and 11 or 7
        if shown >= 4 then
            t.born = now -- waits its turn
            i = i + 1
        else
            local age = now - t.born
            if age > life then
                table.remove(H.toasts, i)
            else
                local fa = a * U.clamp(age / 0.25, 0, 1) * U.clamp((life - age) / 0.6, 0, 1)
                local title_w = F.width(F.bold, 17 * s, t.text)
                local sub = t.sub and F.fit(F.body, 15 * s, t.sub, 520 * s) or nil
                local sub_w = sub and F.width(F.body, 15 * s, sub) or 0
                local w = math.max(title_w, sub_w) + 44 * s
                local h = (sub and 54 or 34) * s
                local x0 = L.w / 2 - w / 2
                local col = TOAST_COL[t.kind] or C.text
                d:add_rect_filled(V(x0, y), V(x0 + w, y + h), A(C.bg, fa * 0.82), 5 * s)
                d:add_rect_filled(V(x0, y), V(x0 + 4 * s, y + h), A(col, fa), 2 * s)
                F.text(d, F.bold, 17 * s, x0 + 18 * s, y + 7 * s, A(col, fa), t.text, false)
                if sub then F.text(d, F.body, 15 * s, x0 + 18 * s, y + 29 * s, A(C.text, fa), sub, false) end
                y = y + h + 6 * s
                shown = shown + 1
                i = i + 1
            end
        end
    end
end

-- a small 24-hour clock tucked under the game's minimap
local function draw_clock(d, L, a)
    local s = L.s
    local mm = H.MM
    local cx, y = L.left + mm.x * s, (mm.y + mm.r + 30) * s
    local txt = U.fmt_clock(G.hour, G.minute)
    local fs = 17 * s
    local w = F.width(F.bold, fs, txt) + 18 * s
    local hgt = fs + 8 * s
    d:add_rect_filled(V(cx - w / 2, y), V(cx + w / 2, y + hgt), A(C.bg, a * 0.6), hgt / 2)
    F.text_centered(d, F.bold, fs, cx, y + 3 * s, A(C.text, a), txt, false)
    local f = M.forgery
    if f then
        local ft = f.done and ("Forgery ready: " .. f.item) or ("Forgery: " .. U.fmt_hours(f.left) .. "  (~" .. U.fmt_real(f.left) .. ")")
        F.text_centered(d, F.body, 14 * s, cx, y + hgt + 4 * s, A(f.done and C.green or C.ice, a), ft, true)
    end
end

---------------------------------------------------------------------------------------------------
function H.draw(now, cfg)
    if not (G.ok and M.ready) then return end
    local size = imgui.get_display_size()
    local s = (size.y / 1080) * (cfg.hud_scale or 1.0)
    local safe_w = math.min(size.x, size.y * 16 / 9)
    local L = { w = size.x, h = size.y, s = s, left = (size.x - safe_w) / 2, right = size.x - (size.x - safe_w) / 2 }
    local a = (G.hud_alpha or 1) * (cfg.hud_opacity or 1.0)
    local d = imgui.get_background_draw_list()
    H.fade_on = cfg.fade_distant ~= false
    build(now, cfg)
    local quiet = cfg.hide_in_battle and G.in_battle
    if not quiet then
        if cfg.markers then draw_markers(d, cfg, L, a) end
        if cfg.compass then draw_compass(d, cfg, L, a) end
        if cfg.radar then draw_radar(d, cfg, L, a) end
        if cfg.tracker then draw_tracker(d, cfg, L, a) end
        if cfg.token_arrow then T.draw(now, { x = L.left + (cfg.token_x or 468) * s, y = (cfg.token_y or 792) * s, scale = s, alpha = a }) end
    end
    if cfg.clock then draw_clock(d, L, a) end
    if cfg.toasts then draw_toasts(d, cfg, L, a, now) end
end

return H
