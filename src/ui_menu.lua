local utils = require "src.utils"
local mp_utils = require "mp.utils"
local title_guess = require "src.title_guess"

local M = {}

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

function M.open_uosc_menu(props)
  local json_props = utils.format_json(props)
  mp.commandv("script-message-to", "uosc", "open-menu", json_props)
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
  local EpisodeStatusText = state.EpisodeStatusText
  local EpisodeProgressText = state.EpisodeProgressText
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
    episode_title = string.format("第%d话  %s", episode_ep, episode_title)
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
      value = { "script-message-to", mp.get_script_name(), "bgm-noop" },
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
    -- {
    --   title = "自动点格子",
    --   icon = AutoMarkIcon,
    --   value = { "script-message-to", mp.get_script_name(), "bgm-toggle-auto-mark" },
    --   selectable = true,
    --   keep_open = true },
    {
      title = "打开Bangumi",
      value = { "script-message", "open-bangumi-url" },
      selectable = true},
  }
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
    items = items,
  }
end

function M.open_info_menu(state)
  if not state.UoscAvailable then
    mp.osd_message("未安装uosc，无法显示番剧信息窗口", 3)
    return
  end
  M.open_uosc_menu(build_info_menu_props(state))
end

function M.update_info_menu(state)
  if not state.UoscAvailable then
    return
  end
  M.update_uosc_menu(build_info_menu_props(state))
end


return M
