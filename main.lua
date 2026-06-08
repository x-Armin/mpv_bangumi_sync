local SCRIPT_NAME = "mpv_bangumi_sync"
local SCRIPT_VERSION = "1.1.1"

local config = require "src.config"
local sync_context = require "src.services.sync_context"
local stream_context = require "src.services.stream_context"
local bangumi_service = require "src.services.bangumi_service"
local dandanplay_service = require "src.services.dandanplay_service"
local bangumi_api = require "src.bangumi_api"
local db = require "src.db"
local utils = require "src.utils"
local mp_utils = require "mp.utils"
local json_store = require "src.core.json_store"
local episode_status = require "src.services.episode_status"
local title_guess = require "src.title_guess"
local input = require "mp.input"
local ui_menu = require "src.ui_menu"

mp.msg.info(string.format("%s v%s loaded", SCRIPT_NAME, SCRIPT_VERSION))

-- global variables
CurrentEpContext = nil
AnimeInfo = nil
CurrentEpisodeInfo = nil
EpisodeStatusText = "未获取"
EpisodeProgressText = "未获取"
UpdateEpisodeTimer = nil
EpisodesReady = false
MatchResults = nil
UoscAvailable = false
StorageConfig = nil
AutoMarkEnabled = Options.enable_auto_mark ~= false
AutoMarkText = AutoMarkEnabled and "开启" or "禁用"
CurrentEpisodeWatched = false
CurrentNetworkMode = nil
NetworkModeOverride = nil
NetworkModeText = ""
local flush_pending_updates
local compose_sync_message
local update_episode_status_from_cache
local reconcile_update_timer
local mark_current_episode_status

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

local function sync_legacy_globals_from_current_ep_context()
  local context = CurrentEpContext or {}
  AnimeInfo = context.anime_info
  CurrentEpisodeInfo = context.episode_info
  EpisodeStatusText = context.status_text or "未获取"
  EpisodeProgressText = context.progress_text or "未获取"
  EpisodesReady = context.episodes_ready == true
  StorageConfig = context.storage
  CurrentEpisodeWatched = context.watched == true
end

local function reset_current_ep_context()
  CurrentEpContext = nil
  sync_legacy_globals_from_current_ep_context()
end

local function reset_globals()
  reset_current_ep_context()
  CurrentNetworkMode = nil
  NetworkModeText = ""
  if UpdateEpisodeTimer then
    UpdateEpisodeTimer:kill()
    UpdateEpisodeTimer = nil
  end
  MatchResults = nil
end

local function resolve_auto_mark_enabled()
  return Options.enable_auto_mark ~= false
end

local function update_auto_mark_text()
  AutoMarkText = AutoMarkEnabled and "开启" or "禁用"
end

local function log_auto_mark_mode()
  if AutoMarkEnabled then
    mp.msg.info("自动点格子：开启")
  else
    mp.msg.info("自动点格子：禁用（仅展示，不同步）")
  end
end

local function stop_update_timer(reason)
  if UpdateEpisodeTimer then
    UpdateEpisodeTimer:kill()
    UpdateEpisodeTimer = nil
    if reason and reason ~= "" then
      mp.msg.verbose("停止进度检测定时器: " .. reason)
    end
  end
end

local function should_start_update_timer()
  local context = CurrentEpContext
  return AutoMarkEnabled
    and context ~= nil
    and context.matched == true
    and context.episodes_ready == true
    and context.watched ~= true
    and context.anime_info ~= nil
end

local function start_update_timer_if_needed()
  if UpdateEpisodeTimer then
    return
  end
  if not should_start_update_timer() then
    return
  end

  UpdateEpisodeTimer = mp.add_periodic_timer(5, function()
    if not AutoMarkEnabled then
      stop_update_timer("自动点格子已禁用")
      return
    end
    if CurrentEpisodeWatched then
      stop_update_timer("当前集已看过")
      return
    end
    if not EpisodesReady then
      mp.msg.verbose("Bangumi 剧集未更新或更新失败，跳过更新")
      return
    end

    local current_time = mp.get_property_number("time-pos")
    local total_time = mp.get_property_number("duration")
    if not current_time or not total_time then
      return
    end
    local ratio = current_time / total_time
    local threshold = Options.progress_mark_threshold or 0.9
    if ratio < threshold then
      return
    end

    stop_update_timer("到达进度阈值，开始同步")
    mark_current_episode_status({status = 2, source = "auto", batch = true})
  end)
end

reconcile_update_timer = function()
  if should_start_update_timer() then
    start_update_timer_if_needed()
    return
  end
  stop_update_timer("当前模式无需进度检测")
end

local function get_current_file_path()
  local file_path = mp.get_property("path")
  if not file_path or file_path == "" then
    return nil
  end
  if utils.is_protocol(file_path) then
    return utils.url_decode(file_path)
  end
  return mp.command_native({"normalize-path", file_path})
end

local function get_current_db_path()
  local file_path = mp.get_property("path")
  if not file_path or file_path == "" then
    return nil
  end
  if utils.is_protocol(file_path) then
    return utils.stable_url_key(file_path)
  end
  return mp.command_native({"normalize-path", file_path})
end

local function is_current_stream()
  local path = mp.get_property("path")
  return utils.is_protocol(path)
end

local VIDEO_EXTENSIONS = {
  mp4 = true,
  mkv = true,
  webm = true,
  avi = true,
  mov = true,
  flv = true,
  ts = true,
  m2ts = true,
  mts = true,
  m4v = true,
  wmv = true,
}

local function get_url_host(path)
  if not path then
    return nil
  end
  local host = tostring(path):match("^%a[%w.+-]-://([^/:?#]+)")
  return host and host:lower() or nil
end

local function get_url_path(path)
  if not path then
    return ""
  end
  return tostring(path):match("^%a[%w.+-]-://[^/?#]+([^?#]*)") or ""
end

local function has_network_file_extension(path)
  local url_path = get_url_path(path):lower()
  local ext = url_path:match("%.([%w%d]+)$")
  return ext and VIDEO_EXTENSIONS[ext] == true
end

local function is_network_file_host(path)
  local host = get_url_host(path)
  if not host then
    return false
  end
  for _, configured in ipairs(config.config.network_file_hosts or {}) do
    if host == configured then
      return true
    end
  end
  return false
end

local function resolve_network_mode(path)
  if not utils.is_protocol(path) then
    return nil
  end
  if NetworkModeOverride then
    return NetworkModeOverride
  end
  if has_network_file_extension(path) or is_network_file_host(path) then
    return "file"
  end
  return "stream"
end

local function update_network_mode_text()
  if CurrentNetworkMode == "file" then
    NetworkModeText = "完整文件"
  elseif CurrentNetworkMode == "stream" then
    NetworkModeText = "流媒体"
  else
    NetworkModeText = ""
  end
end

local function is_current_stream_mode()
  return resolve_network_mode(mp.get_property("path")) == "stream"
end

local function resolve_runtime_episode_id(bgm_id)
  if not bgm_id then
    return nil
  end
  local file_path = get_current_file_path()
  if not file_path then
    return nil
  end
  local filename = file_path:match("([^/\\]+)$") or file_path
  local parsed = utils.extract_info_from_filename(filename)
  if not parsed or type(parsed.episode) ~= "number" then
    return nil
  end
  return tonumber(bgm_id) * 10000 + parsed.episode
end

compose_sync_message = function(collection_update_message, sync_message)
  if collection_update_message and collection_update_message ~= "" then
    return collection_update_message .. "\n" .. sync_message
  end
  return sync_message
end

local function set_current_ep_context(context)
  context = context or {}
  local episode_info = context.episode_info
  local anime_info = context.anime_info
  local bgm_id = context.bgm_id or (anime_info and anime_info.bgm_id)
  local runtime_episode_id = context.episode_id or (episode_info and episode_info.episodeId)
  if anime_info then
    anime_info.bgm_id = bgm_id
    anime_info.bgm_url = context.bgm_url
  end
  CurrentEpContext = {
    matched = false,
    match_error = nil,
    anime_info = anime_info,
    episode_info = episode_info,
    bgm_id = bgm_id,
    bgm_url = context.bgm_url,
    storage = context.storage,
    runtime_episode_id = runtime_episode_id,
    episodes_path = runtime_episode_id and db.get_path(runtime_episode_id, "episodes") or nil,
    episodes_data = context.episodes,
    episodes_ready = false,
    bgm_episode_id = episode_info and tonumber(episode_info.bgmEpisodeId) or nil,
    episode_item = nil,
    status_text = "未获取",
    progress_text = "未获取",
    watched = false,
  }
  update_episode_status_from_cache(context.episodes)
  sync_legacy_globals_from_current_ep_context()
  return CurrentEpContext
end

local function log_context_loaded_summary()
  local info = CurrentEpisodeInfo or {}
  local anime_title = info.animeTitle or "未知番剧"
  local episode_title = info.episodeTitle or "未知单集"
  local episode_ep = tonumber(info.episodeEp)
  local episode_part = episode_ep and ("第" .. tostring(episode_ep) .. "话 ") or ""

  local result_text = EpisodesReady and "番剧信息加载成功" or "番剧信息加载完成（剧集状态未就绪）"
  mp.msg.info(
    string.format(
      "%s-%s%s %s",
      anime_title,
      episode_part,
      episode_title,
      result_text
    )
  )
end

update_episode_status_from_cache = function(episodes_data)
  local context = CurrentEpContext
  local current_episode_info = (context and context.episode_info) or CurrentEpisodeInfo
  local result = episode_status.compute(current_episode_info, episodes_data)
  if not result then
    if context then
      context.matched = false
      context.match_error = "EpisodeStatusUnavailable"
      context.episodes_data = episodes_data or context.episodes_data
      context.episodes_ready = false
      context.watched = false
    end
    sync_legacy_globals_from_current_ep_context()
    return false
  end

  local progress = result.progress or {}
  if not context then
    CurrentEpContext = {}
    context = CurrentEpContext
  end
  context.episodes_data = episodes_data
  context.episodes_ready = episodes_data ~= nil and episodes_data.data ~= nil
  context.status_text = episode_status.map_status(result.status_value)
  context.progress_text = string.format("%d / %d", progress.watched or 0, progress.total or 0)
  context.watched = tonumber(result.status_value) == 2
  context.episode_info = result.episode_info or context.episode_info
  context.episode_item = result.episode_item
  context.bgm_episode_id = result.bgm_episode_id or (context.episode_info and tonumber(context.episode_info.bgmEpisodeId))
  context.matched = context.bgm_episode_id ~= nil
  context.match_error = context.matched and nil or "BangumiEpisodeNotFound"
  sync_legacy_globals_from_current_ep_context()
  return true
end

local function init(episode_id, opts)
  opts = opts or {}
  local force_refresh = opts == true or (type(opts) == "table" and opts.force_refresh)
  reset_globals()
  local source = (type(opts) == "table" and opts.source) or (episode_id and "manual" or "auto")
  local current_path = mp.get_property("path")
  local network_mode = type(opts) == "table" and opts.network_mode or nil
  if type(opts) == "table" and opts.stream == true then
    network_mode = "stream"
  end
  if not network_mode then
    network_mode = resolve_network_mode(current_path)
  end
  CurrentNetworkMode = network_mode
  update_network_mode_text()
  local stream_mode = network_mode == "stream"
  local network_file_mode = network_mode == "file"
  local context_service = stream_mode and stream_context or sync_context
  context_service.sync_context({
    episode_id = episode_id,
    manual_bgm_id = type(opts) == "table" and opts.manual_bgm_id or nil,
    force_refresh = force_refresh,
    source = source,
    remote_url = network_file_mode and current_path or nil,
    remote_path_key = network_file_mode and utils.stable_url_key(current_path) or nil,
  }).async {
    resp = function(result)
      if result and result.status == "select_subject" then
        local query = result.query or title_guess.get_default_search_query()
        mp.msg.info("流媒体未绑定Bangumi条目: " .. tostring(query or ""))
        mp.osd_message("流媒体未绑定Bangumi条目，可在番剧信息中手动匹配", 4)
        return
      end

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

      set_current_ep_context(result.context)

      mp.msg.verbose(
        "Bangumi ID:",
        AnimeInfo and AnimeInfo.bgm_id,
        "Bangumi Url:",
        AnimeInfo and AnimeInfo.bgm_url
      )
      log_context_loaded_summary()
        reconcile_update_timer()
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
      if err and err.error == "EpisodeNumberNotFound" then
        mp.msg.error("无法从文件名解析集数，请检查命名")
        mp.osd_message("无法从文件名解析集数，请检查命名", 3)
        return
      end
      if err and err.error == "AnimeInfoError" and err.reason == "BangumiUrlMissing" then
        mp.msg.error("番剧信息缺少 bangumiUrl，无法解析 Bangumi 条目")
        return
      end
      mp.msg.error("获取番剧元信息失败")
    end,
  }
end

local function bind_manual_bgm_and_reload(bgm_id)
  if is_current_stream_mode() then
    local ok, err = stream_context.bind_current_subject(bgm_id)
    if not ok then
      return false, err or "SaveFailed"
    end
    init(nil, { force_refresh = true, source = "manual_bgm", network_mode = "stream" })
    return true, nil
  end

  local file_path = get_current_db_path()
  if not file_path then
    return false, "PathUnavailable"
  end

  local ok = db.set_manual_bgm_id(file_path, bgm_id)
  if not ok then
    return false, "SaveFailed"
  end

  init(nil, {
    force_refresh = true,
    source = "manual_bgm",
    manual_bgm_id = bgm_id,
    network_mode = resolve_network_mode(mp.get_property("path")),
  })
  return true, nil
end

flush_pending_updates = function(reason, opts)
  local results = bangumi_service.flush_pending(opts)
  if results and #results > 0 then
    local count = 0
    for _, result in ipairs(results) do
      count = count + (tonumber(result.count) or 0)
    end
    mp.msg.info(string.format("Batch synced episodes: %d", count))
  end
end

local function update_info_menu_view()
  ui_menu.update_info_menu({
    UoscAvailable = UoscAvailable,
    CurrentEpisodeInfo = CurrentEpisodeInfo,
    EpisodeStatusText = EpisodeStatusText,
    EpisodeProgressText = EpisodeProgressText,
    AutoMarkText = AutoMarkText,
    IsNetworkPath = is_current_stream(),
    NetworkModeText = NetworkModeText,
  })
end

local function get_info_menu_state()
  return {
    UoscAvailable = UoscAvailable,
    CurrentEpisodeInfo = CurrentEpisodeInfo,
    EpisodeStatusText = EpisodeStatusText,
    EpisodeProgressText = EpisodeProgressText,
    AutoMarkText = AutoMarkText,
    IsNetworkPath = is_current_stream(),
    NetworkModeText = NetworkModeText,
  }
end

local function update_local_episode_status(context, episode_item, status)
  if not episode_item then
    return false
  end
  if tonumber(episode_item.type) == status then
    return true
  end
  episode_item.type = status
  return json_store.write(context.episodes_path, context.episodes_data, {atomic = true})
end

local function refresh_current_ep_context(force_refresh)
  local context = CurrentEpContext
  if not context or not context.runtime_episode_id or not context.bgm_id then
    return false
  end

  local episodes = sync_context.get_user_episodes_cached(
    context.runtime_episode_id,
    context.bgm_id,
    {force_refresh = force_refresh == true}
  )
  if not episodes or not episodes.data then
    return false
  end

  context.episodes_data = episodes
  update_episode_status_from_cache(episodes)
  return CurrentEpContext and CurrentEpContext.matched == true
end

mark_current_episode_status = function(opts)
  opts = opts or {}
  local status = tonumber(opts.status)
  local source = opts.source or "manual"
  local is_manual = source == "manual"
  if status ~= 0 and status ~= 2 then
    if is_manual then
      mp.osd_message("无效的剧集状态", 2)
    end
    return false
  end

  local context = CurrentEpContext
  if context and context.matched == true and context.bgm_episode_id then
    local previous_status = context.episode_item and tonumber(context.episode_item.type) or nil
    if previous_status == nil then
      previous_status = context.watched and 2 or nil
    end
    if previous_status == status then
      if is_manual then
        local current_text = (status == 2) and "已看" or "未看"
        mp.osd_message("当前已经是" .. current_text, 2)
      end
      return true
    end
  end

  if not context or context.matched ~= true or not context.bgm_episode_id then
    if is_manual then
      mp.osd_message("请先手动匹配当前集", 2)
    else
      mp.msg.verbose("自动标记跳过：当前集上下文已失效")
    end
    return false
  end

  local result = bangumi_service.update_episode({
    subject_id = context.bgm_id,
    episode_id = context.bgm_episode_id,
    status = status,
    storage = context.storage,
    batch = opts.batch == true,
  }).execute()
  if not result then
    local message = is_manual and "更新剧集状态失败" or "同步Bangumi追番进度失败"
    mp.osd_message(message, 3)
    return false
  end
  if result.uncollected then
    if is_manual then
      mp.osd_message("当前番剧未收藏", 2)
    end
    return false
  end

  local local_updated = update_local_episode_status(context, context.episode_item, status)
  if not local_updated then
    refresh_current_ep_context(true)
  else
    update_episode_status_from_cache(context.episodes_data)
  end
  if CurrentEpContext then
    CurrentEpContext.episodes_ready = true
  end
  sync_legacy_globals_from_current_ep_context()
  reconcile_update_timer()
  update_info_menu_view()

  local collection_update_message = result.collection_update_message
  if result.flush_failed then
    local message = compose_sync_message(collection_update_message, "同步Bangumi追番进度失败，已保留待重试")
    mp.msg.warn(message:gsub("\n", " | "))
    mp.osd_message(message, 3)
  elseif result.deferred then
    local message = compose_sync_message(collection_update_message, "已加入待批量同步队列")
    mp.msg.info(message:gsub("\n", " | "))
    mp.osd_message(message, 3)
  elseif result.disabled then
    mp.msg.verbose("自动点格子已禁用，跳过同步")
  elseif is_manual then
    local status_text = (status == 2) and "已看" or "未看"
    mp.osd_message(compose_sync_message(collection_update_message, "已标记为" .. status_text), 2)
  else
    local message = compose_sync_message(collection_update_message, "同步Bangumi追番进度成功")
    mp.msg.info(message:gsub("\n", " | "))
    mp.osd_message(message)
  end
  return true
end

local function apply_auto_mark_mode(opts)
  opts = opts or {}
  local previous = AutoMarkEnabled
  AutoMarkEnabled = resolve_auto_mark_enabled()
  update_auto_mark_text()

  if opts.force_log or previous == nil or previous ~= AutoMarkEnabled then
    log_auto_mark_mode()
  end

  if previous == true and AutoMarkEnabled == false then
    flush_pending_updates("auto-mark-disabled", {force = true, detach = false})
    stop_update_timer("自动点格子已禁用")
  elseif previous == false and AutoMarkEnabled == true then
    reconcile_update_timer()
  elseif not AutoMarkEnabled then
    stop_update_timer("自动点格子已禁用")
  end

  update_info_menu_view()
end

local function toggle_auto_mark_from_panel()
  Options.enable_auto_mark = not AutoMarkEnabled
  apply_auto_mark_mode({force_log = true})
  mp.osd_message("自动点格子：" .. AutoMarkText, 2)
end

local function toggle_network_mode_from_panel()
  local path = mp.get_property("path")
  if not utils.is_protocol(path) then
    return
  end
  local current = resolve_network_mode(path)
  NetworkModeOverride = current == "file" and "stream" or "file"
  init(nil, {force_refresh = true, source = "network_mode_toggle", network_mode = NetworkModeOverride})
  mp.osd_message("网络模式：" .. (NetworkModeOverride == "file" and "完整文件" or "流媒体"), 2)
end

config.on_options_changed(function()
  apply_auto_mark_mode()
end)
apply_auto_mark_mode({force_log = true})

mp.register_event("file-loaded", function()
  NetworkModeOverride = nil
  local path = mp.get_property "path"
  local network_mode = resolve_network_mode(path)
  if network_mode then
    mp.msg.verbose("Initializing network playback:", path, "mode:", network_mode)
    init(nil, { network_mode = network_mode })
    return
  end
  init()
end)


mp.register_event("end-file", function(event)
  if not event then
    return
  end
  if event.reason == "quit" then
    flush_pending_updates(event.reason, {detach = true})
  end
end)

mp.register_event("shutdown", function()
  flush_pending_updates("shutdown", {detach = true})
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
  bangumi_service.open_url(AnimeInfo.bgm_url).execute()
end)

mp.register_script_message("open-bangumi-info", function()
  ui_menu.open_info_menu(get_info_menu_state())
end)

mp.register_script_message("bgm-toggle-auto-mark", function()
  toggle_auto_mark_from_panel()
end)

mp.register_script_message("bgm-toggle-network-mode", function()
  toggle_network_mode_from_panel()
end)

mp.register_script_message("bgm-noop", function() end)

mp.register_script_message("bgm-info-menu-event", function(payload)
  local event = mp_utils.parse_json(payload or "")
  if not event or event.type ~= "activate" then
    return
  end

  if event.action == "refresh" then
    local file_path = get_current_db_path()
    if not file_path then
      mp.osd_message("无法获取当前文件路径", 2)
      return
    end
    local db_record = db.get({ path = file_path })
    local bgm_id = (AnimeInfo and AnimeInfo.bgm_id) or (db_record and db_record.bgm_id)
    if not bgm_id then
      mp.osd_message("缺少缓存条目信息，无法刷新", 2)
      return
    end
    local runtime_episode_id = CurrentEpisodeInfo and tonumber(CurrentEpisodeInfo.episodeId) or nil
    if not runtime_episode_id and db_record then
      if db_record.manual and db_record.bgm_id then
        runtime_episode_id = resolve_runtime_episode_id(db_record.bgm_id)
      else
        runtime_episode_id = db_record.dandanplay_id or resolve_runtime_episode_id(db_record.bgm_id)
      end
    end
    if not runtime_episode_id then
      mp.osd_message("无法定位当前集，刷新失败", 2)
      return
    end
    local episodes = sync_context.get_user_episodes_cached(
      runtime_episode_id,
      bgm_id,
      { force_refresh = true }
    )
    if not episodes then
      mp.osd_message("刷新剧集信息失败", 2)
      return
    end
    local updated = update_episode_status_from_cache(episodes)
    if updated then
      EpisodesReady = true
    end
    reconcile_update_timer()
    update_info_menu_view()
    mp.osd_message("已刷新", 2)
    return
  end
  if event.action == "edit_status" then
    mp.commandv("script-message-to", "uosc", "close-menu", "menu_bgm_info")
    ui_menu.open_episode_status_menu(get_info_menu_state())
    return
  end
  if event.action == "toggle_network_mode" then
    mp.commandv("script-message-to", "uosc", "close-menu", "menu_bgm_info")
    toggle_network_mode_from_panel()
    return
  end
  if event.action then
    return
  end

  local modifiers = event.modifiers
  if modifiers and modifiers ~= "alt" then
    return
  end

  local value = event.value
  if value == nil then
    return
  end

  if type(value) == "table" then
    mp.commandv(unpack(value))
  else
    mp.command(tostring(value))
  end

  if not event.keep_open and not modifiers then
    mp.commandv("script-message-to", "uosc", "close-menu", "menu_bgm_info")
  end
end)

mp.register_script_message("bgm-back-info-menu", function()
  mp.commandv("script-message-to", "uosc", "close-menu", "menu_bgm_status")
  ui_menu.open_info_menu(get_info_menu_state())
end)

mp.register_script_message("bgm-set-episode-status", function(status)
  mp.commandv("script-message-to", "uosc", "close-menu", "menu_bgm_status")
  mark_current_episode_status({status = status, source = "manual", batch = false})
end)

mp.register_script_message("bgm-open-search-from-info", function()
  mp.commandv("script-message-to", "uosc", "close-menu", "menu_bgm_info")
  mp.commandv("script-message", "manual-match")
end)

mp.register_script_message("bgm-open-search-source", function()
  MatchResults = nil
  mp.commandv("script-message-to", "uosc", "close-menu", "menu_bgm_match")
  ui_menu.open_manual_match_source_menu()
end)

mp.register_script_message("bgm-open-search", function()
  mp.commandv("script-message", "bgm-open-dandan-search")
end)

mp.register_script_message("bgm-open-dandan-search", function()
  if is_current_stream_mode() then
    mp.commandv("script-message", "bgm-open-bgm-subject-search")
    return
  end
  MatchResults = nil
  mp.commandv("script-message-to", "uosc", "close-menu", "menu_bgm_manual_source")
  mp.commandv("script-message-to", "uosc", "close-menu", "menu_bgm_match")
  ui_menu.open_anime_search_menu(title_guess.get_default_search_query())
end)

mp.register_script_message("bgm-open-bgm-subject-search", function()
  MatchResults = nil
  mp.commandv("script-message-to", "uosc", "close-menu", "menu_bgm_manual_source")
  mp.commandv("script-message-to", "uosc", "close-menu", "menu_bgm_match")
  ui_menu.open_subject_search_menu(title_guess.get_default_search_query())
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

  dandanplay_service.dandanplay_search(query).async {
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

mp.register_script_message("bgm-search-subjects", function(query)
  if not query or query == "" then
    ui_menu.update_uosc_menu({
      type = "menu_bgm_subject",
      title = "搜索Bangumi条目",
      search_style = "palette",
      search_debounce = "submit",
      search_suggestion = "",
      on_search = { "script-message-to", mp.get_script_name(), "bgm-search-subjects" },
      footnote = "使用 enter 或 ctrl+enter 进行搜索",
      items = { ui_menu.format_menu_item("请输入关键词") },
    })
    return
  end

  ui_menu.update_uosc_menu({
    type = "menu_bgm_subject",
    title = "搜索Bangumi条目",
    search_style = "palette",
    search_debounce = "submit",
    search_suggestion = query,
    on_search = { "script-message-to", mp.get_script_name(), "bgm-search-subjects" },
    footnote = "正在加载搜索结果...",
    items = { ui_menu.format_menu_item("加载中...") },
  })

  local res = bangumi_api.search_subjects(query, { limit = 20, type_filter = { 2 } })
  if not res or tonumber(res.status_code or 0) >= 400 or not res.body then
    ui_menu.update_uosc_menu({
      type = "menu_bgm_subject",
      title = "搜索Bangumi条目",
      search_style = "palette",
      search_debounce = "submit",
      search_suggestion = query,
      on_search = { "script-message-to", mp.get_script_name(), "bgm-search-subjects" },
      footnote = "搜索失败，请重试",
      items = { ui_menu.format_menu_item("搜索Bangumi条目失败") },
    })
    return
  end

  local items = {}
  for i, item in ipairs(res.body.data or {}) do
    local title = item.name_cn or item.name or ("#" .. tostring(item.id))
    items[i] = {
      title = title,
      hint = "#" .. tostring(item.id),
      value = { "script-message-to", mp.get_script_name(), "bgm-select-subject", tostring(item.id) },
      keep_open = false,
      selectable = true,
    }
  end
  if #items == 0 then
    items = { ui_menu.format_menu_item("无搜索结果") }
  end

  ui_menu.update_uosc_menu({
    type = "menu_bgm_subject",
    title = "搜索Bangumi条目",
    search_style = "palette",
    search_debounce = "submit",
    search_suggestion = query,
    on_search = { "script-message-to", mp.get_script_name(), "bgm-search-subjects" },
    footnote = is_current_stream_mode() and "选择条目后会绑定当前流媒体标题" or "选择条目后会绑定当前目录",
    items = items,
  })
end)

mp.register_script_message("bgm-select-subject", function(subject_id)
  local bgm_id = tonumber(subject_id)
  if not bgm_id then
    mp.msg.error("无效的Bangumi条目ID")
    return
  end

  mp.commandv("script-message-to", "uosc", "close-menu", "menu_bgm_subject")
  local ok, err_code = bind_manual_bgm_and_reload(bgm_id)
  if not ok then
    if err_code == "PathUnavailable" then
      mp.osd_message("无法获取当前文件路径", 2)
      return
    end
    if err_code == "TitleUnavailable" then
      mp.osd_message("无法解析当前流媒体标题", 2)
      return
    end
    mp.osd_message("保存Bangumi目录绑定失败", 2)
    return
  end
  mp.osd_message(is_current_stream_mode() and "已绑定当前流媒体Bangumi条目" or "已绑定当前目录Bangumi条目", 2)
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

  dandanplay_service.get_dandanplay_episodes(anime_id).async {
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
    if is_current_stream_mode() then
      ui_menu.open_subject_search_menu(title_guess.get_default_search_query())
      return
    end
    if MatchResults then
      ui_menu.open_match_menu(MatchResults)
      return
    end
    ui_menu.open_manual_match_source_menu()
    return
  end
  local bind_manual_subject = function(bgm_id)
    local ok, err_code = bind_manual_bgm_and_reload(bgm_id)
    if not ok then
      if err_code == "PathUnavailable" then
        mp.msg.error("无法获取当前文件路径")
        mp.osd_message("无法获取当前文件路径", 3)
        return
      end
      if err_code == "TitleUnavailable" then
        mp.msg.error("无法解析当前流媒体标题")
        mp.osd_message("无法解析当前流媒体标题", 3)
        return
      end
      mp.msg.error("保存Bangumi目录绑定失败")
      mp.osd_message("保存Bangumi目录绑定失败", 3)
      return
    end
  end
  local select_episode = function(anime_id)
    if not anime_id then
      mp.msg.error "无效的番剧ID"
      return
    end
    dandanplay_service.get_dandanplay_episodes(anime_id).async {
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
  local select_bgm_subject = function(data)
    if not data or #data == 0 then
      mp.msg.error "没有找到Bangumi条目"
      mp.osd_message("没有找到Bangumi条目", 3)
      return
    end
    local items = {}
    for i, item in ipairs(data) do
      local title = item.name_cn or item.name or ("#" .. tostring(item.id))
      items[i] = string.format("%d. %s\t[#%s]", i, title, tostring(item.id))
    end
    input.terminate()
    input.select {
      prompt = "请选择Bangumi条目：",
      items = items,
      submit = function(idx)
        if idx < 1 or idx > #data then
          mp.msg.error "无效的选择"
          return
        end
        local selected = data[idx]
        bind_manual_subject(selected.id)
      end,
    }
  end
  local start_dandan_search = function()
    input.terminate()
    input.get {
      prompt = "请输入番剧名：",
      submit = function(text)
        dandanplay_service.dandanplay_search(text).async {
          resp = function(data)
            select_anime(data)
          end,
          err = function(err)
            mp.msg.error("搜索番剧失败:", err)
            mp.osd_message("搜索番剧失败", 3)
          end,
        }
      end,
      closed = function()
        mp.set_property("pause", "no")
      end,
    }
  end
  local start_bgm_search = function()
    input.terminate()
    input.get {
      prompt = "请输入Bangumi关键词：",
      default_text = title_guess.get_default_search_query(),
      submit = function(text)
        local res = bangumi_api.search_subjects(text, { limit = 20, type_filter = { 2 } })
        if not res or tonumber(res.status_code or 0) >= 400 or not res.body then
          mp.msg.error("搜索Bangumi条目失败")
          mp.osd_message("搜索Bangumi条目失败", 3)
          return
        end
        select_bgm_subject(res.body.data or {})
      end,
      closed = function()
        mp.set_property("pause", "no")
      end,
    }
  end
  local open_source_menu = function()
    input.terminate()
    input.select {
      prompt = "请选择手动匹配来源：",
      items = { "弹弹play搜索", "Bangumi搜索" },
      submit = function(idx)
        if idx == 1 then
          start_dandan_search()
          return
        end
        if idx == 2 then
          start_bgm_search()
          return
        end
        mp.msg.error "无效的选择"
      end,
      closed = function()
        mp.set_property("pause", "no")
      end,
    }
  end

  mp.set_property("pause", "yes")
  if is_current_stream_mode() then
    start_bgm_search()
    return
  end

  if not MatchResults then
    open_source_menu()
    return
  end

  local match_items = {}
  for i, match in ipairs(MatchResults) do
    match_items[i] =
      string.format("%d. %s\t[%s]", i, match.animeTitle, match.episodeTitle)
  end
  match_items[#match_items + 1] = "没有结果，手动匹配"

  input.select {
    prompt = "请选择匹配结果：",
    items = match_items,
    submit = function(idx)
      if idx < 1 or idx > #match_items then
        mp.msg.error "无效的选择"
        return
      end
      if idx == #match_items then
        mp.msg.verbose "选择了手动匹配"
        input.terminate()
        MatchResults = nil
        open_source_menu()
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
