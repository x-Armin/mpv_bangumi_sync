require "src.config"
local bgm = require "src.facade.bgm"
local db = require "src.db"
local utils = require "src.utils"
local episode_status = require "src.services.episode_status"
local title_guess = require "src.title_guess"
local input = require "mp.input"
local ui_menu = require "src.ui_menu"

-- global variables
AnimeInfo = nil
CurrentEpisodeInfo = nil
EpisodeStatusText = "未获取"
EpisodeProgressText = "未获取"
UpdateEpisodeTimer = nil
BangumiCollectionReady = false
EpisodesReady = false
MatchResults = nil
UoscAvailable = false

local function prune_db_on_start()
  local removed = db.prune({max_age_days = 30, remove_missing = false})
  if removed and removed > 0 then
    mp.msg.verbose("Pruned db records: " .. tostring(removed))
  end
end

prune_db_on_start()

mp.register_script_message("uosc-version", function()
  UoscAvailable = true
end)

-- UI/menu helpers moved to src/ui_menu.lua (ui_menu)

local function reset_globals()
  AnimeInfo = nil
  CurrentEpisodeInfo = nil
  EpisodeStatusText = "未获取"
  EpisodeProgressText = "未获取"
  if UpdateEpisodeTimer then
    UpdateEpisodeTimer:kill()
    UpdateEpisodeTimer = nil
  end
  BangumiCollectionReady = false
  EpisodesReady = false
  MatchResults = nil
end

local function update_episode_status_from_cache(episodes_data)
  local result = episode_status.compute(CurrentEpisodeInfo, episodes_data)
  if not result then
    return false
  end

  local progress = result.progress or {}
  EpisodeProgressText = string.format("%d / %d", progress.watched or 0, progress.total or 0)
  EpisodeStatusText = episode_status.map_status(result.status_value)
  if result.episode_info then
    CurrentEpisodeInfo = result.episode_info
  end
  return true
end

local function init_after_bangumi_id()
  bgm.update_bangumi_collection().async {
    resp = function(resp)
      if resp.update_message then
        mp.osd_message(resp.update_message, 3)
        mp.msg.info("Bangumi 收藏状态更新成功:", resp.update_message)
      else
        mp.msg.verbose "收藏状态未改变"
      end
      BangumiCollectionReady = true
    end,
    err = function(err)
      mp.msg.error("更新Bangumi条目失败:", err)
    end,
  }
  UpdateEpisodeTimer = mp.add_periodic_timer(5, function()
    local current_time = mp.get_property_number "time-pos"
    local total_time = mp.get_property_number "duration"
    if not current_time or not total_time then
      return
    end
    local ratio = current_time / total_time
    local threshold = Options.progress_mark_threshold or 0.9
    if ratio < threshold then
      return
    end
    if not (BangumiCollectionReady and EpisodesReady) then
      mp.msg.verbose "Bangumi 收藏或剧集未更新或更新失败，跳过更新"
      return
    end
    if UpdateEpisodeTimer then
      UpdateEpisodeTimer:kill()
      UpdateEpisodeTimer = nil
      bgm.update_episode().async {
        resp = function(data)
          local updated = update_episode_status_from_cache(data and data.episodes_data or nil)
          if updated then
            EpisodesReady = true
          end
          if data.skipped then
            mp.msg.info "同步Bangumi追番记录进度成功（无需更新）"
            mp.osd_message("同步Bangumi追番记录进度成功（无需更新）")
          else
            mp.msg.info "同步Bangumi追番记录进度成功"
            mp.osd_message("同步Bangumi追番记录进度成功")
            EpisodeStatusText = "已看"
          end
        end,
        err = function(err)
          mp.msg.error("更新当前集信息失败:", err)
          mp.osd_message("同步Bangumi追番记录进度失败", 3)
        end,
      }
    else
      mp.msg.error "Unexpected value: UpdateEpisodeTimer = nil"
      return
    end
  end)
end

local function init(episode_id, opts)
  local force_refresh = opts == true or (type(opts) == "table" and opts.force_refresh)
  reset_globals()
  local source = episode_id and "manual" or "auto"
  bgm.sync_context({
    episode_id = episode_id,
    force_refresh = force_refresh,
    source = source,
  }).async {
    resp = function(result)
      if result and result.status == "select" and result.matches and #result.matches > 1 then
        mp.msg.info "匹配结果不唯一，请手动选择"
        mp.osd_message("匹配结果不唯一，请手动选择", 3)
        MatchResults = result.matches
        return
      end

      if not result or result.status ~= "ok" or not result.context then
        mp.msg.error "获取番剧元信息失败"
        return
      end

      CurrentEpisodeInfo = result.context.episode_info
      local anime_info = result.context.anime_info or {}
      anime_info.bgm_id = result.context.bgm_id
      anime_info.bgm_url = result.context.bgm_url
      AnimeInfo = anime_info
      EpisodesReady = update_episode_status_from_cache(result.context.episodes)

      mp.msg.verbose(
        "Bangumi ID:",
        AnimeInfo.bgm_id,
        "Bangumi Url:",
        AnimeInfo.bgm_url
      )
      init_after_bangumi_id()
    end,
    err = function(err)
      if err and err.error == "VideoPathError" then
    if err.reason == "NotInStorage" then
      mp.msg.verbose("视频不在配置的存储路径内，跳过初始化")
      return
        end
        if err.reason == "InvalidPath" then
          mp.msg.error("视频路径无效")
          return
        end
      end
      mp.msg.error("获取番剧元信息失败")
    end,
  }
end

mp.register_event("file-loaded", function()
  if utils.is_protocol(mp.get_property "path") then
    mp.msg.verbose("Skipping init for protocol:", mp.get_property "path")
    return
  end
  init()
end)

-- key bindings

local key_bindings = {
  ["Alt+o"] = { "open-bangumi-info" },
}

for key, binding in pairs(key_bindings) do
  table.insert(binding, 1, "script-message")
  local desc = table.concat(binding, "", 2)
  mp.msg.verbose("key:", key, "binding:", binding[2], "desc:", desc)
  mp.add_key_binding(key, desc, function()
    mp.command_native(binding)
  end)
end

-- script messages

mp.register_script_message("open-bangumi-url", function()
  if not AnimeInfo or not AnimeInfo.bgm_url then
    mp.msg.error "未匹配到番剧信息"
    return
  end
  bgm.open_url(AnimeInfo.bgm_url).execute()
end)

mp.register_script_message("open-bangumi-info", function()
  ui_menu.open_info_menu({
    UoscAvailable = UoscAvailable,
    CurrentEpisodeInfo = CurrentEpisodeInfo,
    EpisodeStatusText = EpisodeStatusText,
    EpisodeProgressText = EpisodeProgressText,
  })
end)

mp.register_script_message("bgm-noop", function() end)

mp.register_script_message("bgm-open-search-from-info", function()
  mp.commandv("script-message-to", "uosc", "close-menu", "menu_bgm_info")
  mp.commandv("script-message", "manual-match")
end)

mp.register_script_message("bgm-open-search", function()
  MatchResults = nil
  mp.commandv("script-message-to", "uosc", "close-menu", "menu_bgm_match")
  ui_menu.open_anime_search_menu(title_guess.get_default_search_query())
end)

mp.register_script_message("bgm-search-anime", function(query)
  if not query or query == "" then
    ui_menu.update_uosc_menu({
      type = "menu_bgm_anime",
      title = "输入番剧名称",
      search_style = "palette",
      search_debounce = "submit",
      search_suggestion = "",
      on_search = { "script-message-to", mp.get_script_name(), "bgm-search-anime" },
      footnote = "使用 enter 或 ctrl+enter 进行搜索",
      items = { ui_menu.format_menu_item("请输入番剧名称") },
    })
    return
  end

  ui_menu.update_uosc_menu({
    type = "menu_bgm_anime",
    title = "输入番剧名称",
    search_style = "palette",
    search_debounce = "submit",
    search_suggestion = query,
    on_search = { "script-message-to", mp.get_script_name(), "bgm-search-anime" },
    footnote = "正在加载搜索结果...",
    items = { ui_menu.format_menu_item("加载中...") },
  })

  bgm.dandanplay_search(query).async {
    resp = function(data)
      local items = {}
      for i, item in ipairs(data or {}) do
        items[i] = {
          title = item.title,
          hint = item.type,
          value = { "script-message-to", mp.get_script_name(), "bgm-search-episodes", item.title, item.id },
          keep_open = false,
          selectable = true,
        }
      end
      if #items == 0 then
        items = { ui_menu.format_menu_item("无搜索结果") }
      end
      ui_menu.update_uosc_menu({
        type = "menu_bgm_anime",
        title = "输入番剧名称",
        search_style = "palette",
        search_debounce = "submit",
        search_suggestion = query,
        on_search = { "script-message-to", mp.get_script_name(), "bgm-search-anime" },
        footnote = "使用 enter 或 ctrl+enter 进行搜索",
        items = items,
      })
    end,
    err = function(err)
      mp.msg.error("搜索番剧失败:", err)
      ui_menu.update_uosc_menu({
        type = "menu_bgm_anime",
        title = "输入番剧名称",
        search_style = "palette",
        search_debounce = "submit",
        search_suggestion = query,
        on_search = { "script-message-to", mp.get_script_name(), "bgm-search-anime" },
        footnote = "搜索失败，请重试",
        items = { ui_menu.format_menu_item("搜索番剧失败") },
      })
    end,
  }
end)

mp.register_script_message("bgm-search-episodes", function(anime_title, anime_id)
  if not anime_id then
    mp.msg.error "无效的番剧ID"
    return
  end
  mp.commandv("script-message-to", "uosc", "close-menu", "menu_bgm_anime")

  ui_menu.open_uosc_menu({
    type = "menu_bgm_episodes",
    title = string.format("选择剧集: %s", anime_title),
    search_style = "on_demand",
    footnote = "正在加载剧集...",
    items = { ui_menu.format_menu_item("加载中...") },
  })

  bgm.get_dandanplay_episodes(anime_id).async {
    resp = function(data)
      local items = {}
      for i, item in ipairs(data or {}) do
        items[i] = {
          title = item.title,
          hint = tostring(i),
          value = { "script-message-to", mp.get_script_name(), "bgm-select-episode", item.id },
          keep_open = false,
          selectable = true,
        }
      end
      if #items == 0 then
        items = { ui_menu.format_menu_item("没有找到匹配的剧集") }
      end
      ui_menu.update_uosc_menu({
        type = "menu_bgm_episodes",
        title = string.format("选择剧集: %s", anime_title),
        search_style = "on_demand",
        footnote = "使用 / 打开筛选",
        items = items,
      })
    end,
    err = function(err)
      mp.msg.error("获取剧集信息失败:", err)
      ui_menu.update_uosc_menu({
        type = "menu_bgm_episodes",
        title = string.format("选择剧集: %s", anime_title),
        search_style = "on_demand",
        footnote = "获取失败，请重试",
        items = { ui_menu.format_menu_item("获取剧集信息失败") },
      })
    end,
  }
end)

mp.register_script_message("bgm-select-episode", function(episode_id)
  if not episode_id then
    mp.msg.error "无效的集数ID"
    return
  end
  mp.commandv("script-message-to", "uosc", "close-menu", "menu_bgm_episodes")
  init(episode_id, { force_refresh = true })
end)

mp.register_script_message("bgm-select-match", function(episode_id)
  if not episode_id then
    mp.msg.error "无效的集数ID"
    return
  end
  mp.commandv("script-message-to", "uosc", "close-menu", "menu_bgm_match")
  init(episode_id, { force_refresh = true })
end)

mp.register_script_message("manual-match", function()
  if UoscAvailable then
    if MatchResults then
      ui_menu.open_match_menu(MatchResults)
      return
    end
    ui_menu.open_anime_search_menu(title_guess.get_default_search_query())
    return
  end
  local select_episode = function(anime_id)
    if not anime_id then
      mp.msg.error "无效的番剧ID"
      return
    end
    bgm.get_dandanplay_episodes(anime_id).async {
      resp = function(data)
        if not data or #data == 0 then
          mp.msg.error "没有找到匹配的剧集"
          mp.osd_message("没有找到匹配的剧集", 3)
          return
        end
        local episode_items = {}
        for i, item in ipairs(data) do
          episode_items[i] = item.title
        end
        input.select {
          prompt = "请选择正确剧集：",
          items = episode_items,
          submit = function(idx)
            if idx < 1 or idx > #data then
              mp.msg.error "无效的选择"
              return
            end
            local selected_episode = data[idx]
            mp.msg.verbose(
              "选择的剧集",
              selected_episode.id,
              selected_episode.title
            )
            init(selected_episode.id, { force_refresh = true })
          end,
        }
      end,
      err = function(err)
        mp.msg.error("获取剧集信息失败:", err)
        mp.osd_message("获取剧集信息失败", 3)
      end,
    }
  end
  local select_anime = function(data)
    if not data or #data == 0 then
      mp.msg.error "没有找到匹配的番剧"
      mp.osd_message("没有找到匹配的番剧", 3)
      return
    end
    local anime_items = {}
    for i, item in ipairs(data) do
      anime_items[i] = string.format("%d. %s\t[%s]", i, item.title, item.type)
    end
    input.terminate()
    input.select {
      prompt = "请选择正确番剧：",
      items = anime_items,
      submit = function(idx)
        if idx < 1 or idx > #data then
          mp.msg.error "无效的选择"
          return
        end
        local selected_anime = data[idx]
        mp.msg.verbose("选择的番剧", selected_anime.title)
        select_episode(selected_anime.id)
      end,
    }
  end

  mp.set_property("pause", "yes")
  if not MatchResults then
    input.terminate()
    input.get {
      prompt = "请输入番剧名：",
      submit = function(text)
        bgm.dandanplay_search(text).async {
          resp = function(data)
            select_anime(data)
          end,
          err = function(err)
            mp.msg.error("搜索番剧失败:", err)
            mp.osd_message("搜索番剧失败", 3)
          end,
        }
      end,
      -- keep_open = true,
      closed = function()
        mp.set_property("pause", "no")
      end,
    }
    return
  end

  local match_items = {}
  for i, match in ipairs(MatchResults) do
    match_items[i] =
      string.format("%d. %s\t[%s]", i, match.animeTitle, match.episodeTitle)
  end
  match_items[#match_items + 1] = "没有结果，手动搜索"

  input.select {
    prompt = "请选择匹配结果：",
    items = match_items,
    submit = function(idx)
      if idx < 1 or idx > #match_items then
        mp.msg.error "无效的选择"
        return
      end
      if idx == #match_items then
        mp.msg.verbose "选择了手动搜索"
        input.terminate()
        MatchResults = nil
        mp.command "script-message manual-match"
        return
      end
      local selected_match = MatchResults[idx]
      mp.msg.verbose(
        "选择的匹配结果",
        selected_match.animeTitle,
        selected_match.episodeTitle
      )
      init(selected_match.episodeId, { force_refresh = true })
    end,
    closed = function()
      mp.set_property("pause", "no")
    end,
  }
end)
