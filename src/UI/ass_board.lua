-- ASS 绘制原语 + UTF-8 文本度量 + 简易按钮命中检测
-- 约定: 绘制函数首参 A 为字符串数组, 最后 table.concat(A, "\n") 交给 overlay;
--       坐标为 ASS 虚拟画布坐标; 颜色 "RRGGBB"; alpha "00"(不透明)~"FF"(全透明)

local M = {}

-- 主题调色板 (push_pill 默认色也取自这里, 使用方可覆盖字段)
M.C = {
    panel = "161922", panel_ln = "2A2F3C",
    card = "222734", card_hov = "2C3242",
    line = "333A4A",
    accent = "FF8FAB", accent_d = "E76A8B", accent_hi = "FFA9C4",
    on_accent = "2B1220", on_gold = "3A2A05", gold = "FFD166",
    text = "F2F3F5", body = "C9CEDA", sub = "9AA3B2", faint = "646C7D",
}

local function fmt(...) return string.format(...) end

-- "RRGGBB" -> "&HBBGGRR&"
function M.bgr(hex)
    return ("&H%s%s%s&"):format(hex:sub(5, 6), hex:sub(3, 4), hex:sub(1, 2))
end

-- ASS 特殊字符转义 (同 mpv 内置 osc 的技巧)
function M.ass_escape(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\239\187\191")
    s = s:gsub("{", "\\{")
    s = s:gsub("}", "\\}")
    return s
end

--==============================================================================
-- UTF-8 / 文本度量
--==============================================================================
function M.utf8_chars(s)
    local t, i = {}, 1
    while i <= #s do
        local b = s:byte(i)
        local n = 1
        if b >= 0xF0 then n = 4 elseif b >= 0xE0 then n = 3 elseif b >= 0xC0 then n = 2 end
        t[#t + 1] = s:sub(i, i + n - 1)
        i = i + n
    end
    return t
end

function M.utf8_codepoint(ch)
    local b1, b2, b3, b4 = ch:byte(1, 4)
    if b1 < 0xE0 then return b1 end
    if b1 < 0xF0 then
        return (b1 % 0x10) * 0x1000 + ((b2 or 0) % 0x40) * 0x40 + ((b3 or 0) % 0x40)
    end
    return (b1 % 0x08) * 0x40000 + ((b2 or 0) % 0x40) * 0x1000
        + ((b3 or 0) % 0x40) * 0x40 + ((b4 or 0) % 0x40)
end

function M.is_wide(ch)
    local cp = M.utf8_codepoint(ch)
    return (cp >= 0x1100 and cp <= 0x115F) or (cp >= 0x2E80 and cp <= 0xA4CF)
        or (cp >= 0xAC00 and cp <= 0xD7A3) or (cp >= 0xF900 and cp <= 0xFAFF)
        or (cp >= 0xFE30 and cp <= 0xFE4F) or (cp >= 0xFF00 and cp <= 0xFF60)
        or (cp >= 0xFFE0 and cp <= 0xFFE6) or (cp >= 0x20000 and cp <= 0x3FFFD)
end

function M.char_w(ch, fs)
    return (M.is_wide(ch) and 1.0 or 0.53) * fs
end

function M.text_width(s, fs)
    local w = 0
    for _, ch in ipairs(M.utf8_chars(tostring(s or ""))) do
        w = w + M.char_w(ch, fs)
    end
    return w
end

function M.truncate_w(s, fs, max_w)
    s = tostring(s or "")
    if M.text_width(s, fs) <= max_w then return s end
    local out, w = "", 0
    local dots = M.text_width("…", fs)
    for _, ch in ipairs(M.utf8_chars(s)) do
        local cw = M.char_w(ch, fs)
        if w + cw > max_w - dots then break end
        out = out .. ch
        w = w + cw
    end
    return out .. "…"
end

function M.wrap_text(s, fs, max_w, max_lines)
    s = tostring(s or ""):gsub("[\r\n]+", " ")
    local lines, cur, w = {}, "", 0
    for _, ch in ipairs(M.utf8_chars(s)) do
        local cw = M.char_w(ch, fs)
        if w + cw > max_w and #cur > 0 then
            lines[#lines + 1] = cur
            cur, w = "", 0
        end
        cur = cur .. ch
        w = w + cw
    end
    if #cur > 0 then lines[#lines + 1] = cur end
    if max_lines and #lines > max_lines then
        local out = {}
        for i = 1, max_lines - 1 do out[i] = lines[i] end
        out[max_lines] = M.truncate_w(lines[max_lines], fs, max_w - M.text_width("…", fs)) .. "…"
        return out
    end
    return lines
end

-- 两段宽度换行: 前 n1 行用 w1 宽, 之后用 w2 宽 (简介绕开封面时用)
function M.wrap_two(s, fs, w1, n1, w2, max_lines)
    s = tostring(s or ""):gsub("[\r\n]+", " ")
    local lines, cur, w = {}, "", 0
    local max_w = w1
    for _, ch in ipairs(M.utf8_chars(s)) do
        local cw = M.char_w(ch, fs)
        if w + cw > max_w and #cur > 0 then
            lines[#lines + 1] = cur
            cur, w = "", 0
            if #lines >= n1 then max_w = w2 end
        end
        cur = cur .. ch
        w = w + cw
    end
    if #cur > 0 then lines[#lines + 1] = cur end
    if max_lines and #lines > max_lines then
        local lw = (max_lines <= n1) and w1 or w2
        lines[max_lines] = M.truncate_w(lines[max_lines], fs, lw - M.text_width("…", fs)) .. "…"
        for i = max_lines + 1, #lines do lines[i] = nil end
    end
    return lines
end

--==============================================================================
-- 形状 / 文本
--==============================================================================
function M.rect_path(w, h, r)
    r = math.max(0, math.min(r, w / 2, h / 2))
    return table.concat({
        fmt("m %g 0 l %g 0 b %g 0 %g 0 %g %g l %g %g", r, w - r, w, w, w, r, w, h - r),
        fmt("b %g %g %g %g %g %g l %g %g", w, h, w, h, w - r, h, r, h),
        fmt("b 0 %g 0 %g 0 %g l 0 %g", h, h, h - r, r),
        fmt("b 0 0 0 0 %g 0", r),
    }, " ")
end

function M.push_rect(A, x, y, w, h, r, fill, fill_a, line, line_a, bw)
    local t = fmt("{\\an7\\pos(%g,%g)\\p1\\shad0\\bord%d", x, y, bw or 0)
    if fill then
        t = t .. "\\1c" .. M.bgr(fill) .. fmt("\\1a&H%s&", fill_a or "00")
    else
        t = t .. "\\1a&HFF&"
    end
    if line then
        t = t .. "\\3c" .. M.bgr(line) .. fmt("\\3a&H%s&", line_a or "00")
    else
        t = t .. "\\3a&HFF&"
    end
    A[#A + 1] = t .. "}" .. M.rect_path(w, h, r) .. "{\\p0}"
end

function M.push_text(A, x, y, s, fs, color, o2)
    o2 = o2 or {}
    local t = fmt("{\\an%d\\pos(%g,%g)\\fs%g\\bord0\\shad0\\c%s",
        o2.align or 4, x, y, fs, M.bgr(color))
    if o2.alpha then t = t .. fmt("\\1a&H%s&", o2.alpha) end
    if o2.bold then t = t .. "\\b1" end
    if o2.italic then t = t .. "\\i1" end
    A[#A + 1] = t .. "}" .. M.ass_escape(s)
end

function M.push_hline(A, x, y, w, color, alpha)
    A[#A + 1] = fmt("{\\an7\\pos(%g,%g)\\p1\\shad0\\bord0\\1c%s\\1a&H%s&}"
        .. "m 0 0 l %g 0 l %g 1.5 l 0 1.5{\\p0}",
        x, y, M.bgr(color), alpha or "50", w, w)
end

function M.push_dim(A, alpha, w, h)
    A[#A + 1] = fmt("{\\an7\\pos(0,0)\\p1\\shad0\\bord0\\1c&H000000&\\1a&H%s&}"
        .. "m 0 0 l %g 0 l %g %g l 0 %g{\\p0}", alpha, w, w, h, h)
end

--==============================================================================
-- 按钮命中
--==============================================================================
function M.btn_name(kind, action)
    return kind .. ":" .. tostring(action)
end

function M.add_btn(buttons, x, y, w, h, kind, action)
    buttons[#buttons + 1] = { x = x, y = y, w = w, h = h, name = M.btn_name(kind, action) }
end

function M.hit_test(buttons, px, py)
    for _, b in ipairs(buttons) do
        if px >= b.x and px <= b.x + b.w and py >= b.y and py <= b.y + b.h then
            return b.name
        end
    end
    return nil
end

--==============================================================================
-- 胶囊 / 流式布局
--==============================================================================
-- opts: {fs,h,padx,bg,bg_a,fg,line,line_a,hbg,hfg,bold,
--        kind, action, hover(bool), buttons(提供时注册命中区域)}
function M.push_pill(A, x, y, s, opts)
    opts = opts or {}
    local fs, h = opts.fs or 19, opts.h or 36
    local padx = opts.padx or 16
    local w = M.text_width(s, fs) + padx * 2
    local C = M.C
    local hov = opts.action and opts.hover or false
    local bg = hov and (opts.hbg or C.card_hov) or (opts.bg or C.card)
    local fgc = hov and (opts.hfg or C.text) or (opts.fg or C.sub)
    M.push_rect(A, x, y, w, h, h / 2, bg, opts.bg_a or "00", opts.line, opts.line_a or "40", opts.bw or 1)
    M.push_text(A, x + w / 2, y + h / 2, s, fs, fgc, { align = 5, bold = opts.bold })
    if opts.action and opts.buttons then
        M.add_btn(opts.buttons, x, y, w, h, opts.kind or "pill", opts.action)
    end
    return w, h
end

function M.flow(A, items, x, y, max_w, gx, gy, draw)
    local cx, cy = x, y
    for _, it in ipairs(items) do
        local w, h = draw(it, cx, cy, true)
        if cx + w > x + max_w and cx > x then
            cx = x
            cy = cy + h + gy
        end
        draw(it, cx, cy, false)
        cx = cx + w + gx
    end
    return cy
end

return M
