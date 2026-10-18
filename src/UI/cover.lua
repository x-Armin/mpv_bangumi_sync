-- 封面: 下载 URL → mpv/ffmpeg 解码为 BGRA → 圆角+面板底色边距
-- → 永久缓存 <metadata>/<animeId>/<animeId>-cover.bgra → overlay-add 到面板封面槽位
-- (命中缓存直接读取; 仅文件缺失时才请求图片 URL)

local mp = require "mp"
local msg = require "mp.msg"
local mp_utils = require "mp.utils"

local paths = require "src.paths"
local ass = require "src.UI.ass_board"

local M = {}

local file_info = mp_utils.file_info or mp_utils.fileinfo

-- 封面尺寸 (ASS 画布单位)
M.W, M.H = 280, 420       -- 2:3
M.GAP = 6                 -- 图片边缘与描边空隙
M.R = 16                  -- 圆角半径
M.BW = M.W + 2 * M.GAP
M.BH = M.H + 2 * M.GAP
M.BYTES = M.BW * M.BH * 4 -- 成品位图字节数 (缓存校验用)

local function fmt(...) return string.format(...) end

-- 从 info JSON 提取封面 URL (兼容多种字段名)
function M.get_url(data)
    if not data then return nil end
    local u = data.coverUrl or data.cover_url or data.cover or data.imageUrl or data.image
    if type(u) == "table" then u = u.url or u.large or u.medium or u.common end
    return (type(u) == "string" and u ~= "") and u or nil
end

local function resolve_mpv_path(cfg)
    if cfg ~= "mpv" and cfg ~= "" then return cfg end
    local fp = mp.get_property_native("user-data/frontend/process-path")
    if type(fp) == "string" and fp ~= "" then return fp end -- mpv.net 等前端
    return "mpv"
end

-- 把 W×H 原始 BGRA 加上 "面板底色边距 + 圆角(1px 羽化)", 输出 (W+2m)×(H+2m)
local function cover_round(src_path, dst_path, w, h, m, r, panel_hex)
    local f = io.open(src_path, "rb")
    if not f then return false end
    local raw = f:read("*a")
    f:close()
    if #raw ~= w * h * 4 then return false end

    local pr = tonumber(panel_hex:sub(1, 2), 16)
    local pg = tonumber(panel_hex:sub(3, 4), 16)
    local pb = tonumber(panel_hex:sub(5, 6), 16)
    local BW, BH = w + m * 2, h + m * 2
    local panel_row = string.char(pb, pg, pr, 0xFF):rep(BW)

    local rows = {}
    for iy = -m, h + m - 1 do
        if iy < 0 or iy >= h then
            rows[#rows + 1] = panel_row
        else
            local cells = {}
            for ix = -m, w + m - 1 do
                local b, g, r8
                if ix < 0 or ix >= w then
                    b, g, r8 = pb, pg, pr
                else
                    local off = (iy * w + ix) * 4 + 1
                    b, g, r8 = raw:byte(off, off + 2)
                    local cx, cy = 0, 0
                    if ix < r and iy < r then cx, cy = r - ix, r - iy
                    elseif ix >= w - r and iy < r then cx, cy = ix - (w - 1 - r), r - iy
                    elseif ix < r and iy >= h - r then cx, cy = r - ix, iy - (h - 1 - r)
                    elseif ix >= w - r and iy >= h - r then cx, cy = ix - (w - 1 - r), iy - (h - 1 - r) end
                    if cx > 0 and cy > 0 then
                        local cov = 0.5 - (math.sqrt(cx * cx + cy * cy) - r)
                        if cov <= 0 then b, g, r8 = pb, pg, pr
                        elseif cov < 1 then
                            b = math.floor(b * cov + pb * (1 - cov) + 0.5)
                            g = math.floor(g * cov + pg * (1 - cov) + 0.5)
                            r8 = math.floor(r8 * cov + pr * (1 - cov) + 0.5)
                        end
                    end
                end
                cells[#cells + 1] = string.char(b, g, r8, 0xFF)
            end
            rows[#rows + 1] = table.concat(cells)
        end
    end

    local fo = io.open(dst_path, "wb")
    if not fo then return false end
    fo:write(table.concat(rows))
    fo:close()
    return true
end

-- opts: {root_dir, panel_color, cover_fill("yes"/"no"), mpv_path,
--        overlay_id, res_x, res_y, on_redraw(fn)}
function M.create(opts)
    opts = opts or {}
    local root_dir = opts.root_dir or ""
    local panel_hex = opts.panel_color or ass.C.panel
    local cover_fill = opts.cover_fill ~= "no"
    local mpv_path_opt = opts.mpv_path or "mpv"
    local ov_id = opts.overlay_id or 44
    local on_redraw = opts.on_redraw or function() end

    local self = {
        anime_id = nil, url = nil, path = nil, data = nil,
        loading = false, failed = false,
        slot = nil, -- draw() 时记录的 ASS 画布槽位 {x,y,w,h}
    }

    -- 封面 URL 兼容:
    --   A 格式: data.imageUrl = "https://...jpg" (字符串)
    --   B 格式 (Bangumi subject): data.images = { large=..., medium=..., common=..., small=..., grid=... }
    local function cover_url(data)
        if type(data) ~= "table" then return nil end
        if type(data.imageUrl) == "string" and data.imageUrl ~= "" then
            return data.imageUrl
        end
        local im = data.images
        if type(im) == "table" then
            -- 优先高清, 逐级降级; 都不匹配时兜底取任意一个字符串值
            for _, k in ipairs({ "large", "medium", "common", "small", "grid" }) do
                local u = im[k]
                if type(u) == "string" and u ~= "" then return u end
            end
            for _, u in pairs(im) do
                if type(u) == "string" and u ~= "" then return u end
            end
        end
        return nil
    end

    -- 番剧 ID 兼容: A 格式 animeId / B 格式 id (bangumiId 由 normalize 补, 此处再兜一层)
    local function anime_id_of(data)
        if type(data) ~= "table" then return nil end
        local id = data.animeId or data.bangumiId or data.id
        if type(id) == "number" or (type(id) == "string" and id:match("^%d+$")) then
            return tostring(id)
        end
        return nil
    end

    local function root_path_for(aid)
        return mp_utils.join_path(mp_utils.join_path(root_dir, aid), aid .. "-cover.bgra")
    end

    local function finalize(raw_path, dst, aid)
        if self.anime_id ~= aid then os.remove(raw_path) return end
        local ok = cover_round(raw_path, dst, M.W, M.H, M.GAP, M.R, panel_hex)
        os.remove(raw_path)
        local fi = ok and file_info(dst) or nil
        if fi and fi.size == M.BYTES then
            self.path, self.loading = dst, false
            msg.info("封面已缓存: " .. dst)
        else
            self.loading, self.failed = false, true
            msg.warn("封面处理失败: " .. tostring(dst))
        end
        on_redraw()
    end

    function self.load(data)
        self.data = data
        local url = cover_url(data)
        msg.error(url)
        if not url then return end
        local aid = anime_id_of(data)

        if self.anime_id == aid then return end
        self.anime_id, self.url = aid, url
        self.path, self.failed, self.loading = nil, false, true

        if cache_dir == "" then
            self.loading, self.failed = false, true
            return
        end
        paths.ensure_dir(mp_utils.join_path(root_dir, aid))

        local dst = root_path_for(aid)
        local raw = dst .. ".raw.bgra"

        local fi = file_info(dst)
        if fi and fi.size == M.BYTES then
            self.path, self.loading = dst, false
            on_redraw()
            return
        end

        local vf
        if cover_fill then
            vf = fmt("scale=w=%d:h=%d:force_original_aspect_ratio=increase,crop=%d:%d,format=bgra",
                M.W, M.H, M.W, M.H)
        else
            vf = fmt("scale=w=%d:h=%d:force_original_aspect_ratio=decrease,"
                .. "pad=w=%d:h=%d:x=-1:y=-1:color=0x%s,format=bgra",
                M.W, M.H, M.W, M.H, panel_hex)
        end

        local args = {
            resolve_mpv_path(mpv_path_opt), "--no-config", "--msg-level=all=no",
            "--really-quiet", "--no-terminal", "--frames=1", "--hwdec=no",
            "--no-sub", "--no-audio", "--ytdl=no", "--network-timeout=15",
            "--vf=" .. vf, "--ovc=rawvideo", "--of=image2", "--ofopts=update=1",
            "--o=" .. raw, "--", url,
        }
        mp.command_native_async({ name = "subprocess", playback_only = false,
            capture_stdout = true, args = args }, function(ok, result)
            if self.anime_id ~= aid then os.remove(raw) return end
            local status = (ok and result and result.status) or -1
            local fout = file_info(raw)
            if status == 0 and fout and fout.size == M.W * M.H * 4 then
                finalize(raw, dst, aid)
                return
            end
            -- mpv 失败 → ffmpeg 兜底
            local fvf = cover_fill
                and fmt("scale=w=%d:h=%d:force_original_aspect_ratio=increase,crop=%d:%d", M.W, M.H, M.W, M.H)
                or fmt("scale=w=%d:h=%d:force_original_aspect_ratio=decrease,"
                    .. "pad=w=%d:h=%d:x=-1:y=-1:color=0x%s", M.W, M.H, M.W, M.H, panel_hex)
            local fargs = { "ffmpeg", "-y", "-loglevel", "error", "-i", url,
                "-vf", fvf, "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "bgra", raw }
            mp.command_native_async({ name = "subprocess", playback_only = false,
                capture_stdout = true, args = fargs }, function(ok2, res2)
                if self.anime_id ~= aid then os.remove(raw) return end
                local st2 = (ok2 and res2 and res2.status) or -1
                local f2 = file_info(raw)
                if st2 == 0 and f2 and f2.size == M.W * M.H * 4 then
                    finalize(raw, dst, aid)
                else
                    os.remove(raw)
                    self.loading, self.failed = false, true
                    msg.warn(fmt("封面下载失败 (mpv=%s, ffmpeg=%s): %s",
                        tostring(status), tostring(st2), url))
                    on_redraw()
                end
            end)
        end)
    end

    -- 绘制封面槽位/占位, 并记录槽位供 place() 使用
    function self.draw(A, x, y, buttons, hover_name)
        self.slot = nil
        local fi = self.path and file_info(self.path) or nil
        if fi and fi.size == M.BYTES then
            ass.push_rect(A, x - M.GAP, y - M.GAP, M.BW, M.BH, M.R + M.GAP,
                panel_hex, "00", ass.C.line, "60", 2)
            self.slot = { x = x, y = y, w = M.W, h = M.H }
            return
        end
        ass.push_rect(A, x, y, M.W, M.H, 10, "20242F", "00", ass.C.line, "50", 1)
        if self.failed then
            ass.push_text(A, x + M.W / 2, y + M.H / 2 - 14, "封面加载失败", 18, ass.C.faint, { align = 5 })
            ass.push_text(A, x + M.W / 2, y + M.H / 2 + 16, "点击重试", 16, ass.C.accent, { align = 5 })
            ass.add_btn(buttons, x, y, M.W, M.H, "cover", "retry")
        else
            ass.push_text(A, x + M.W / 2, y + M.H / 2, "封面加载中…", 18, ass.C.faint, { align = 5 })
        end
    end

    function self.place()
        if not self.slot then
            pcall(mp.command_native, { "overlay-remove", ov_id })
            return
        end
        local fi = self.path and file_info(self.path) or nil
        if not (fi and fi.size == M.BYTES) then return end
        local d = mp.get_property_native("osd-dimensions")
        if not d or not d.w or d.w <= 0 or not d.h or d.h <= 0 then return end
        local s = self.slot
        local x = math.floor((s.x - M.GAP) / opts.res_x * d.w + 0.5)
        local y = math.floor((s.y - M.GAP) / opts.res_y * d.h + 0.5)
        local dw = math.floor(M.BW / opts.res_x * d.w + 0.5)
        local dh = math.floor(M.BH / opts.res_y * d.h + 0.5)
        if dw < 1 or dh < 1 then return end
        local ok = pcall(mp.command_native, { "overlay-add", ov_id, x, y, self.path,
            0, "bgra", M.BW, M.BH, 4 * M.BW, dw, dh })
        if not ok then
            pcall(mp.command_native, { "overlay-add", ov_id, x, y, self.path,
                0, "bgra", M.BW, M.BH, 4 * M.BW })
        end
    end

    function self.remove()
        pcall(mp.command_native, { "overlay-remove", ov_id })
    end

    function self.clear()
        self.slot = nil
    end

    function self.retry()
        self.anime_id, self.failed = nil, false
        if self.data then self.load(self.data) end
    end

    return self
end

return M
