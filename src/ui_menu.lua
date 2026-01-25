local utils = require "src.utils"
local mp_utils = require "mp.utils"
local title_guess = require "src.title_guess"

local M = {}

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
    title = "没有结果，手动搜索",
    value = { "script-message-to", mp.get_script_name(), "bgm-open-search" },
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

local function build_info_menu_props(state)
  local CurrentEpisodeInfo = state.CurrentEpisodeInfo
  local EpisodeStatusText = state.EpisodeStatusText
  local EpisodeProgressText = state.EpisodeProgressText
  local title_guess_mod = title_guess

  local title = (CurrentEpisodeInfo and CurrentEpisodeInfo.animeTitle) or title_guess_mod.get_default_search_query() or "未获取"
  local episode_title = (CurrentEpisodeInfo and CurrentEpisodeInfo.episodeTitle) or "未获取"
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
      keep_open = true},
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
    {
      title = "打开Bangumi",
      value = { "script-message", "open-bangumi-url" },
      selectable = true},
  }
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
