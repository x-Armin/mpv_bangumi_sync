-- src/ui_info.lua
--
-- 番剧元数据信息面板 (ASS OSD / 圆角卡片 UI)
-- 数据来源: <数据目录>/metadata/<番剧ID>/<番剧ID>-info.json | info.json
--           <数据目录>/metadata/<番剧ID>/<episodeId>.json
--
-- 快捷键:  ESC 关闭 / ← → 切页签 / 滚轮: 剧集页翻页·其他切页签
--         左键: 页签 / 翻页 / 链接 / ✕ / 封面重试
-- 脚本消息: script-message [to] bgm-info-panel show [番剧ID] | hide | toggle
--           (兼容旧消息名 bangumi-info)
-- 集成接口: M.notify_match(animeId, episodeId) — 由 main.lua 在同步成功后推送,
--           绕过文件名数字猜测直接精确定位当前集。

local mp = require "mp"
local msg = require "mp.msg"
local mp_utils = require "mp.utils"

local paths = require "src.paths"
local json_store = require "src.core.json_store"
local ass = require "src.UI.ass_board"
local ui_cover = require "src.UI.cover"
local config = require "src.config"

local C = ass.C
local fmt = string.format

-- 配置统一来自 mpv_bangumi_sync.conf (panel_* 键, 由 src.config 归一化)
local o = config.panel or {}

--==============================================================================
-- 状态
--==============================================================================
-- 原版第 2 页签实际渲染 标签/别名/外部链接/相关作品, 标签更名为 "更多"
local TABS = { "概览", "更多", "制作", "剧集" }
local EP_PER_PAGE = 14 -- 剧集页: 2 列 x 7 行

local overlay = nil
local shown = false
local data = nil        -- <id>-info.json 解析结果
local cur_ep_id = nil
local cur_ep = nil
local tab = 1
local ep_page = 1
local ep_grid = nil     -- 剧集网格区域 (滚轮判定)
local buttons = {}
local hover_name = ""
local bound_keys = {}

local current = { anime_id = nil, episode_id = nil } -- M.notify_match 推送

local W, H, PW, PH, PX, PY, CT, CB

--==============================================================================
-- 元数据加载
--==============================================================================
local function read_json(path)
    if not path or path == "" then return nil end
    local ok, res = pcall(json_store.read, path)
    if ok then return res end
    return nil
end

local function metadata_root()
    local dir = mp_utils.join_path(paths.get_data_path(), "metadata")
    return mp.command_native({ "expand-path", dir }) or ""
end

local function md(key) -- 读取 metadata 数组中的 "键: 值"
    if not data or not data.metadata then return nil end
    for _, m in ipairs(data.metadata) do
        if type(m) == "string" then
            local k, v = m:match("^(.-)%s*:%s*(.*)$")
            if k == key and v ~= "" then return v end
        end
    end
    return nil
end

local function fmt_date_cn(s)
    if not s then return nil end
    local y, mo, d = s:match("^(%d+)%s*年%s*(%d+)%s*月%s*(%d+)%s*日$")
    if y then return fmt("%s-%02d-%02d", y, tonumber(mo), tonumber(d)) end
    return s
end

local function find_ep(id)
    if not data or not data.episodes then return nil end
    for _, e in ipairs(data.episodes) do
        if tonumber(e.episodeId) == id then return e end
    end
    return nil
end

local function list_anime_dirs()
    local root = metadata_root()
    if root == "" then return {} end
    local items = mp_utils.readdir(root)
    local dirs = {}
    if items then
        for _, n in ipairs(items) do
            local fi = mp_utils.file_info(root .. "/" .. n)
            if fi and fi.is_dir then dirs[#dirs + 1] = n end
        end
        table.sort(dirs)
    end
    return dirs
end

-- info.json 双格式兼容:
--  A) anixplayer/dandanplay 聚合格式 (animeTitle/imageUrl/rating=数字/ratingDetails...)
--  B) Bangumi API subject 原始格式 (name_cn/images.*/rating={score=..}/infobox...)
-- 统一归一化为 A 格式, 渲染层零改动
local function normalize_info(raw)
    if type(raw) ~= "table" then return nil end
    if raw.animeTitle then return raw end                       -- 已是 A 格式

    local d = {}
    d.animeTitle = raw.name_cn or raw.name
    d.summary    = raw.summary
    d.imageUrl   = raw.imageUrl or (raw.images and
        (raw.images.large or raw.images.medium or raw.images.common
         or raw.images.small or raw.images.grid))
    d.typeDescription = raw.typeDescription or raw.platform
    d.tags       = raw.tags
    d.animeId    = raw.animeId or raw.id
    d.bangumiId  = raw.bangumiId or raw.id
    d.bangumiUrl = raw.bangumiUrl
        or (raw.id and ("https://bangumi.tv/subject/" .. tostring(raw.id)) or nil)
    d.date       = raw.date
    d.airDay     = raw.airDay

    -- rating: {score=7.7, rank=.., count={..}} → 数字
    local r = raw.rating
    if type(r) == "table" then r = r.score end
    d.rating = tonumber(r)

    -- 分源评分: B 格式没有, 用综合评分合成一项 (评分区不至于空白)
    d.ratingDetails = raw.ratingDetails
        or (d.rating and { ["Bangumi评分"] = d.rating } or nil)

    -- infobox → metadata 字符串数组 ("导演: 水島努"), 并提取"别名" → titles
    d.metadata, d.titles = raw.metadata, raw.titles
    if raw.infobox then
        if not d.metadata then
            d.metadata = {}
            for _, kv in ipairs(raw.infobox) do
                local v = kv.value
                if type(v) == "table" then
                    local parts = {}
                    for _, it in ipairs(v) do parts[#parts + 1] = tostring(it.v or "") end
                    v = table.concat(parts, " / ")
                end
                d.metadata[#d.metadata + 1] = tostring(kv.key) .. ": " .. tostring(v)
            end
        end
        if not d.titles then
            d.titles = {}
            for _, kv in ipairs(raw.infobox) do
                if kv.key == "别名" and type(kv.value) == "table" then
                    for _, it in ipairs(kv.value) do
                        if it.v then
                            d.titles[#d.titles + 1] = { title = tostring(it.v), language = "别名" }
                        end
                    end
                end
            end
        end
    end
    return d
end

-- B 格式 info.json 不含剧集列表; 从同目录 episodes.json 补读并统一字段名
local function load_episodes(aid)
    local root = metadata_root()
    local ep = read_json(fmt("%s/%s/episodes.json", root, aid))
    if type(ep) == "table" and type(ep.episodes) == "table" then ep = ep.episodes end
    if type(ep) ~= "table" or #ep == 0 then return nil end
    local out = {}
    for _, e in ipairs(ep) do
        if type(e) == "table" then
            out[#out + 1] = {
                episodeId    = tonumber(e.episodeId or e.id),
                episodeTitle = e.episodeTitle or e.title or e.name_cn or e.name,
            }
        end
    end
    return #out > 0 and out or nil
end

local function load_info(anime_id)
    local root = metadata_root()
    local raw = read_json(fmt("%s/%s/%s-info.json", root, anime_id, anime_id))
        or read_json(fmt("%s/%s/info.json", root, anime_id))
    local data = normalize_info(raw)
    if data and not data.episodes then data.episodes = load_episodes(anime_id) end
    return data
end

-- 0) 同步模块推送的精确匹配
local function try_bridge()
    if not (current.anime_id and current.episode_id) then return false end
    local root = metadata_root()
    local ep = read_json(fmt("%s/%s/%s.json", root, current.anime_id, current.episode_id))
    local info = load_info(current.anime_id)
    if not info and not ep then return false end
    data = info or ep
    cur_ep_id = tonumber(current.episode_id)
    if ep then
        cur_ep = find_ep(cur_ep_id) or ep
    else
        cur_ep = find_ep(cur_ep_id)
    end
    return data ~= nil
end

local function load_for_current()
    data, cur_ep, cur_ep_id = nil, nil, nil

    if try_bridge() then return true end

    local path = mp.get_property("path")
    if not path then return false end
    local name = path:gsub(".*[\\/]", "")
    local root = metadata_root()
    local dirs = list_anime_dirs()

    -- 1) 文件名中的数字精确匹配 <animeId>/<数字>.json
    for n in name:gmatch("%d+") do
        for _, d in ipairs(dirs) do
            local ep = read_json(fmt("%s/%s/%s.json", root, d, n))
            if ep and ep.animeId then
                data = load_info(d) or ep
                cur_ep_id = tonumber(ep.episodeId) or tonumber(n)
                cur_ep = find_ep(cur_ep_id) or ep
                return data ~= nil
            end
        end
    end

    -- 2) 回退: 元数据下只有一个番剧时, 尝试 animeId*10000+集号 (102*10000+16)
    if #dirs == 1 then
        local d, aid = dirs[1], tonumber(dirs[1])
        data = load_info(d)
        if data then
            if aid then
                local e = name:match("[Ee][Pp](%d+)") or name:match("[Ee](%d+)")
                    or name:match("(%d+)%s*话") or name:match("(%d+)%.%w+$") or name:match("(%d+)")
                if e and #e <= 3 then
                    local id = aid * 10000 + tonumber(e)
                    local ep = read_json(fmt("%s/%s/%s.json", root, d, id))
                    if ep then
                        cur_ep_id = id
                        cur_ep = find_ep(id) or ep
                    end
                end
            end
            return true
        end
    end
    return false
end

--==============================================================================
-- 封面实例
--==============================================================================
local render -- 前向声明: 封面异步完成后重绘

local cover = ui_cover.create({
    root_dir = metadata_root(),
    panel_color = C.panel,
    cover_fill = o.cover_fill and "yes" or "no",
    mpv_path = o.mpv_path,
    overlay_id = 44,
    res_x = o.res_x,
    res_y = o.res_y,
    on_redraw = function() render() end,
})

--==============================================================================
-- 界面渲染
--==============================================================================
local function layout()
    W, H = o.res_x, o.res_y
    PW = math.min(1480, W - 80)
    PH = math.min(810, H - 60)
    PX, PY = (W - PW) / 2, (H - PH) / 2
    CT = PY + 258   -- 内容区顶
    CB = PY + PH - 66 -- 内容区底
end

-- 评分兼容: 数字 / 数字字符串 / {score=..}|{value=..} 对象 均转为数字, 无效返回 nil
local function rating_num(v)
    if type(v) == "table" then
        v = v.score or v.value or v.Value or v.rating or v.Rating
    end
    v = tonumber(v)
    return (v and v > 0) and v or nil
end

-- 面板本地 pill 封装: 自动挂 hover 状态与按钮注册
local function pill(A, x, y, s, opts)
    opts = opts or {}
    if opts.action then
        opts.hover = hover_name == ass.btn_name(opts.kind or "pill", opts.action)
        opts.buttons = buttons
    end
    return ass.push_pill(A, x, y, s, opts)
end

local function push_header(A)
    local x, ty = PX + 40, PY + 34
    local title = ass.truncate_w(data.animeTitle or data.searchKeyword or "番剧信息", 34, 880)
    ass.push_text(A, x, ty + 24, title, 34, C.text, { align = 4, bold = true })
    local cx = x + ass.text_width(title, 34) + 18
    if data.typeDescription then
        local w = pill(A, cx, ty + 6, data.typeDescription,
            { fs = 18, h = 30, padx = 14, bg = C.accent, bg_a = "10", fg = C.on_accent, bold = true })
        cx = cx + w + 12
    end
    local rt = rating_num(data.rating)
    if rt then
        pill(A, cx, ty + 6, fmt("★ %.1f", rt),
            { fs = 18, h = 30, padx = 14, bg = C.gold, bg_a = "10", fg = C.on_gold, bold = true })
    end
    -- 关闭按钮 ✕
    local bs = 44
    local bx, by = PX + PW - 40 - bs, PY + 26
    local hov = hover_name == ass.btn_name("close", "")
    ass.push_rect(A, bx, by, bs, bs, 12,
        hov and "5A2530" or C.card, "00",
        hov and C.accent_d or C.line, hov and "90" or "40", 1)
    ass.push_text(A, bx + bs / 2, by + bs / 2, "×", 26,
        hov and C.accent_d or C.sub, { align = 5, bold = true })
    ass.add_btn(buttons, bx, by, bs, bs, "close", "")
end

local function push_subtitle(A)
    local parts, jp, en = {}, nil, nil
    for _, t in ipairs(data.titles or {}) do
        if not jp and t.language and t.language:find("日语") then jp = t.title end
        if not en and t.language and t.language:find("英语") then en = t.title end
    end
    if jp then parts[#parts + 1] = jp end
    if en and en ~= jp then parts[#parts + 1] = en end
    local al = md("别名")
    if al then parts[#parts + 1] = al:gsub("[\r\n]+%s*别名:%s*", " · ") end
    local s = table.concat(parts, " · ")
    if s ~= "" then
        ass.push_text(A, PX + 40, PY + 100, ass.truncate_w(s, 20, PW - 150), 20, C.sub, { align = 4 })
    end
end

local function push_infobar(A)
    local bits = {}
    if data.typeDescription then bits[#bits + 1] = data.typeDescription end
    local n = md("话数")
    if n then bits[#bits + 1] = "全 " .. n .. " 话" end
    local d1 = fmt_date_cn(md("放送开始"))
    local d2 = fmt_date_cn(md("播放结束") or md("放送结束"))
    if d1 then bits[#bits + 1] = d1 .. (d2 and (" ~ " .. d2) or "") end
    local wd = md("放送星期")
    if wd then bits[#bits + 1] = (wd:gsub("星期", "周")) .. "放送" end
    local tv = md("播放电视台")
    if tv then bits[#bits + 1] = tv end
    local s = ass.truncate_w(table.concat(bits, " · "), 21, PW - 150)
    if s ~= "" then
        ass.push_text(A, PX + 40, PY + 138, s, 21, C.faint, { align = 4 })
    end
end

local function push_tab_btn(A, idx, x, y, h)
    local s, fs, padx = TABS[idx], 22, 24
    local w = ass.text_width(s, fs) + padx * 2
    local active = (tab == idx)
    local hov = (hover_name == ass.btn_name("tab", idx)) and not active
    if active then
        ass.push_rect(A, x, y, w, h, h / 2, C.accent, "10", C.accent, "00", 1)
        ass.push_text(A, x + w / 2, y + h / 2, s, fs, C.on_accent, { align = 5, bold = true })
    else
        ass.push_rect(A, x, y, w, h, h / 2, hov and C.card_hov or C.card, "00",
            hov and "424A5E" or C.line, "40", 1)
        ass.push_text(A, x + w / 2, y + h / 2, s, fs, hov and C.text or C.sub, { align = 5 })
    end
    ass.add_btn(buttons, x, y, w, h, "tab", idx)
    return w
end

local function push_tabbar(A)
    ass.push_hline(A, PX + 40, PY + 178, PW - 80, C.line, "50")
    local x = PX + 40
    for i in ipairs(TABS) do
        x = x + push_tab_btn(A, i, x, PY + 196, 42) + 12
    end
end

-- 页签 1: 概览 ---------------------------------------------------------------
local function render_overview(A)
    local y = CT
    local cover_x = PX + PW - 40 - ui_cover.W
    cover.draw(A, cover_x, y, buttons, hover_name)

    local full_w = PW - 80                  -- 封面以下的全宽
    local side_w = (cover_x - 24) - (PX + 40) -- 与封面并排时的窄宽

    if cur_ep then
        ass.push_rect(A, PX + 40, y, side_w, 52, 13, C.accent, "10", C.accent, "00", 1)
        ass.push_text(A, PX + 66, y + 26, "▶", 18, C.on_accent, { align = 5, bold = true })
        ass.push_text(A, PX + 92, y + 26,
            ass.truncate_w("正在播放 " .. (cur_ep.episodeTitle or ""), 22, side_w - 120),
            22, C.on_accent, { align = 4, bold = true })
        y = y + 72
    end

    ass.push_text(A, PX + 40, y + 14, "简介", 19, C.accent, { align = 4, bold = true })
    local lw = ass.text_width("简介", 19)
    ass.push_hline(A, PX + 40 + lw + 14, y + 14, side_w - lw - 14, C.line, "40")
    y = y + 40

    -- 与封面并排的行用窄宽, 越过封面底边后转入全宽
    local y_sum = y
    local n_side = math.max(0, math.ceil((CT + ui_cover.H - y_sum) / 32))
    local max_lines = math.max(4, math.floor((CB - y_sum + 8) / 32))
    local lines = ass.wrap_two(data.summary or "暂无简介", 22, side_w + 500, n_side, full_w, max_lines)
    for i, ln in ipairs(lines) do
        ass.push_text(A, PX + 40, y + (i - 1) * 32 + 11, ln, 22, C.body, { align = 4 })
    end
    y = y + #lines * 32 + 16

    local rels = data.relateds or {}
    if #rels > 0 and CB - y >= 76 then
        ass.push_text(A, PX + 40, y + 14, "相关作品", 19, C.accent, { align = 4, bold = true })
        y = y + 40
        local items = {}
        for i, r in ipairs(rels) do
            if i <= 6 then items[#items + 1] = r end
        end
        local function draw(r, x, yy, measure)
            local s = ass.truncate_w(r.animeTitle or "?", 18, 280)
            local rr = rating_num(r.rating)
            if rr then s = s .. fmt(" ★%.1f", rr) end
            local w = ass.text_width(s, 18) + 32
            if not measure then
                local action = r.bangumiId
                    and ("https://bangumi.tv/subject/" .. tostring(r.bangumiId)) or nil
                pill(A, x, yy, s, { fs = 18, h = 34, padx = 16, kind = "link", action = action })
            end
            return w, 34
        end
        ass.flow(A, items, PX + 40, y, full_w, 12, 10, draw)
    end
end

-- 页签 2: 更多 (标签/别名/链接/相关) -------------------------------------------
local function render_more(A)
    local y = CT

    local tags = {}
    for _, t in ipairs(data.tags or {}) do tags[#tags + 1] = tostring(t.name or t) end
    if #tags > 0 then
        ass.push_text(A, PX + 40, y + 14, fmt("标签 · %d", #tags), 19, C.accent, { align = 4, bold = true })
        y = y + 44
        local function draw(t, x, yy, measure)
            local s = "#" .. t
            local w = ass.text_width(s, 18) + 30
            if not measure then
                pill(A, x, yy, s, { fs = 18, h = 34, padx = 15 })
            end
            return w, 34
        end
        y = ass.flow(A, tags, PX + 40, y, PW - 80, 10, 10, draw) + 48
    end

    local al = md("别名")
    if al then
        ass.push_text(A, PX + 40, y + 14, "别名", 19, C.accent, { align = 4, bold = true })
        y = y + 40
        al = al:gsub("[\r\n]+%s*别名:%s*", " · ")
        local lines = ass.wrap_text(al, 20, PW - 80, 2)
        for i, ln in ipairs(lines) do
            ass.push_text(A, PX + 40, y + (i - 1) * 30 + 11, ln, 20, "B9C0CE", { align = 4 })
        end
        y = y + #lines * 30 + 14
    end

    -- 评分 (ratingDetails 各来源评分; JSON 键序不保证, 按预设优先级排序)
    local RATING_RANK = {
        ["Bangumi评分"] = 1,
        ["弹弹play连载中评分"] = 2,
        ["弹弹play完结后评分"] = 3,
        ["Anidb连载中评分"] = 4,
        ["Anidb完结后评分"] = 5,
        ["Anidb评论员评分"] = 6,
    }
    local ratings = {}
    for k, v in pairs(data.ratingDetails or {}) do
        local rv = rating_num(v)
        if rv then ratings[#ratings + 1] = { k = k, v = rv } end
    end
    table.sort(ratings, function(a, b)
        local ra, rb = RATING_RANK[a.k], RATING_RANK[b.k]
        if ra and rb then return ra < rb end
        if ra then return true end
        if rb then return false end
        return a.k < b.k
    end)
    if #ratings > 0 then
        ass.push_text(A, PX + 40, y + 14, fmt("评分 · %d", #ratings), 19, C.accent,
            { align = 4, bold = true })
        y = y + 44
        local function draw(r, x, yy, measure)
            local s = fmt("%s %.1f", r.k:gsub("评分$", ""), r.v)
            local w = ass.text_width(s, 18) + 34
            if not measure then
                pill(A, x, yy, s, { fs = 18, h = 34, padx = 17, fg = C.gold })
            end
            return w, 34
        end
        y = ass.flow(A, ratings, PX + 40, y, PW - 80, 12, 10, draw) + 48
    end

    local links = {}
    local site = md("官方网站")
    if site then
        local u = site:match("^https?://") and site or ("https://" .. site)
        links[#links + 1] = { s = "官网 " .. site:gsub("^https?://", ""), u = u }
    end
    if data.bangumiUrl then links[#links + 1] = { s = "Bangumi 条目", u = data.bangumiUrl } end
    for i, db in ipairs(data.onlineDatabases or {}) do
        if i <= 3 and db.url then links[#links + 1] = { s = db.name or db.url, u = db.url } end
    end
    if #links > 0 and CB - y > 80 then
        ass.push_text(A, PX + 40, y + 14, "外部链接", 19, C.accent, { align = 4, bold = true })
        y = y + 40
        local function draw(l, x, yy, measure)
            local s = ass.truncate_w(l.s, 18, 330)
            local w = ass.text_width(s, 18) + 34
            if not measure then
                pill(A, x, yy, s, { fs = 18, h = 34, padx = 17,
                    fg = "8FB8FF", line = "3A4A66", hfg = "AFCFFF", kind = "link", action = l.u })
            end
            return w, 34
        end
        y = ass.flow(A, links, PX + 40, y, PW - 80, 12, 10, draw) + 48
    end

    local rels = data.relateds or {}
    if #rels > 0 and CB - y >= 76 then
        ass.push_text(A, PX + 40, y + 14, "相关作品", 19, C.accent, { align = 4, bold = true })
        y = y + 40
        local items = {}
        for i, r in ipairs(rels) do
            if i <= 6 then items[#items + 1] = r end
        end
        local function draw(r, x, yy, measure)
            local s = ass.truncate_w(r.animeTitle or "?", 18, 260)
            local rr = rating_num(r.rating)
            if rr then s = s .. fmt(" ★%.1f", rr) end
            local w = ass.text_width(s, 18) + 32
            if not measure then
                local action = r.bangumiId
                    and ("https://bangumi.tv/subject/" .. tostring(r.bangumiId)) or nil
                pill(A, x, yy, s, { fs = 18, h = 34, padx = 16, kind = "link", action = action })
            end
            return w, 34
        end
        ass.flow(A, items, PX + 40, y, PW - 80, 12, 10, draw)
    end
end

-- 页签 3: 制作 ---------------------------------------------------------------
local STAFF_FIELDS = { "原作", "导演", "系列构成", "人物设定", "脚本", "美术监督",
    "色彩设计", "摄影监督", "音响监督", "音乐", "动画制作", "音乐制作人", "企画", "制片人" }

local function render_staff(A)
    local y = CT
    ass.push_text(A, PX + 40, y + 14, "制作人员", 19, C.accent, { align = 4, bold = true })
    y = y + 46
    local lh = 38
    for _, key in ipairs(STAFF_FIELDS) do
        local v = md(key)
        if v and CB - y >= lh then
            ass.push_text(A, PX + 40, y + lh / 2, key, 19, C.faint, { align = 4 })
            ass.push_text(A, PX + 220, y + lh / 2, ass.truncate_w(v, 21, PW - 280), 21, C.body, { align = 4 })
            y = y + lh
        end
    end
end

-- 页签 4: 剧集 ---------------------------------------------------------------
local function page_btn(A, x, y, s, action)
    local w = ass.text_width(s, 18) + 36
    local hov = hover_name == ass.btn_name("page", action)
    ass.push_rect(A, x, y, w, 40, 20, hov and C.card_hov or C.card, "00",
        hov and "4A5468" or C.line, "40", 1)
    ass.push_text(A, x + w / 2, y + 20, s, 18, hov and C.text or C.sub, { align = 5 })
    ass.add_btn(buttons, x, y, w, 40, "page", action)
end

local function render_episodes(A)
    local eps = data.episodes or {}
    local total_pages = math.max(1, math.ceil(#eps / EP_PER_PAGE))
    ep_page = math.min(ep_page, total_pages)
    local y = CT
    ass.push_text(A, PX + 40, y + 14, fmt("剧集列表 · %d 项", #eps), 19, C.accent, { align = 4, bold = true })
    y = y + 46
    local cols, cw, ch, gy = 2, (PW - 96) / 2, 46, 10
    if #eps > 0 then
        ep_grid = { x = PX + 40, y = y, w = PW - 80, h = 7 * (ch + gy) - gy }
    end
    local start_i = (ep_page - 1) * EP_PER_PAGE
    for i = 0, EP_PER_PAGE - 1 do
        local e = eps[start_i + i + 1]
        if not e then break end
        local bx = PX + 40 + (i % cols) * (cw + 16)
        local by = y + math.floor(i / cols) * (ch + gy)
        local is_cur = cur_ep_id ~= nil and tonumber(e.episodeId) == cur_ep_id
        if is_cur then
            ass.push_rect(A, bx, by, cw, ch, 10, C.accent, "10", C.accent, "00", 1)
            ass.push_text(A, bx + 18, by + ch / 2, "▶", 16, C.on_accent, { align = 5, bold = true })
            ass.push_text(A, bx + 40, by + ch / 2,
                ass.truncate_w(e.episodeTitle or "", 21, cw - 60), 21, C.on_accent, { align = 4, bold = true })
        else
            ass.push_rect(A, bx, by, cw, ch, 10, C.card, "00", C.line, "30", 1)
            ass.push_text(A, bx + 18, by + ch / 2,
                ass.truncate_w(e.episodeTitle or "", 21, cw - 40), 21, "B9C0CE", { align = 4 })
        end
    end
    local fy = CB - 44
    page_btn(A, PX + PW / 2 - 190, fy, "‹ 上一页", "ep_prev")
    page_btn(A, PX + PW / 2 + 100, fy, "下一页 ›", "ep_next")
    ass.push_text(A, PX + PW / 2, fy + 20, fmt("%d / %d", ep_page, total_pages), 18, C.faint, { align = 5 })
end

--==============================================================================
-- 主渲染
--==============================================================================
render = function()
    if not shown or not data then return end
    layout()
    buttons = {}
    ep_grid = nil
    cover.clear()

    local A = {}
    ass.push_dim(A, o.dim_alpha, W, H)
    ass.push_rect(A, PX, PY, PW, PH, 22, C.panel, "10", C.panel_ln, "50", 1)
    push_header(A)
    push_subtitle(A)
    push_infobar(A)
    push_tabbar(A)
    if tab == 1 then render_overview(A)
    elseif tab == 2 then render_more(A)
    elseif tab == 3 then render_staff(A)
    else render_episodes(A) end
    ass.push_text(A, W / 2, PY + PH - 34,
        "ESC 退出 · ← / → 切换页签 · 滚轮: 切页签 / 剧集页翻页"
        .. " · 可点击: 页签 / 翻页 / 链接 / ×",
        17, C.faint, { align = 5 })

    if not overlay then
        overlay = mp.create_osd_overlay("ass-events")
        overlay.res_x = o.res_x
        overlay.res_y = o.res_y
        overlay.z = 10
    end
    overlay.data = table.concat(A, "\n")
    overlay:update()
    cover.place()
end

--==============================================================================
-- 交互 (hide 必须先于 show / on_click 定义, 保证闭包捕获的是局部函数)
--==============================================================================
local function window_to_canvas(wx, wy)
    local d = mp.get_property_native("osd-dimensions")
    if not d or not d.w or not d.h or d.w <= 0 or d.h <= 0 then return nil end
    return wx / d.w * o.res_x, wy / d.h * o.res_y
end

local function open_url(url)
    local plat = mp.get_property_native("platform")
    local args
    if plat == "windows" then
        args = { "cmd", "/c", "start", "", url }
    elseif plat == "darwin" then
        args = { "open", url }
    else
        args = { "xdg-open", url }
    end
    mp_utils.subprocess({ args = args, playback_only = false, cancellable = false })
end

local function hide()
    if not shown then return end
    shown = false
    for _, name in ipairs(bound_keys) do
        pcall(mp.remove_key_binding, name)
    end
    bound_keys = {}
    hover_name = ""
    if overlay then overlay:remove() end
    cover.remove()
    mp.commandv("script-message", "osc-show")
end

local function on_click()
    if not shown then return end
    local m = mp.get_property_native("mouse-pos")
    if not m then return end
    local cx, cy = window_to_canvas(m.x, m.y)
    if not cx then return end
    -- 点击面板外的暗化区域也关闭
    if PX and (cx < PX or cx > PX + PW or cy < PY or cy > PY + PH) then
        hide()
        return
    end
    local name = ass.hit_test(buttons, cx, cy)
    if not name then return end
    local kind, arg = name:match("^(.-):(.*)$")
    if kind == "close" then
        hide()
    elseif kind == "tab" then
        local t = tonumber(arg)
        if t and t ~= tab then tab = t render() end
    elseif kind == "page" then
        local tp = math.max(1, math.ceil(#(data.episodes or {}) / EP_PER_PAGE))
        if arg == "ep_prev" then
            ep_page = math.max(1, ep_page - 1) render()
        elseif arg == "ep_next" then
            ep_page = math.min(tp, ep_page + 1) render()
        end
    elseif kind == "link" and arg ~= "" then
        open_url(arg)
    elseif kind == "cover" and arg == "retry" then
        cover.retry()
        render()
    end
end

local function switch_tab(dir)
    if not shown then return end
    tab = ((tab - 1 + dir) % #TABS) + 1
    render()
end

-- 滚轮: 悬在剧集网格内 → 翻页; 其余任何位置 → 切换页签
local function on_wheel(dir)
    if not shown then return end
    if tab == 4 and ep_grid then
        local m = mp.get_property_native("mouse-pos")
        if m then
            local cx, cy = window_to_canvas(m.x, m.y)
            if cx and cx >= ep_grid.x and cx <= ep_grid.x + ep_grid.w
                and cy >= ep_grid.y and cy <= ep_grid.y + ep_grid.h then
                local tp = math.max(1, math.ceil(#(data.episodes or {}) / EP_PER_PAGE))
                local np = ep_page + dir
                if np >= 1 and np <= tp then
                    ep_page = np
                    render()
                end
                return
            end
        end
    end
    switch_tab(dir)
end

local function show(forced_id, silent)
    if shown then return end
    if forced_id and forced_id ~= "" then
        data = load_info(tostring(forced_id))
        cur_ep, cur_ep_id = nil, nil
    elseif not load_for_current() then
        data = nil
    end
    if not data then
        if not silent then
            mp.osd_message("bangumi_info: 未找到元数据 (" .. metadata_root() .. ")", 3)
        end
        return
    end
    tab, ep_page, hover_name = 1, 1, ""
    shown = true
    mp.commandv("script-message", "osc-hide")
    -- 面板打开期间用 forced 绑定, 优先级高于 input.conf / 第三方 OSC 的默认键位
    local binds = {
        { "ESC", "bginfo/esc", hide },
        { "MBTN_LEFT", "bginfo/click", on_click },
        { "MBTN_RIGHT", "bginfo/rclick", hide },
        { "LEFT", "bginfo/left", function() switch_tab(-1) end },
        { "RIGHT", "bginfo/right", function() switch_tab(1) end },
        { "WHEEL_UP", "bginfo/wup", function() on_wheel(-1) end },
        { "WHEEL_DOWN", "bginfo/wdn", function() on_wheel(1) end },
    }
    for _, b in ipairs(binds) do
        mp.add_forced_key_binding(b[1], b[2], b[3])
        bound_keys[#bound_keys + 1] = b[2]
    end
    render()
    cover.load(data)
end

local function toggle()
    if shown then hide() else show() end
end

--==============================================================================
-- 注册
--==============================================================================

local function debug_dump()
    local root = metadata_root()
    msg.info("[面板调试] 元数据根目录: " .. tostring(root))
    local dirs = list_anime_dirs()
    msg.info("[面板调试] 番剧子目录 " .. #dirs .. " 个: " .. table.concat(dirs, ", "))
    -- 列出第一个目录里的文件, 看实际文件名
    if dirs[1] then
        local files = mp_utils.readdir(root .. "/" .. dirs[1])
        if files then
            msg.info("[面板调试] " .. dirs[1] .. " 内文件: " .. table.concat(files, ", "))
        end
    end
    local path = mp.get_property("path")
    msg.info("[面板调试] 当前文件: " .. tostring(path))
    if path then
        local name = path:gsub(".*[\\/]", "")
        local nums = {}
        for n in name:gmatch("%d+") do nums[#nums + 1] = n end
        msg.info("[面板调试] 文件名中的数字: " .. table.concat(nums, ", "))
    end
    mp.osd_message("面板调试信息已写入控制台", 2)
end

local on_message = function(cmd, arg)
    cmd = cmd or ""
    if cmd == "show" then show(arg)
    elseif cmd == "hide" then hide()
    elseif cmd == "debug" then debug_dump()
    else toggle() end
end
mp.register_script_message("bgm-info-panel", on_message)
mp.register_script_message("bangumi-info", on_message)

mp.observe_property("mouse-pos", "native", function()
    if not shown then return end
    local m = mp.get_property_native("mouse-pos")
    if not m then return end
    local cx, cy = window_to_canvas(m.x, m.y)
    if not cx then return end
    local h = ass.hit_test(buttons, cx, cy) or ""
    if h ~= hover_name then
        hover_name = h
        render()
    end
end)

mp.observe_property("osd-dimensions", "native", function()
    if shown then render() end
end)

-- 新文件: 清除上一部作品的精确匹配; 面板若开着则关闭 (数据已过期)
mp.register_event("file-loaded", function()
    current.anime_id, current.episode_id = nil, nil
    if shown then hide() end
    if o.auto_show and load_for_current() and cur_ep then show(nil, true) end
end)

mp.register_event("shutdown", hide)

--==============================================================================
-- 集成接口 (main.lua 调用)
--==============================================================================
local M = {}

function M.notify_match(anime_id, episode_id)
    current.anime_id = anime_id and tostring(anime_id) or nil
    current.episode_id = episode_id and tostring(episode_id) or nil
    if o.auto_show and not shown and current.anime_id then
        if load_for_current() and cur_ep then show(nil, true) end
    end
end

M.show = function(forced_id, silent) show(forced_id, silent) end
M.hide = hide
M.toggle = toggle
return M
