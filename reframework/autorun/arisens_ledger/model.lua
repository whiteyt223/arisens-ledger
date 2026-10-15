-- Arisen's Ledger: quest model. Everything here is read from the game's own quest data; nothing is written back.
local U = require("arisens_ledger/util")
local G = require("arisens_ledger/game")
local try = U.try
local S = G.S

local M = {
    ready = false, quests = {}, order = {}, hidden = {}, result = {}, counts = {}, events = {},
    driver = { [11030] = 10140, [11040] = 10180, [11050] = 10200 }, driver_confirmed = {},
    groups = {}, timers = {}, tracked = -1, baseline = false, scan_cycle = 0, init_error = nil, avail = {},
}

-- categories
-- walkthrough notes per quest (choices, outcomes, warnings), researched from community guides
M.guide = {}
do
    local g = json.load_file("arisens_guide.json")
    if type(g) == "table" then for _, e in ipairs(g) do if type(e) == "table" and e.id then M.guide[e.id] = e end end end
end
-- where to get a quest item: exact name first, then ignoring case and punctuation
function M.item_hint(qid, name)
    local g = M.guide[qid]
    local ih = g and g.item_hints
    if not (ih and name) then return nil end
    if ih[name] then return ih[name] end
    local function norm(s) return (s:lower():gsub("[^%w]", "")) end
    local n = norm(name)
    for k, v in pairs(ih) do if norm(k) == n then return v end end
    return nil
end

M.CAT = { AVAILABLE = 1, PROGRESS = 2, LOCKED = 3, DONE = 4, FAILED = 5, MISSED = 6 }
M.CAT_NAME = { "Available", "In progress", "Locked", "Completed", "Failed", "Missed" }
local CAT = M.CAT

local PLAYER_ID, PAWN_ID = 1857826560, 2891076981
local qdef = sdk.find_type_definition("app.QuestDefine")
local m_is_main = qdef and try(function() return qdef:get_method("isMainQuestID(app.QuestDefine.ID)") end)
local m_is_dlc = qdef and try(function() return qdef:get_method("isContents0014QuestID(app.QuestDefine.ID)") end)
local m_item_name = try(function() return sdk.find_type_definition("app.ItemCommonParam"):get_method("get_item_name(System.Int32)") end)

local function push_event(kind, text, sub, quest)
    if not M.baseline then return end
    M.events[#M.events + 1] = { kind = kind, text = text, sub = sub, quest = quest, t = os.clock() }
    while #M.events > 40 do table.remove(M.events, 1) end
end

---------------------------------------------------------------------------------------------------
-- static data: titles, tree (prerequisites, cut-offs, unlocks)
---------------------------------------------------------------------------------------------------
local function read_catalog(ql, field, titles, summaries)
    local cat = try(function() return ql:get_field(field) end)
    local dict = cat and try(function() return cat:get_field("<MergedCatalog>k__BackingField") end)
    local n = 0
    U.dict(dict, function(_, v)
        local res = v
        if v and U.tname(v) ~= "app.QuestLogResource" then
            res = nil
            local td = try(function() return v:get_type_definition() end)
            for _, f in ipairs(td and try(function() return td:get_fields() end) or {}) do
                local fv = try(function() return v:get_field(f:get_name()) end)
                if type(fv) == "userdata" and U.tname(fv) == "app.QuestLogResource" then res = fv end
            end
        end
        if res then
            local id = try(function() return res:call("get_QuestId") end)
            local title = U.msg(try(function() return res:call("get_Title") end))
            if type(id) == "number" and title then
                titles[id] = U.clean(title)
                summaries[id] = U.clean(U.msg(try(function() return res:call("get_Summary") end)))
                n = n + 1
            end
        end
    end)
    return n
end

local function read_element(e, out)
    local op = try(function() return e:get_field("_Operator") end) or 0
    local grp = { any = (op == 1), items = {} }
    for _, p in ipairs(U.array(try(function() return e:get_field("_ParamArray") end))) do
        local q, r = try(function() return p:get_field("_QuestID") end), try(function() return p:get_field("_ResultNo") end)
        if type(q) == "number" then grp.items[#grp.items + 1] = { q = q, r = r or 0 } end
    end
    if #grp.items > 0 then out[#out + 1] = grp end
    for _, sub in ipairs(U.array(try(function() return e:get_field("_ElementArray") end))) do read_element(sub, out) end
end

local function read_tree(tree)
    if not tree then return 0 end
    local n = 0
    U.dict(try(function() return tree:get_field("AllNodeDict") end), function(id, node)
        local q = M.quests[id] or M.hidden[id]
        if not q then q = { id = id, hidden = true } M.hidden[id] = q end
        q.in_tree = true
        q.prev, q.endc = {}, {}
        for _, t in ipairs(U.list(try(function() return node:get_field("PrevTransitionList") end))) do
            local data = try(function() return t:get_field("<Data>k__BackingField") end)
            for _, e in ipairs(U.array(data and try(function() return data:get_field("_ElementArray") end))) do read_element(e, q.prev) end
        end
        local ec = try(function() return node:get_field("_EndCondition") end)
        local prm = ec and try(function() return ec:get_field("_Param") end)
        if prm then
            q.end_any = (try(function() return prm:get_field("_Operator") end) == 1)
            for _, c in ipairs(U.array(try(function() return prm:get_field("_ConditionArray") end))) do
                local cq, cr = try(function() return c:get_field("_QuestID") end), try(function() return c:get_field("_ResultNo") end)
                if type(cq) == "number" then q.endc[#q.endc + 1] = { q = cq, r = cr or 0 } end
            end
        end
        n = n + 1
    end)
    U.dict(try(function() return tree:get_field("AllRelationNodeDict") end), function(id, lst)
        local q = M.quests[id] or M.hidden[id]
        if q then
            q.unlocks = U.list(lst, function(node) return try(function() return node:get_field("<QuestID>k__BackingField") end) end)
        end
    end)
    return n
end

local function init_static()
    local qm, ql = S("app.QuestManager"), S("app.QuestLogManager")
    if not (qm and ql) then M.init_error = "waiting for a loaded save" return false end
    local titles, summaries = {}, {}
    local n = read_catalog(ql, "_Catalog", titles, summaries) + read_catalog(ql, "_Contents0014Catalog", titles, summaries)
    if n < 10 then M.init_error = "quest catalogue not loaded yet" return false end
    M.quests, M.hidden, M.order = {}, {}, {}
    local by_val = U.enum("app.QuestDefine.ID")
    for id, _ in pairs(by_val) do
        if id >= 0 then
            if titles[id] then
                local q = { id = id, name = titles[id], summary = summaries[id], st = 0, cat = CAT.LOCKED, clears = 0, level = 0, risk = 0, cutoffs = {} }
                q.main = m_is_main and try(function() return m_is_main:call(nil, id) end) == true
                q.dlc = (m_is_dlc and try(function() return m_is_dlc:call(nil, id) end) == true) or (id >= 40000 and id < 60000)
                q.dlc_opener = (id == 40010) -- Chilling Tidings: "travel to Norgan", the start of Dark Arisen
                M.quests[id] = q
                M.order[#M.order + 1] = id
            else
                M.hidden[id] = { id = id, hidden = true }
            end
        end
    end
    table.sort(M.order)
    local tn = read_tree(try(function() return qm:get_field("Tree") end))
    tn = tn + read_tree(try(function() return qm:get_field("Contents0014Tree") end))
    if tn < 10 then M.init_error = "quest tree not ready yet" return false end
    -- reverse relation: which quests gate this one
    for _, id in ipairs(M.order) do
        local q = M.quests[id]
        q.prev, q.endc, q.unlocks = q.prev or {}, q.endc or {}, q.unlocks or {}
    end
    M.status_names = U.enum("app.QuestLogManager.QuestStatus")
    M.init_error = nil
    return true
end

function M.name(id)
    local q = M.quests[id]
    if q then return q.name end
    return nil
end

---------------------------------------------------------------------------------------------------
-- cut-off logic
---------------------------------------------------------------------------------------------------
-- the quest whose completion actually fires a cut-off (hidden story markers map to a main quest)
function M.driver_of(cut_id)
    if M.quests[cut_id] then return cut_id end
    return M.driver[cut_id]
end

local function cond_met(c) return M.result[c.q] ~= nil and M.result[c.q] == c.r end

local function end_condition_met(q)
    if not q.endc or #q.endc == 0 then return false end
    if q.end_any then
        for _, c in ipairs(q.endc) do if cond_met(c) then return true end end
        return false
    end
    for _, c in ipairs(q.endc) do if not cond_met(c) then return false end end
    return true
end

local function prereqs_met(q)
    if not q.prev or #q.prev == 0 then return true end
    for _, grp in ipairs(q.prev) do
        local ok = not grp.any
        for _, it in ipairs(grp.items) do
            local met = cond_met(it)
            if grp.any and met then ok = true break end
            if (not grp.any) and (not met) then ok = false break end
        end
        if not ok then return false end
    end
    return true
end

-- 0 far off, 1 next story step, 2 the triggering quest is available, 3 it is in progress right now
local function driver_level(did)
    local d = M.quests[did]
    if not d then return 0 end
    if d.cat == CAT.PROGRESS then return 3 end
    if d.cat == CAT.AVAILABLE then return 2 end
    if d.cat == CAT.LOCKED then
        -- "next up" when every prerequisite is done or under way
        local all = true
        local any_item = false
        for _, grp in ipairs(d.prev or {}) do
            for _, it in ipairs(grp.items) do
                any_item = true
                local p = M.quests[it.q]
                local ok = cond_met(it) or (p and (p.cat == CAT.PROGRESS or p.cat == CAT.AVAILABLE))
                if grp.any and ok then all = true break end
                if not ok then all = false end
            end
        end
        if any_item and all then return 1 end
    end
    return 0
end

local RISK_TEXT = { [0] = "later in the story", "next story step", "can be triggered now", "in progress now" }
M.RISK_TEXT = RISK_TEXT

---------------------------------------------------------------------------------------------------
-- fast refresh: status of every quest
---------------------------------------------------------------------------------------------------
local function npc_info(nm, cid)
    if cid == PLAYER_ID or cid == PAWN_ID then return nil end
    local cd = try(function() return nm:call("getNPCData", cid) end)
    local name = cd and try(function() return cd:call("get_Name") end)
    if type(name) == "userdata" then name = U.str(name) end
    if type(name) ~= "string" or #name == 0 then return nil end
    return { cid = cid, name = name }
end

local function npc_update(nm, n)
    n.dead = try(function() return nm:call("NPCisDead", n.cid) end) == true
    -- the game's own test for "this person has a quest conversation you can start right now"
    local tem = S("app.TalkEventManager")
    n.ready = (not n.dead) and tem ~= nil and try(function() return tem:call("isQuestTalkEventInteractableCharacter", n.cid) end) == true
    local h = try(function() return nm:call("getNPCHolder", n.cid) end)
    local p = h and U.pos(try(function() return h:call("get_UniversalPosition") end))
    if U.is_zero(p) then p = U.pos(try(function() return nm:call("getCurrentScheduleDistination(app.CharacterID)", n.cid) end)) end
    if not U.is_zero(p) then n.pos = p end
    n.loaded = h and try(function() return h:call("isFlagEntity") end) == true
end

local function read_task(ql, q)
    local task = try(function() return ql:call("getCurrentTask", q.id) end)
    q.task, q.timed, q.dests = nil, false, {}
    if not task then return end
    q.task = U.clean(U.msg(try(function() return task:get_field("_BaseMsg") end)))
    q.task_detail = U.clean(U.msg(try(function() return task:get_field("_DetailMsg") end)))
    q.timed = try(function() return task:get_field("_IsTimed") end) == true
    for _, d in ipairs(U.array(try(function() return task:get_field("_Destinations") end))) do
        local show = try(function() return d:call("evaluateShow") end)
        local p = U.pos(try(function() return d:call("getDestination") end))
        -- the game hands these back with the world-origin offset applied a second time
        if p and not U.is_zero(p) and G.off then p = { x = p.x - G.off.x, y = p.y - G.off.y, z = p.z - G.off.z } end
        if show ~= false and not U.is_zero(p) then
            q.dests[#q.dests + 1] = { pos = p, label = U.clean(U.msg(try(function() return d:get_field("_MsgId") end))) or "Objective" }
        end
    end
end

local function status_pass(q, qm, ql)
    local id = q.id
    local info = try(function() return ql:call("getQuestLog", id) end)
    local st = info and try(function() return info:get_field("<Status>k__BackingField") end) or 0
    local old_cat = q.cat
    q.st, q.active, q.acceptable = st, M.active[id] == true, M.avail[id] == true
    q.clears = try(function() return qm:call("getClearRecordCount", id) end) or 0
    if q.level == 0 then q.level = try(function() return qm:call("getQuestRecommendedLevel", id) end) or 0 end
    if st == 1 then
        q.cat = CAT.PROGRESS
        read_task(ql, q)
    elseif st == 2 then q.cat = CAT.DONE q.task = nil q.dests = nil
    elseif st == 3 then q.cat = CAT.FAILED
    elseif q.acceptable then q.cat = CAT.AVAILABLE
    elseif (not q.active) and end_condition_met(q) then q.cat = CAT.MISSED
    else q.cat = CAT.LOCKED end
    if q.cat ~= CAT.PROGRESS then q.timed = false end
    q.unlocked = prereqs_met(q)
    if M.baseline and old_cat ~= q.cat then
        if q.cat == CAT.AVAILABLE then push_event("new", "New quest available", q.name, id)
        elseif q.cat == CAT.PROGRESS then push_event("start", "Quest started", q.name, id)
        elseif q.cat == CAT.DONE then push_event("done", "Quest completed", q.name, id)
        elseif q.cat == CAT.FAILED then push_event("fail", "Quest failed", q.name, id)
        elseif q.cat == CAT.MISSED then push_event("fail", "Quest no longer available", q.name, id) end
    end
end

local function finalize()
    local c = { avail = 0, prog = 0, done = 0, locked = 0, failed = 0, missed = 0, total = 0, timed = 0, fresh = 0, risk = 0, dlc_total = 0, dlc_done = 0 }
    local groups = {}
    for _, id in ipairs(M.order) do
        local q = M.quests[id]
        local old_risk = q.risk or 0
        q.risk, q.cutoffs = 0, {}
        local open = (q.cat == CAT.AVAILABLE or q.cat == CAT.PROGRESS or q.cat == CAT.LOCKED)
        if open and q.endc then
            for _, cnd in ipairs(q.endc) do
                local did = M.driver_of(cnd.q)
                local lvl = did and driver_level(did) or 0
                q.cutoffs[#q.cutoffs + 1] = { cut = cnd.q, driver = did, level = lvl, r = cnd.r, guess = (M.quests[cnd.q] == nil and not M.driver_confirmed[cnd.q]) }
                if q.cat ~= CAT.LOCKED and lvl > q.risk then q.risk = lvl end
                if did and (q.cat ~= CAT.LOCKED or q.unlocked) then
                    groups[did] = groups[did] or { driver = did, level = lvl, quests = {} }
                    local g = groups[did]
                    local dup = false
                    for _, x in ipairs(g.quests) do if x == id then dup = true end end
                    if not dup then g.quests[#g.quests + 1] = id end
                end
            end
        end
        c.total = c.total + 1
        if q.dlc then c.dlc_total = c.dlc_total + 1 end
        if q.cat == CAT.AVAILABLE then c.avail = c.avail + 1
        elseif q.cat == CAT.PROGRESS then c.prog = c.prog + 1
        elseif q.cat == CAT.DONE then c.done = c.done + 1 if q.dlc then c.dlc_done = c.dlc_done + 1 end
        elseif q.cat == CAT.LOCKED then c.locked = c.locked + 1
        elseif q.cat == CAT.FAILED then c.failed = c.failed + 1
        elseif q.cat == CAT.MISSED then c.missed = c.missed + 1 end
        if q.timed then c.timed = c.timed + 1 end
        if q.clears == 0 and q.cat ~= CAT.DONE and q.cat ~= CAT.MISSED and q.cat ~= CAT.FAILED then c.fresh = c.fresh + 1 end
        q.time_risk = q.timer ~= nil and q.timer.kind ~= "wait" and (q.cat == CAT.AVAILABLE or q.cat == CAT.PROGRESS)
        if q.risk >= 1 or q.time_risk then c.risk = c.risk + 1 end
    end
    local glist = {}
    for _, g in pairs(groups) do glist[#glist + 1] = g end
    table.sort(glist, function(a, b) if a.level ~= b.level then return a.level > b.level end return a.driver < b.driver end)
    -- one notice per story quest when it moves closer, not one per side quest
    M.group_level = M.group_level or {}
    for _, g in ipairs(glist) do
        local open = 0
        for _, id in ipairs(g.quests) do
            local x = M.quests[id]
            if x.cat == CAT.AVAILABLE or x.cat == CAT.PROGRESS then open = open + 1 end
        end
        g.open = open
        local was = M.group_level[g.driver] or 0
        if M.baseline and g.level > was and g.level >= 2 and open > 0 then
            local dn = M.name(g.driver) or "A story quest"
            local head = (g.level >= 3) and ("'" .. dn .. "' is under way") or ("'" .. dn .. "' can now be started")
            push_event("risk", head, open .. " open quest" .. (open > 1 and "s end" or " ends") .. " when it completes. See At Risk in the ledger.", g.driver)
        end
        M.group_level[g.driver] = g.level
    end
    M.groups = glist

    local timers = {}
    for _, id in ipairs(M.order) do
        local q = M.quests[id]
        if q.timer and (q.cat == CAT.AVAILABLE or q.cat == CAT.PROGRESS) then timers[#timers + 1] = q end
    end
    table.sort(timers, function(a, b) return a.timer.left < b.timer.left end)
    M.timers = timers
    c.timers = #timers
    M.counts = c
    M.refreshed = (M.refreshed or 0) + 1
    if (c.avail > 0 or c.prog > 0) and M.scan_cycle >= 1 and M.refreshed >= 2 then M.baseline = true end
end

-- spread over frames: a status pass touches ~120 quests, so it runs 24 at a time
local pass, last_pass = nil, -100
-- Ibrahim's forgery (one item at a time): what is being copied, game minutes left, and a notice when it's ready
local last_forge, forge_was = -100, nil
local function forgery_tick(now)
    if now - last_forge < 2 then return end
    last_forge = now
    local im = S("app.ItemManager")
    if not im then return end
    if try(function() return im:call("isFakeShopKeeped") end) ~= true then M.forgery, forge_was = nil, nil return end
    local done = try(function() return im:call("isFakeShopCompleted") end) == true
    local left = try(function() return im:call("isFakeShopRemainingMinute") end) or 0
    local f = M.forgery or {}
    if not f.item then
        local sd = try(function() return im:call("getFakeShopKeepedItem") end)
        local iid = sd and try(function() return sd:get_field("_ItemId") end)
        local nm = iid and m_item_name and U.clean(U.str(try(function() return m_item_name:call(nil, iid) end)))
        f.item = nm or "your item"
    end
    f.done, f.left = done or left <= 0, math.max(0, left) / 60 -- hours
    M.forgery = f
    if f.done and forge_was == false then push_event("new", "Forgery ready: " .. f.item, "Collect it from Ibrahim's Scrap Store.", 20350) end
    forge_was = f.done
end

function M.tick(now)
    forgery_tick(now)
    if not M.ready then
        if now - last_pass < 1.0 then return end
        last_pass = now
        M.ready = init_static()
        if not M.ready then return end
    end
    local qm, ql = S("app.QuestManager"), S("app.QuestLogManager")
    if not (qm and ql) then pass = nil return end
    if not pass then
        if now - last_pass < 2.0 then return end
        for id, _ in pairs(M.hidden) do M.result[id] = try(function() return qm:call("getQuestResultNo", id) end) or -1 end
        for _, id in ipairs(M.order) do M.result[id] = try(function() return qm:call("getQuestResultNo", id) end) or -1 end
        local avail, active = {}, {}
        for _, id in ipairs(U.list(try(function() return ql:call("getAcceptableQuestList") end))) do avail[id] = true end
        for _, id in ipairs(U.list(try(function() return qm:call("getActiveQuestIDList") end))) do active[id] = true end
        M.avail, M.active = avail, active
        local tracked = try(function() return ql:get_field("_CurrentDestinationTargetQuestID") end)
        M.tracked = type(tracked) == "number" and tracked or -1
        pass = 1
        return
    end
    local stop = math.min(pass + 23, #M.order)
    for i = pass, stop do status_pass(M.quests[M.order[i]], qm, ql) end
    pass = stop + 1
    if pass > #M.order then
        pass = nil
        last_pass = now
        finalize()
    end
end

---------------------------------------------------------------------------------------------------
-- deep scan: one quest per call. Reads the quest's waiting processors for timers, time windows,
-- required items and the NPCs the game itself points oracle hints at.
---------------------------------------------------------------------------------------------------
local scan_queue, scan_pos = {}, 0

-- what the quest-giver will actually take: the game's hand-over data for the next step not yet delivered
local function item_name(iid)
    local s = m_item_name and try(function() return m_item_name:call(nil, iid) end)
    if type(s) == "userdata" then s = U.str(s) end
    if type(s) == "string" and #s > 0 then return s end
    return nil
end

local function deliver_need(qid, cond_ids)
    local dm = S("app.QuestDeliverManager")
    local stages
    U.dict(dm and try(function() return dm:get_field("_ContextDict") end), function(k, v) if k == qid then stages = v end end)
    if not stages then return nil end
    local list = {}
    U.dict(stages, function(sk, ctx) list[#list + 1] = { k = sk, ctx = ctx } end)
    table.sort(list, function(a, b) return a.k < b.k end)
    for _, st in ipairs(list) do
        if try(function() return st.ctx:get_field("IsDeliverdItem") end) == false then
            local item = try(function() return st.ctx:get_field("Data"):get_field("_Item") end)
            if not item then return nil end
            local ids, order, need, infinite, label = {}, {}, 0, false, nil
            for _, slot in ipairs(U.array(try(function() return item:get_field("_Value") end))) do
                if try(function() return slot:get_field("_IsInfinite") end) == true then infinite = true end
                need = need + (try(function() return slot:get_field("_Count") end) or 1)
                label = label or U.clean(U.msg(try(function() return slot:get_field("_Name") end)))
                for _, iid in ipairs(U.array(try(function() return slot:get_field("_ItemID") end))) do
                    if type(iid) == "userdata" then iid = try(function() return iid:get_field("value__") end) end
                    if type(iid) == "number" and iid > 0 and not ids[iid] then ids[iid] = true order[#order + 1] = iid end
                end
            end
            if infinite or #order == 0 then return nil end
            local linked = false
            for iid, _ in pairs(cond_ids) do if ids[iid] then linked = true end end
            if not linked then return nil end
            local names = {}
            for _, iid in ipairs(order) do names[#names + 1] = item_name(iid) or ("Item " .. iid) end
            return { ids = order, names = names, need = need, label = label or names[1],
                partial = try(function() return item:get_field("_IncompletePossible") end) == true }
        end
    end
    return nil
end

-- the quest log's own notes: what has happened so far, and the people/places those notes point you to next
local function read_journal(q, nm)
    local ql = S("app.QuestLogManager")
    local dict = ql and try(function() return ql:get_field("_QuestLogInfoDict") end)
    local info = dict and try(function() return dict:call("get_Item", q.id) end)
    local res = info and try(function() return info:get_field("_Resource") end)
    if not res then q.story, q.leads = nil, nil return end
    local reminds = U.array(try(function() return res:get_field("_RemindList") end))
    local story, leads, seen = {}, {}, {}
    local done_idx = U.list(try(function() return info:get_field("<CompletedReminders>k__BackingField") end))
    -- places the game already names but you haven't been told about yet (e.g. the Putrid Cave in Prey for the Pack):
    -- only visible (non-hidden) area/place destinations with a real position, so they point where to go without
    -- revealing story beats.
    local done_set = {}
    for _, idx in ipairs(done_idx) do done_set[idx] = true end
    local function place_leads(r, base)
        for _, d in ipairs(U.array(try(function() return r:get_field("_Destinations") end))) do
            local dtype = try(function() return d:get_field("_DestType") end) or 0
            if dtype ~= 2 and try(function() return d:call("evaluateHide") end) ~= true then
                local label = U.clean(U.msg(try(function() return d:get_field("_MsgId") end)))
                local p = U.pos(try(function() return d:call("getDestination") end))
                if label and p and not U.is_zero(p) and G.off and not seen[label] then
                    seen[label] = true
                    leads[#leads + 1] = { label = label, pos = { x = p.x - G.off.x, y = p.y - G.off.y, z = p.z - G.off.z }, from = base }
                end
            end
        end
    end
    for _, idx in ipairs(done_idx) do
        local r = reminds[idx + 1]
        if r then
            local base = U.clean(U.msg(try(function() return r:get_field("_BaseMsg") end)))
            local detail = U.clean(U.msg(try(function() return r:get_field("_DetailMsg") end)))
            if base then story[#story + 1] = { text = base, detail = detail } end
            for _, d in ipairs(U.array(try(function() return r:get_field("_Destinations") end))) do
                local dtype = try(function() return d:get_field("_DestType") end) or 0
                -- the game hides a note's marker once that lead has been followed up
                if dtype ~= 0 and try(function() return d:call("evaluateHide") end) ~= true then
                    local label, pos = U.clean(U.msg(try(function() return d:get_field("_MsgId") end))), nil
                    if dtype == 2 then
                        local cid = try(function() return d:get_field("_CharaID") end)
                        local n = cid and npc_info(nm, cid)
                        if n then npc_update(nm, n) if not n.dead then pos = n.pos end label = n.name end
                    else
                        local p = U.pos(try(function() return d:call("getDestination") end))
                        if p and not U.is_zero(p) and G.off then pos = { x = p.x - G.off.x, y = p.y - G.off.y, z = p.z - G.off.z } end
                    end
                    if label and not seen[label] then
                        seen[label] = true
                        leads[#leads + 1] = { label = label, pos = pos, from = base }
                    end
                end
            end
        end
    end
    for i, r in ipairs(reminds) do
        if not done_set[i - 1] then place_leads(r, nil) end
    end
    q.story, q.leads = story, leads
end

-- where things can be bought, and where your storage is: shop -> keeper, item -> shops, inns (storage)
local shop_index = nil
local function build_shop_index(nm)
    local im, tem, gm = S("app.ItemManager"), S("app.TalkEventManager"), S("app.GuiManager")
    if not (im and tem and gm) then return nil end
    local idx = { item_shops = {}, shop_name = {}, shop_npc = {}, inns = {} }
    U.dict(try(function() return im:get_field("ShopParamTable") end), function(sid, sp)
        idx.shop_name[sid] = U.clean(U.msg(try(function() return sp:get_field("_ShopNameId") end)))
        for _, bp in ipairs(U.array(try(function() return sp:get_field("_BuyParams") end))) do
            local iid = try(function() return bp:get_field("_ItemId") end)
            if type(iid) == "number" and iid > 0 then
                local t = idx.item_shops[iid] or {}
                t[#t + 1] = sid
                idx.item_shops[iid] = t
            end
        end
    end)
    local td = sdk.find_type_definition("app.CharacterID")
    for _, f in ipairs(td and try(function() return td:get_fields() end) or {}) do
        if try(function() return f:is_static() end) then
            local cid = try(function() return f:get_data(nil) end)
            if type(cid) == "number" then
                local sid = try(function() return tem:call("getShopId", cid) end)
                if type(sid) == "number" and sid > 0 and not idx.shop_npc[sid] then idx.shop_npc[sid] = cid end
            end
        end
    end
    for _, ip in ipairs(U.list(try(function() return gm:get_field("MapIconList") end))) do
        if try(function() return ip:get_field("_IconType") end) == 9 then
            local p = U.pos(try(function() return ip:get_field("_Pos") end))
            local name = U.clean(U.msg(try(function() return ip:get_field("_DispNameId") end)))
            if p and name and not U.is_zero(p) then idx.inns[#idx.inns + 1] = { name = name, pos = p } end
        end
    end
    return idx
end

-- the nearest place to buy any of these items, as { label, pos, shop }
local function nearest_shop(nm, ids)
    local best, bd
    for _, iid in ipairs(ids) do
        for _, sid in ipairs(shop_index.item_shops[iid] or {}) do
            local cid = shop_index.shop_npc[sid]
            if cid then
                local h = try(function() return nm:call("getNPCHolder", cid) end)
                local p = h and U.pos(try(function() return h:call("get_UniversalPosition") end))
                if U.is_zero(p) then p = U.pos(try(function() return nm:call("getCurrentScheduleDistination(app.CharacterID)", cid) end)) end
                if p and not U.is_zero(p) then
                    local d = G.dist(p)
                    if not bd or d < bd then
                        local cd = try(function() return nm:call("getNPCData", cid) end)
                        local who = cd and U.str(try(function() return cd:call("get_Name") end))
                        best, bd = { shop = shop_index.shop_name[sid] or who or "Shop", who = who, pos = p }, d
                    end
                end
            end
        end
    end
    return best
end
local function nearest_inn()
    local best, bd
    for _, inn in ipairs(shop_index.inns) do
        local d = G.dist(inn.pos)
        if not bd or d < bd then best, bd = inn, d end
    end
    return best
end

-- where to buy / store an item, for the ledger and for checks
function M.where_to_get(ids)
    local nm = S("app.NPCManager")
    if not shop_index then shop_index = build_shop_index(nm) end
    if not (shop_index and nm) then return nil end
    return nearest_shop(nm, ids), nearest_inn()
end

local function scan_quest(id, now)
    local qm, nm, tm, im = S("app.QuestManager"), S("app.NPCManager"), S("app.TimeManager"), S("app.ItemManager")
    if not (qm and nm) then return end
    local q = M.quests[id]
    local is_marker = q == nil
    local ent = try(function() return qm:call("getQuestEnity", id) end)
    if not ent then return end
    local ctrl = try(function() return ent:get_field("Controller") end)
    local pfc = ctrl and try(function() return ctrl:get_field("_ProcessorFolderController") end)
    local procs = pfc and U.list(try(function() return pfc:get_field("_ProcessorList") end)) or {}

    local best_timer, windows, items, cond_npcs, marker_main = nil, {}, {}, {}, nil
    local all_timers = {}
    for _, p in ipairs(procs) do
        if try(function() return p:get_field("<CurrentPhase>k__BackingField") end) == 3 then
            local act = try(function() return p:get_field("Process"):get_field("QuestAction") end)
            local act_name = act and U.tname(act) or ""
            for _, lst in ipairs(U.list(try(function() return p:get_field("ConditionLists") end))) do
                for _, cnd in ipairs(U.list(lst)) do
                    local t = U.tname(cnd) or ""
                    local prm = try(function() return cnd:get_field("Param") end)
                    if prm then
                        if is_marker then
                            if t == "app.quest.condition.CheckScenarioStatus" then
                                local mq = try(function() return prm:get_field("_QuestID") end)
                                local mm = mq and M.quests[mq]
                                if mm and mm.main and (not marker_main or mq > marker_main) then marker_main = mq end
                            end
                        elseif t == "app.quest.condition.CheckElapsedTime" then
                            local loop = try(function() return prm:get_field("_IsLoopCondition") end)
                            local hours = (try(function() return prm:get_field("_ElapsedHour") end) or 0) + (try(function() return prm:get_field("_ElapsedMinute") end) or 0) / 60
                            local key = U.str(try(function() return p:get_field("<TimeDetectionKey>k__BackingField") end))
                            if tm and key and not loop and hours >= 1 and try(function() return tm:call("isValidQuestDetection", key) end) == true then
                                local el = try(function() return tm:call("getQuestDetectionElapsedTime", key) end)
                                local sat = try(function() return tm:call("isQuestDetectionSatisfy", key) end)
                                if type(el) == "number" and sat ~= true then
                                    local left = hours - el / 3600
                                    if left > 0 then
                                        all_timers[#all_timers + 1] = { left = left, total = hours, key = key, read_at = now, trigger = (act_name == "app.quest.action.Trigger") }
                                    end
                                end
                            end
                        elseif t == "app.quest.condition.CheckTimeOfDay" and act_name == "app.quest.action.PlayEvent" then
                            local sh, eh = try(function() return prm:get_field("_StartPointHour") end), try(function() return prm:get_field("_EndPointHour") end)
                            if sh and eh then windows[string.format("%02d:00-%02d:59", sh, eh)] = { sh = sh, eh = eh } end
                        elseif t == "app.quest.condition.CheckHasItem" then
                            for _, it in ipairs(U.array(try(function() return prm:get_field("_ItemInfoArray") end))) do
                                local iid, num = try(function() return it:get_field("_ID") end), try(function() return it:get_field("_Number") end)
                                if type(iid) == "number" and iid > 0 then
                                    if not items[iid] or (num or 1) > items[iid].need then items[iid] = { id = iid, need = num or 1 } end
                                end
                            end
                        elseif t == "app.quest.condition.CheckNPCArrivedLocation" then
                            local cid = try(function() return prm:get_field("_CharaID") end)
                            if cid then cond_npcs[cid] = true end
                        elseif t == "app.quest.condition.CheckNpcDistance" then
                            for _, f in ipairs({ "_CharaA", "_CharaB" }) do
                                local cid = try(function() return prm:get_field(f) end)
                                if cid then cond_npcs[cid] = true end
                            end
                        end
                    end
                end
            end
        end
    end

    if is_marker then
        if marker_main then M.driver[id] = marker_main M.driver_confirmed[id] = true end
        return
    end

    -- timer (with threshold notices). Quests often run several clocks at once: state changes hang off
    -- Trigger processors, so those win; a wait shows the longest one, anything else the soonest.
    local old = q.timer
    -- deadline: the step carries the game's hourglass.  wait: the task itself tells you to come back later.
    -- expires: a clock on a step that doesn't read like a wait; treat it as one that can run out.
    -- window: a clock running before you have accepted the quest.
    local kind
    if q.cat == CAT.PROGRESS then
        -- the task line, plus the journal's latest entry ("It should only take him a day or so.")
        local t = (q.task or ""):lower()
        local last = q.story and q.story[#q.story]
        if last then t = t .. " " .. ((last.detail or "") .. " " .. (last.text or "")):lower() end
        local function has(w) return t:find(w, 1, true) ~= nil end
        if q.timed then kind = "deadline"
        elseif has("day") or has("week") or has("tomorrow") or has("night") or has("wait") or has("later") or has("come back")
            or has("return to") or has("some time") or has("a while") or has("in time") or has("tests") or has("prepare") then kind = "wait"
        else kind = "expires" end
    else
        kind = "window"
    end
    local pool = {}
    for _, t in ipairs(all_timers) do if t.trigger then pool[#pool + 1] = t end end
    if #pool == 0 then pool = all_timers end
    for _, t in ipairs(pool) do
        if not best_timer then best_timer = t
        elseif kind == "wait" then
            if t.total > best_timer.total or (t.total == best_timer.total and t.left > best_timer.left) then best_timer = t end
        elseif t.left < best_timer.left then best_timer = t end
    end
    if best_timer then
        best_timer.kind = kind
        best_timer.warned = old and old.warned or 99
        for _, th in ipairs({ 24, 6, 1 }) do
            if best_timer.left <= th and best_timer.warned > th then
                best_timer.warned = th
                if best_timer.kind ~= "wait" then
                    push_event("timer", U.fmt_hours(best_timer.left) .. " left: " .. q.name, "About " .. U.fmt_real(best_timer.left), id)
                elseif best_timer.kind == "wait" and th == 1 then
                    push_event("new", "Almost ready: " .. q.name, "About " .. U.fmt_real(best_timer.left), id)
                end
            end
        end
    elseif old and old.kind == "wait" and q.cat == CAT.PROGRESS then
        push_event("new", "Ready: " .. q.name, q.task, id)
    end
    q.timer = best_timer

    local wl = {}
    for k, w in pairs(windows) do wl[#wl + 1] = { text = k, sh = w.sh, eh = w.eh } end
    table.sort(wl, function(a, b) return a.sh < b.sh end)
    q.windows = wl

    local il = {}
    local function have_of(iid) return (im and G.player) and try(function() return im:call("getHaveNum(System.Int32, app.Character)", iid, G.player) end) or 0 end
    if q.cat == CAT.PROGRESS and next(items) then
        local dv = deliver_need(id, items)
        if dv then
            -- the hand-over: one line, counting everything that qualifies
            local have = 0
            for _, iid in ipairs(dv.ids) do have = have + have_of(iid) end
            il[1] = { name = dv.label, have = have, need = dv.need, partial = dv.partial, options = (#dv.names > 1) and dv.names or nil, ids = dv.ids }
        else
            -- the quest checks for these but the amount it wants is not stated anywhere readable: show what you carry
            for iid, _ in pairs(items) do
                local nm_s = item_name(iid)
                if nm_s then il[#il + 1] = { name = nm_s, have = have_of(iid) } end
            end
            table.sort(il, function(a, b) return a.name < b.name end)
        end
    end
    -- short of something? look in your pawns' packs and your storage, then route to storage or a shop
    local iwps = {}
    if q.cat == CAT.PROGRESS and #il > 0 and im then
        if not shop_index then shop_index = build_shop_index(nm) end
        for _, it in ipairs(il) do
            if it.need and (it.have or 0) < it.need and it.ids and shop_index then
                local party, all = 0, 0
                for _, iid in ipairs(it.ids) do
                    party = party + (try(function() return im:call("getHavePartyNum(System.Int32)", iid) end) or 0)
                    all = all + (try(function() return im:call("getHaveAllNum(System.Int32)", iid) end) or 0)
                end
                it.pawn = math.max(0, party - (it.have or 0))
                it.stored = math.max(0, all - party)
                local short = it.need - (it.have or 0) - it.pawn
                if short > 0 and it.stored > 0 then
                    local inn = nearest_inn()
                    if inn then
                        it.route = "storage"
                        iwps[#iwps + 1] = { label = "Storage (" .. it.name .. "): " .. inn.name, pos = inn.pos }
                    end
                elseif short > 0 then
                    local sh = nearest_shop(nm, it.ids)
                    if sh then
                        it.route, it.shop = "shop", sh.shop
                        iwps[#iwps + 1] = { label = "Buy " .. it.name .. ": " .. sh.shop, pos = sh.pos }
                    end
                end
            end
        end
    end
    q.item_wps = iwps
    q.items = il

    -- people: the game's own oracle targets first, then anyone named in the waiting conditions
    local npcs, seen = {}, {}
    for _, cid in ipairs(U.list(try(function() return qm:call("getOracleHintCharacter", id) end))) do
        if not seen[cid] then
            seen[cid] = true
            local n = npc_info(nm, cid)
            if n then n.oracle = true npcs[#npcs + 1] = n end
        end
    end
    -- for a quest you have started, people named in the game's internal checks are not instructions;
    -- only fall back to them for quests you have yet to pick up
    if #npcs == 0 and q.cat ~= CAT.PROGRESS then
        for cid, _ in pairs(cond_npcs) do
            if not seen[cid] then
                seen[cid] = true
                local n = npc_info(nm, cid)
                if n then npcs[#npcs + 1] = n end
            end
        end
    end
    for _, n in ipairs(npcs) do npc_update(nm, n) end
    table.sort(npcs, function(a, b) return a.name < b.name end)
    q.npcs = npcs

    -- anyone in the quest's cast who has died
    local dead_old = q.dead or {}
    local dead, dead_set = {}, {}
    local ctx = try(function() return ent:get_field("Context") end)
    for _, cid in ipairs(U.list(ctx and try(function() return ctx:call("get_NPCCastList") end))) do
        if cid ~= PLAYER_ID and cid ~= PAWN_ID and try(function() return nm:call("NPCisDead", cid) end) == true then
            local n = npc_info(nm, cid)
            if n then dead[#dead + 1] = n.name dead_set[n.name] = true end
        end
    end
    if M.baseline and (q.cat == CAT.AVAILABLE or q.cat == CAT.PROGRESS) then
        local was = {}
        for _, nme in ipairs(dead_old) do was[nme] = true end
        for _, nme in ipairs(dead) do
            if not was[nme] then push_event("dead", nme .. " has died", "Needed for '" .. q.name .. "'. The morgue can revive them with a Wakestone.", id) end
        end
    end
    q.dead = dead
    if q.cat == CAT.PROGRESS then read_journal(q, nm) else q.story, q.leads = nil, nil end
    q.scanned = now
end

function M.deep_step(now)
    if not M.ready or not M.active then return end
    if scan_pos >= #scan_queue then
        if #scan_queue > 0 then M.scan_cycle = M.scan_cycle + 1 end
        scan_queue, scan_pos = {}, 0
        for _, id in ipairs(M.order) do
            local q = M.quests[id]
            if q.active and (q.cat == CAT.AVAILABLE or q.cat == CAT.PROGRESS) then scan_queue[#scan_queue + 1] = id end
        end
        for id, _ in pairs(M.hidden) do
            if M.active[id] and M.driver[id] ~= nil then scan_queue[#scan_queue + 1] = id end
        end
        if #scan_queue == 0 then M.scan_cycle = M.scan_cycle + 1 return end
    end
    scan_pos = scan_pos + 1
    local id = scan_queue[scan_pos]
    local ok, err = pcall(scan_quest, id, now)
    if not ok then M.scan_error = tostring(err) end
end

-- keep positions fresh for the handful of quests the HUD is following
function M.refresh_people(q)
    local nm = S("app.NPCManager")
    if not (nm and q and q.npcs) then return end
    for _, n in ipairs(q.npcs) do npc_update(nm, n) end
end

-- where to go for this quest right now
function M.waypoints(q)
    local out = {}
    if not q then return out end
    if q.cat == CAT.PROGRESS and q.item_wps then
        for _, w in ipairs(q.item_wps) do out[#out + 1] = { pos = w.pos, label = w.label, kind = "objective", quest = q.id, priority = true } end
    end
    if q.cat == CAT.PROGRESS and q.dests then
        for _, d in ipairs(q.dests) do out[#out + 1] = { pos = d.pos, label = d.label, kind = "objective", quest = q.id } end
    end
    if q.cat == CAT.PROGRESS and q.leads then
        for _, l in ipairs(q.leads) do
            if l.pos then out[#out + 1] = { pos = l.pos, label = l.label, kind = "objective", quest = q.id, lead = true } end
        end
    end
    if (q.cat == CAT.PROGRESS or q.cat == CAT.AVAILABLE) and q.npcs then
        for _, n in ipairs(q.npcs) do
            if n.pos and not n.dead then
                local dup = false
                for _, w in ipairs(out) do
                    if U.dist2d(w.pos, n.pos) < 6 then
                        dup = true
                        -- two people standing together: keep the one who will actually talk
                        if n.ready and not w.ready and w.kind ~= "objective" then w.label, w.ready = n.name, true end
                    end
                end
                -- the same person can be listed under two character IDs (e.g. a home copy and the live one):
                -- keep one marker per name, preferring the one actually loaded in the world, then the ready one
                for _, w in ipairs(out) do
                    if not dup and w.label == n.name then
                        dup = true
                        -- a journal lead naming this person: follow the person themself, where they stand now
                        if w.kind == "objective" then w.pos, w.ready, w.loaded = n.pos, n.ready, n.loaded
                        elseif (n.loaded and not w.loaded) or (n.ready and not w.ready and n.loaded == w.loaded) then
                            w.pos, w.ready, w.loaded = n.pos, n.ready, n.loaded
                        end
                    end
                end
                if not dup then out[#out + 1] = { pos = n.pos, label = n.name, kind = (q.cat == CAT.AVAILABLE) and "giver" or "person", quest = q.id, ready = n.ready, loaded = n.loaded } end
            end
        end
    end
    return out
end

function M.nearest_waypoint(q)
    local best, bd
    for _, w in ipairs(M.waypoints(q)) do
        local d = G.dist(w.pos)
        if not bd or d < bd then best, bd = w, d end
    end
    return best, bd
end

-- everyone the quest involves, with where they are now (built on demand for the detail pane)
function M.cast(q)
    local qm, nm = S("app.QuestManager"), S("app.NPCManager")
    local out = {}
    if not (qm and nm and q) then return out end
    local ent = try(function() return qm:call("getQuestEnity", q.id) end)
    local ctx = ent and try(function() return ent:get_field("Context") end)
    for _, cid in ipairs(U.list(ctx and try(function() return ctx:call("get_NPCCastList") end))) do
        local n = npc_info(nm, cid)
        if n then npc_update(nm, n) out[#out + 1] = n end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- plain-language line for a cut-off entry
function M.cutoff_text(c)
    local did = c.driver
    local dn = did and M.name(did)
    if not dn then return "a later story event" end
    local s = "'" .. dn .. "'"
    if M.quests[c.cut] and c.r and c.r > 0 then s = s .. " (a particular outcome)" end
    return s
end

function M.requirement_text(q)
    local parts = {}
    for _, grp in ipairs(q.prev or {}) do
        local names = {}
        for _, it in ipairs(grp.items) do
            local n = M.name(it.q)
            if n then names[#names + 1] = n end
        end
        if #names > 0 then parts[#parts + 1] = table.concat(names, grp.any and " or " or " and ") end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, "; ")
end

return M
