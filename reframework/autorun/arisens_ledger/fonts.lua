-- Arisen's Ledger: fonts and text drawing. Loaded once; survives hot reloads of the other modules.
local F = {}
F.body = imgui.load_font("AlegreyaSans-Medium.ttf", 22)
F.bold = imgui.load_font("AlegreyaSans-Bold.ttf", 22)
F.title = imgui.load_font("Cinzel.ttf", 28)
local V = Vector2f.new
local SHADOW = 0xD0000000

local cur_font, cur_size = nil, nil
function F.push(font, size)
    imgui.push_font(font)
    imgui.push_font_size(math.max(8, math.floor(size + 0.5)))
end
function F.pop()
    imgui.pop_font_size()
    imgui.pop_font()
end

function F.width(font, size, s)
    F.push(font, size)
    local w = imgui.calc_text_size(s).x
    F.pop()
    return w
end

-- draw text on a draw list; shadow = true adds a drop shadow for text over the game world
function F.text(d, font, size, x, y, col, s, shadow)
    F.push(font, size)
    if shadow then
        local a = (col >> 24) & 0xFF
        local sc = (SHADOW & 0x00FFFFFF) | ((math.floor(a * 0.8)) << 24)
        d:add_text(V(x + 1.5, y + 1.5), sc, s)
    end
    d:add_text(V(x, y), col, s)
    F.pop()
end

function F.text_centered(d, font, size, cx, y, col, s, shadow)
    F.push(font, size)
    local w = imgui.calc_text_size(s).x
    if shadow then
        local a = (col >> 24) & 0xFF
        d:add_text(V(cx - w / 2 + 1.5, y + 1.5), (SHADOW & 0x00FFFFFF) | ((math.floor(a * 0.8)) << 24), s)
    end
    d:add_text(V(cx - w / 2, y), col, s)
    F.pop()
    return w
end

-- greedy word wrap; returns a list of lines
function F.wrap(font, size, s, max_w, max_lines)
    local lines = {}
    if not s or s == "" then return lines end
    F.push(font, size)
    local line = ""
    for word in s:gmatch("%S+") do
        local try_line = (line == "") and word or (line .. " " .. word)
        if imgui.calc_text_size(try_line).x <= max_w or line == "" then
            line = try_line
        else
            lines[#lines + 1] = line
            line = word
            if max_lines and #lines >= max_lines then break end
        end
    end
    if line ~= "" and not (max_lines and #lines >= max_lines) then lines[#lines + 1] = line end
    if max_lines and #lines == max_lines then
        -- mark truncation when text was cut
        local joined = table.concat(lines, " ")
        if #joined < #s:gsub("%s+", " ") - 1 then
            local last = lines[#lines]
            while #last > 3 and imgui.calc_text_size(last .. "...").x > max_w do last = last:sub(1, -2) end
            lines[#lines] = last .. "..."
        end
    end
    F.pop()
    return lines
end

-- shorten to fit a width
function F.fit(font, size, s, max_w)
    F.push(font, size)
    if imgui.calc_text_size(s).x > max_w then
        while #s > 3 and imgui.calc_text_size(s .. "...").x > max_w do s = s:sub(1, -2) end
        s = s .. "..."
    end
    F.pop()
    return s
end

return F
