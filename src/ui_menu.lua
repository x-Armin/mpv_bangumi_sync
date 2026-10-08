local utils = require "src.utils"
local mp_utils = require "mp.utils"
local title_guess = require "src.title_guess"
local episode_status = require "src.services.episode_status"

local M = {}

local PLAIN_INFO_DURATION = 5
local PlainInfoVisible = false
local PlainInfoTimer = nil
local EpisodeListMenu = nil
local EpisodeListRequest = nil

function M.clear_episode_list()
  EpisodeListMenu = nil
  EpisodeListRequest = nil
end

local function non_empty(value)
  if value == nil then
    return nil
  end
  value = tostring(value):match("^%s*(.-)%s*$")
  return value ~= "" and value or nil
end

function M.format_menu_item(message)
  return {
    title = message,
    value = "",
    italic = true,
    keep_open = true,
    selectable = false,
    align = "center",
  }
end

function M.open_uosc_menu(props, submenu_id)
  local json_props = utils.format_json(props)
  if submenu_id then
    mp.commandv("script-message-to", "uosc", "open-menu", json_props, submenu_id)
  else
    mp.commandv("script-message-to", "uosc", "open-menu", json_props)
  end
end

function M.update_uosc_menu(props)
  local json_props = utils.format_json(props)
  mp.commandv("script-message-to", "uosc", "update-menu", json_props)
end

function M.open_anime_search_menu(query)
  local menu_props = {
    type = "menu_bgm_anime",
    title = "输入番剧名称",
    search_style = "palette",
    search_debounce = "submit",
    search_suggestion = query,
    on_search = { "script-message-to", mp.get_script_name(), "bgm-search-anime" },
    footnote = "使用 enter 或 ctrl+enter 进行搜索",
    items = {},
  }
  M.open_uosc_menu(menu_props)
end

function M.open_subject_search_menu(query)
  local menu_props = {
    type = "menu_bgm_subject",
    title = "搜索Bangumi条目",
    search_style = "palette",
    search_debounce = "submit",
    search_suggestion = query,
    on_search = { "script-message-to", mp.get_script_name(), "bgm-search-subjects" },
    footnote = "使用 enter 或 ctrl+enter 进行搜索",
    items = {},
  }
  M.open_uosc_menu(menu_props)
end

function M.open_manual_match_source_menu()
  local menu_props = {
    type = "menu_bgm_manual_source",
    title = "选择手动匹配来源",
    search_style = "disabled",
    items = {
      {
        title = "弹弹play搜索",
        value = { "script-message-to", mp.get_script_name(), "bgm-open-dandan-search" },
        selectable = true,
      },
      {
        title = "Bangumi搜索",
        value = { "script-message-to", mp.get_script_name(), "bgm-open-bgm-subject-search" },
        selectable = true,
      },
    },
  }
  M.open_uosc_menu(menu_props)
end

function M.open_match_menu(matches)
  local items = {}
  for i, match in ipairs(matches or {}) do
    items[i] = {
      title = string.format("%d. %s - %s", i, match.animeTitle, match.episodeTitle),
      value = { "script-message-to", mp.get_script_name(), "bgm-select-match", match.episodeId },
      keep_open = false,
      selectable = true,
    }
  end
  items[#items + 1] = {
    title = "没有结果，手动匹配",
    value = { "script-message-to", mp.get_script_name(), "bgm-open-search-source" },
    keep_open = false,
    selectable = true,
  }
  local menu_props = {
    type = "menu_bgm_match",
    title = "请选择匹配结果",
    search_style = "disabled",
    items = items,
  }
  M.open_uosc_menu(menu_props)
end

function M.open_episode_status_menu(state)
  state = state or {}
  local current_status = state.EpisodeStatusText or "未获取"
  local items = {
    {
      title = "标记为已看",
      hint = current_status == "已看" and "当前" or nil,
      value = { "script-message-to", mp.get_script_name(), "bgm-set-episode-status", "2" },
      keep_open = false,
      selectable = true,
    },
    {
      title = "标记为未看",
      hint = current_status == "未看" and "当前" or nil,
      value = { "script-message-to", mp.get_script_name(), "bgm-set-episode-status", "0" },
      keep_open = false,
      selectable = true,
    },
    {
      title = "返回",
      value = { "script-message-to", mp.get_script_name(), "bgm-back-info-menu" },
      keep_open = false,
      selectable = true,
    },
  }
  M.open_uosc_menu({
    type = "menu_bgm_status",
    title = "修改单集状态",
    search_style = "disabled",
    items = items,
  })
end

local function build_info_menu_props(state)
  local CurrentEpisodeInfo = state.CurrentEpisodeInfo
  local EpisodeStatusText = state.EpisodeStatusText or "未获取"
  local EpisodeProgressText = state.EpisodeProgressText or "未获取"
  local IsNetworkPath = state.IsNetworkPath == true
  local NetworkModeText = state.NetworkModeText or ""
  local NetworkModeIcon = "sync_alt"
  local AutoMarkText = state.AutoMarkText or "开启"
  local AutoMarkIcon = (AutoMarkText == "开启") and "toggle_on" or "toggle_off"
  local title_guess_mod = title_guess

  local title = non_empty(CurrentEpisodeInfo and CurrentEpisodeInfo.animeTitle)
    or non_empty(title_guess_mod.get_default_search_query())
    or "未获取"
  local episode_title = non_empty(CurrentEpisodeInfo and CurrentEpisodeInfo.episodeTitle) or "未获取"
  local episode_ep = CurrentEpisodeInfo and CurrentEpisodeInfo.episodeEp
  if type(episode_ep) == "number" and episode_ep > 0 then
    episode_title = string.format("第%s话  %s", tostring(episode_ep), episode_title)
  end
  local status_title = "状态：" .. EpisodeStatusText
  local status_italic = false
  local status_muted = false
  if EpisodeStatusText == "已看" then
    status_title = "状态：已看 ✔"
  elseif EpisodeStatusText == "未看" then
    status_italic = true
    status_muted = true
  end
  local items = {
    {
      title = episode_title,
      hint  = "播放中",
      value = { "script-message-to", mp.get_script_name(), "bgm-noop" },
      keep_open = true },
    {
      title = status_title,
      italic = status_italic, muted = status_muted,
      value = { "script-message-to", mp.get_script_name(), "bgm-noop" },
      keep_open = true,
      actions = {
        { name = "edit_status", icon = "edit", label = "修改当前集状态" },
      },
      actions_place = "inside" },
    {
      title = "进 度  " .. EpisodeProgressText,
      hint = "查看单集 ›",
      value = { "script-message-to", mp.get_script_name(), "bgm-open-episode-list" },
      selectable = true,
      keep_open = true },
    {
      title = "手动匹配",
      value = { "script-message-to", mp.get_script_name(), "bgm-open-search-from-info" },
      selectable = true,
      keep_open = false,
      actions = {
        { name = "refresh", icon = "refresh", label = "根据当前匹配的番剧Id，重新获取单集信息" },
      },
      actions_place = "inside" },
    {
      title = "自动点格子：" .. AutoMarkText,
      value = { "script-message-to", mp.get_script_name(), "bgm-toggle-auto-mark" },
      selectable = true,
      keep_open = true,
      actions = {
        { name = "toggle_auto_mark", icon = AutoMarkIcon, label = "切换自动点格子" },
      },
      actions_place = "inside" },
    {
      title = "打开Bangumi",
      value = { "script-message", "open-bangumi-url" },
      selectable = true},
  }
  if EpisodeListMenu then
    -- 保留进度栏的位置与文字，由 uosc 在右侧展开子菜单。
    EpisodeListMenu.title = items[3].title
    items[3] = EpisodeListMenu
  end
  if IsNetworkPath then
    table.insert(items, #items, {
      title = "匹配模式：" .. (NetworkModeText ~= "" and NetworkModeText or "未知"),
      value = { "script-message-to", mp.get_script_name(), "bgm-noop" },
      selectable = true,
      keep_open = true,
      actions = {
        { name = "toggle_network_mode", icon = NetworkModeIcon, label = "切换匹配模式" },
      },
      actions_place = "inside",
    })
  end
  return {
    type = "menu_bgm_info",
    title = title,
    search_style = "disabled",
    callback = { mp.get_script_name(), "bgm-info-menu-event" },
    on_close = EpisodeListRequest and {
      "script-message-to", mp.get_script_name(), "bgm-cancel-episode-list", tostring(EpisodeListRequest),
    } or nil,
    items = items,
  }
end

function M.show_episode_list(state, episodes_data, message, update, preserve_selection)
  local current = state.CurrentEpisodeInfo or {}
  local local_data = state.EpisodesData or {}
  local statuses = {}
  for _, item in ipairs(local_data.data or {}) do
    if item.episode and item.episode.id then
      statuses[tostring(item.episode.id)] = item.type
    end
  end
  local episodes = {}
  for _, item in ipairs(episodes_data and episodes_data.data or {}) do
    if type(item.episode) == "table" then
      episodes[#episodes + 1] = item
    end
  end
  table.sort(episodes, function(a, b)
    local x, y = a.episode, b.episode
    local xt, yt = tonumber(x.type) or 0, tonumber(y.type) or 0
    if xt ~= yt then return xt < yt end
    local xs, ys = tonumber(x.sort) or tonumber(x.ep) or 0, tonumber(y.sort) or tonumber(y.ep) or 0
    if xs ~= ys then return xs < ys end
    return (tonumber(x.id) or 0) < (tonumber(y.id) or 0)
  end)
  local items = {{
    title = "返回番剧信息",
    value = {"script-binding", "uosc/menu-back"},
    keep_open = true,
  }}
  local types = {[1] = "SP", [2] = "OP", [3] = "ED", [4] = "预告", [5] = "MAD", [6] = "其他"}
  local selected_index = 1
  for _, item in ipairs(episodes) do
    local ep = item.episode
    local ep_type = tonumber(ep.type) or 0
    local number = tostring(ep.sort or ep.ep or "?")
    local label = ep_type == 0 and ("第" .. number .. "话")
      or ((types[ep_type] or "其他") .. " " .. number)
    local is_current = current.bgmEpisodeId ~= nil and tostring(ep.id) == tostring(current.bgmEpisodeId)
    local status = statuses[tostring(ep.id)] or item.type
    -- 与信息窗口一致：条目看过时正片视为已看，SP 等保留各自状态。
    if ep_type == 0 and episode_status.collection_is_watched(local_data.collection) then status = 2 end
    items[#items + 1] = {
      title = label .. "  " .. (non_empty(ep.name_cn) or non_empty(ep.name) or "暂无标题"),
      hint = (is_current and "播放中 · " or "") .. episode_status.map_status(tonumber(status)),
      active = is_current,
      bold = is_current,
      value = {"script-message-to", mp.get_script_name(), "bgm-noop"},
      keep_open = true,
    }
    if is_current then selected_index = #items end
  end
  if #episodes == 0 then
    items[#items + 1] = M.format_menu_item(message or "暂无单集信息")
  end
  if state.EpisodeListFailed then
    items[#items + 1] = {
      title = "重新加载",
      value = {"script-message-to", mp.get_script_name(), "bgm-open-episode-list"},
      keep_open = true,
    }
  end
  EpisodeListMenu = {
    id = "menu_bgm_episode_list",
    hint = episodes_data and ("共 " .. #episodes .. " 集") or "单集列表",
    search_style = "on_demand",
    footnote = "滚轮 / ↑↓ 浏览 · Ctrl+F 搜索 · ← 返回 · Esc 关闭",
    items = items,
  }
  EpisodeListRequest = state.EpisodeListRequest
  local props = build_info_menu_props(state)
  if update then
    -- 原位更新，用户在加载期间返回主菜单时不会被强行带回列表。
    M.update_uosc_menu(props)
  else
    M.open_uosc_menu(props, EpisodeListMenu.id)
  end
  if not preserve_selection then
    mp.commandv("script-message-to", "uosc", "select-menu-item",
      "menu_bgm_info", tostring(selected_index), EpisodeListMenu.id)
  end
end

local function build_plain_info_text(state)
  local current_episode_info = state.CurrentEpisodeInfo or {}
  local title = non_empty(current_episode_info.animeTitle) or "未获取"
  local episode_title = non_empty(current_episode_info.episodeTitle)
  local episode_ep = tonumber(current_episode_info.episodeEp)
  if not episode_ep or episode_ep <= 0 then
    local episode_id = tonumber(current_episode_info.episodeId)
    episode_ep = episode_id and episode_id % 10000 or nil
  end
  local status = non_empty(state.EpisodeStatusText) or "未获取"
  local progress = non_empty(state.EpisodeProgressText) or "未获取"
  local episode_text = string.format(
    "%s 第 %s 话",
    title,
    tostring((episode_ep and episode_ep > 0) and episode_ep or "?")
  )
  if episode_title then
    episode_text = episode_text .. " " .. episode_title
  end

  return string.format(
    "%s\n状态: %s\n进度: %s",
    episode_text,
    status,
    progress
  )
end

local function close_plain_info_text()
  if PlainInfoTimer then
    PlainInfoTimer:kill()
    PlainInfoTimer = nil
  end
  PlainInfoVisible = false
  mp.osd_message("", 0)
end

local function toggle_plain_info_text(state)
  if PlainInfoVisible then
    close_plain_info_text()
    return
  end

  PlainInfoVisible = true
  mp.osd_message(build_plain_info_text(state), PLAIN_INFO_DURATION)
  PlainInfoTimer = mp.add_timeout(PLAIN_INFO_DURATION, function()
    PlainInfoVisible = false
    PlainInfoTimer = nil
  end)
end

function M.open_info_menu(state)
  if not state.UoscAvailable then
    toggle_plain_info_text(state)
    return
  end
  M.clear_episode_list()
  M.open_uosc_menu(build_info_menu_props(state))
end

function M.update_info_menu(state)
  if not state.UoscAvailable then
    return
  end
  if EpisodeListMenu and type(state.EpisodesData) == "table"
    and type(state.EpisodesData.data) == "table" then
    -- 刷新或标记后的缓存变化同步到已展开的列表，保留浏览位置。
    state.EpisodeListRequest = EpisodeListRequest
    M.show_episode_list(state, state.EpisodesData, nil, true, true)
    return
  end
  M.update_uosc_menu(build_info_menu_props(state))
end


return M
