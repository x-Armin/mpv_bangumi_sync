local utils = require "src.utils"
local mp_utils = require "mp.utils"
local db = require "src.db"
local bangumi_api = require "src.bangumi_api"
local dandanplay_api = require "src.dandanplay_api"
local video_info = require "src.video_info"
local config = require "src.config"
local json_store = require "src.core.json_store"
local storage_gate = require "src.core.storage_gate"
local episode_matcher = require "src.episode_matcher"
local title_guess = require "src.title_guess"
local title_variants = require "src.title_variants"

local M = {}

local INFO_CACHE_MAX_AGE = 3600 * 24
local EPISODES_CACHE_MAX_AGE = 3600 * 4

local function first_non_empty(...)
  for i = 1, select("#", ...) do
    local value = select(i, ...)
    if value ~= nil then
      value = tostring(value):match("^%s*(.-)%s*$")
      if value ~= "" then
        return value
      end
    end
  end
  return nil
end

local function get_current_file_path()
  local file_path = mp.get_property("path")
  if not file_path then
    return nil
  end
  return mp.command_native({"normalize-path", file_path})
end

local function build_episode_info_from_anime(anime_info, episode_id)
  if not anime_info or not anime_info.episodes then
    mp.msg.error("anime_info or episodes missing")
    return nil
  end

  for _, episode in ipairs(anime_info.episodes) do
    if tostring(episode.episodeId) == tostring(episode_id) then
      return {
        episodeId = episode.episodeId,
        animeId = anime_info.animeId,
        animeTitle = anime_info.animeTitle,
        episodeTitle = episode.episodeTitle,
        type = anime_info.type,
        typeDescription = anime_info.typeDescription,
        shift = 0.0,
      }
    end
  end
  mp.msg.error("Episode ID not found in anime_info: " .. tostring(episode_id))
  return nil
end

local function get_anime_info_cached(episode_id, anime_id, opts)
  local force_refresh = opts and opts.force_refresh
  local info_path = db.get_path(episode_id, "info")
  if not force_refresh then
    local cached = json_store.read(info_path, {
      max_age = INFO_CACHE_MAX_AGE,
      validate = function(data)
        return data and data.episodes
      end,
    })
    if cached then
      mp.msg.verbose(
        string.format(
          "sync_context: anime_info 缓存命中 episode_id=%s anime_id=%s path=%s",
          tostring(episode_id),
          tostring(anime_id),
          info_path
        )
      )
      return cached
    end
  end

  mp.msg.verbose(
    string.format(
      "sync_context: anime_info 缓存未命中 episode_id=%s anime_id=%s refresh=%s",
      tostring(episode_id),
      tostring(anime_id),
      tostring(force_refresh == true)
    )
  )
  local fresh = dandanplay_api.get_anime_info(anime_id)
  if fresh and fresh.episodes then
    json_store.write(info_path, fresh, {atomic = true})
    return fresh
  end
  mp.msg.error(
    string.format(
      "Failed to get anime info from API episode_id=%s anime_id=%s",
      tostring(episode_id),
      tostring(anime_id)
    )
  )
  return nil
end

local function get_user_episodes_cached(episode_id, bgm_id, opts)
  if not bgm_id then
    return nil
  end
  local force_refresh = opts and opts.force_refresh
  local episodes_path = db.get_path(episode_id, "episodes")
  if not force_refresh then
    local cached = json_store.read(episodes_path, {
      max_age = EPISODES_CACHE_MAX_AGE,
      validate = function(data)
        return data and data.data
      end,
    })
    if cached then
      mp.msg.verbose(
        string.format(
          "sync_context: episodes 缓存命中 episode_id=%s bgm_id=%s path=%s",
          tostring(episode_id),
          tostring(bgm_id),
          episodes_path
        )
      )
      return cached
    end
  end

  mp.msg.verbose(
    string.format(
      "sync_context: episodes 缓存未命中 episode_id=%s bgm_id=%s refresh=%s",
      tostring(episode_id),
      tostring(bgm_id),
      tostring(force_refresh == true)
    )
  )
  local episodes = bangumi_api.get_user_episodes(bgm_id)
  if not episodes or not episodes.body or not episodes.body.data then
    return nil
  end
  json_store.write(episodes_path, episodes.body, {atomic = true})
  return episodes.body
end

-- 构造episode match
local function construct_episode_match(episode_id, opts)
  local anime_id = math.floor(episode_id / 10000)
  local anime_info = get_anime_info_cached(episode_id, anime_id, opts)
  local episode_info = build_episode_info_from_anime(anime_info, episode_id)
  if not episode_info then
    mp.msg.error("无法获取anime信息以构造episode match")
    return nil
  end
  return episode_info
end

-- 获取匹配信息
local function get_match_info(video_path, prepared_info)
  local info = prepared_info or video_info.get_info(video_path)
  if not info then
    mp.msg.verbose("match: video_info not available")
    mp.msg.error("无法获取视频信息: " .. video_path)
    return {}
  end
  
  local matches = dandanplay_api.match(info)
  if not matches or #matches == 0 then
    mp.msg.verbose("match: no candidates from dandanplay")
    mp.msg.error("未找到匹配: " .. info.filename)
    return {}
  end
  
  mp.msg.verbose("match: dandanplay candidates=" .. tostring(#matches))
  return matches
end

local function format_match_results(matches)
  local match_list = {}
  for _, match in ipairs(matches or {}) do
    table.insert(match_list, {
      episodeId = match.episodeId,
      animeTitle = match.animeTitle,
      episodeTitle = match.episodeTitle,
    })
  end
  return match_list
end

local function split_file_path(path)
  local dir_path = path:match("^(.+)/[^/]+$") or path:match("^(.+)\\[^\\]+$") or ""
  local filename = path:match("([^/\\]+)$") or path
  return dir_path, filename
end

local function append_unique(list, seen, value)
  if not value or value == "" or seen[value] then
    return
  end
  seen[value] = true
  list[#list + 1] = value
end

local function collect_title_variants(title)
  local variants = {}
  local seen = {}
  for _, value in ipairs(title_variants.normalized_variants(title) or {}) do
    append_unique(variants, seen, value)
  end
  append_unique(variants, seen, title_guess.normalize_title(title))
  return variants
end

local function normalized_titles_match(left, right)
  local left_variants = collect_title_variants(left)
  local right_variants = collect_title_variants(right)
  for _, a in ipairs(left_variants) do
    for _, b in ipairs(right_variants) do
      if a == b then
        return true
      end
      if #a >= 6 and #b >= 6 and (a:find(b, 1, true) or b:find(a, 1, true)) then
        return true
      end
    end
  end
  return utils.fuzzy_match_title(left or "", right or "") >= 0.72
end

local function filename_matches_title(filename, cached_title)
  local current_info = utils.extract_info_from_filename(filename or "")
  local current_title = current_info and current_info.title or nil
  if not current_title or not cached_title then
    return false
  end
  return normalized_titles_match(current_title, cached_title)
end

local function folder_entry_matches_current(entries, filename)
  local current_info = utils.extract_info_from_filename(filename or "")
  local current_title = current_info and current_info.title or nil
  if not current_title then
    return false
  end
  for cached_filename, _ in pairs(entries or {}) do
    if cached_filename ~= filename then
      local cached_info = utils.extract_info_from_filename(cached_filename or "")
      local cached_title = cached_info and cached_info.title or nil
      if cached_title and normalized_titles_match(current_title, cached_title) then
        return true
      end
    end
  end
  return false
end

local function anime_info_matches_filename(anime_info, filename)
  if not anime_info then
    return false
  end
  local candidates = {
    anime_info.animeTitle,
    anime_info.searchKeyword,
  }
  for _, item in ipairs(anime_info.titles or {}) do
    candidates[#candidates + 1] = item and item.title or nil
  end
  for _, title in ipairs(candidates) do
    if filename_matches_title(filename, title) then
      return true
    end
  end
  return false
end

local function can_use_autoload_source(video_source, sync_state, episode_id)
  if not episode_id then
    return false
  end
  local folder_info = sync_state and sync_state.folder_info or nil
  if folder_entry_matches_current(folder_info and folder_info.entries, video_source.filename) then
    return true
  end

  local episode_info = db.get_episode_info(episode_id)
  if episode_info and filename_matches_title(video_source.filename, episode_info.animeTitle) then
    return true
  end

  local anime_info = json_store.read(db.get_path(episode_id, "info"), {
    max_age = INFO_CACHE_MAX_AGE,
    validate = function(data)
      return data and (data.animeTitle or data.searchKeyword or data.titles)
    end,
  })
  if anime_info_matches_filename(anime_info, video_source.filename) then
    return true
  end

  mp.msg.verbose(
    string.format(
      "sync_context: autoload cache mismatch dir=%s filename=%s episode_id=%s",
      tostring(video_source.dir_path),
      tostring(video_source.filename),
      tostring(episode_id)
    )
  )
  return false
end

local function find_target_episode(episodes, episode_no)
  local match = episode_matcher.match_by_number(episodes, episode_no)
  return match and match.target or nil, match
end

local function get_subject_cached(bgm_id, episode_id, opts)
  if not bgm_id then
    return nil
  end
  local force_refresh = opts and opts.force_refresh
  local info_path = db.get_path(episode_id, "info")
  if not force_refresh then
    local cached = json_store.read(info_path, {
      max_age = INFO_CACHE_MAX_AGE,
      validate = function(data)
        return data and data.id
      end,
    })
    if cached then
      mp.msg.verbose(
        string.format(
          "sync_context: subject 缓存命中 bgm_id=%s path=%s",
          tostring(bgm_id),
          info_path
        )
      )
      return cached
    end
  end

  mp.msg.verbose(
    string.format(
      "sync_context: subject 缓存未命中 bgm_id=%s refresh=%s",
      tostring(bgm_id),
      tostring(force_refresh == true)
    )
  )
  local res = bangumi_api.get_subject(bgm_id)
  if not res or not res.body or tonumber(res.status_code or 0) >= 400 then
    return nil
  end
  json_store.write(info_path, res.body, {atomic = true})
  return res.body
end

local function normalize_search_title(title)
  if not title then
    return nil
  end
  local normalized = tostring(title):match("^%s*(.-)%s*$")
  if not normalized or normalized == "" then
    return nil
  end
  normalized = normalized:lower()
  normalized = normalized:gsub("[%s%p_%-]+", "")
  normalized = normalized:gsub("　", "")
  return normalized ~= "" and normalized or nil
end

local function append_unique_title(list, seen, value)
  value = value and tostring(value):match("^%s*(.-)%s*$") or nil
  if not value or value == "" or seen[value] then
    return
  end
  seen[value] = true
  list[#list + 1] = value
end

local function collect_search_titles(anime_info)
  local titles = {}
  local seen = {}

  append_unique_title(titles, seen, anime_info and anime_info.searchKeyword)
  append_unique_title(titles, seen, anime_info and anime_info.animeTitle)

  for _, item in ipairs(anime_info and anime_info.titles or {}) do
    append_unique_title(titles, seen, item and item.title)
  end

  return titles
end

local function bangumi_id_from_online_databases_process(anime_info)
  for _, item in ipairs(anime_info and anime_info.onlineDatabases or {}) do
    local url = item and item.url or nil
    local name = item and item.name or nil
    local lower_name = name and tostring(name):lower() or ""
    if url and (url:find("bgm.tv/subject/", 1, true) or lower_name:find("bangumi", 1, true)) then
      local bgm_id = tonumber(url:match("/subject/(%d+)"))
      if bgm_id then
        return bgm_id, url, "online_databases"
      end
    end
  end
  return nil
end

local function bangumi_id_from_search_process(anime_info)
  local queries = collect_search_titles(anime_info)
  if #queries == 0 then
    return nil
  end

  local normalized_queries = {}
  for _, query in ipairs(queries) do
    local normalized = normalize_search_title(query)
    if normalized then
      normalized_queries[normalized] = true
    end
  end

  local exact_matches = {}
  local best = nil
  local second = nil

  for _, query in ipairs(queries) do
    local res = bangumi_api.search_subjects(query, {limit = 10, type_filter = {2}})
    if res and tonumber(res.status_code or 0) < 400 and res.body and res.body.data then
      for index, item in ipairs(res.body.data) do
        local names = {item.name_cn, item.name}
        local exact = false
        local score = 0

        for _, candidate_name in ipairs(names) do
          local normalized_name = normalize_search_title(candidate_name)
          if normalized_name and normalized_queries[normalized_name] then
            exact = true
          end
          score = math.max(score, utils.fuzzy_match_title(query, candidate_name or ""))
        end

        score = score - ((index - 1) * 0.01)

        if exact then
          exact_matches[item.id] = exact_matches[item.id] or {
            id = item.id,
            url = "https://bgm.tv/subject/" .. tostring(item.id),
          }
        end

        if not best or score > best.score then
          second = best
          best = {
            id = item.id,
            url = "https://bgm.tv/subject/" .. tostring(item.id),
            score = score,
          }
        elseif not second or score > second.score then
          second = {
            id = item.id,
            url = "https://bgm.tv/subject/" .. tostring(item.id),
            score = score,
          }
        end
      end
    end
  end

  local exact_count = 0
  local exact_hit = nil
  for _, item in pairs(exact_matches) do
    exact_count = exact_count + 1
    exact_hit = item
  end
  if exact_count == 1 and exact_hit then
    return exact_hit.id, exact_hit.url, "search_exact"
  end

  if best and best.score >= 0.95 then
    local second_score = second and second.score or 0
    if not second or best.id == second.id or (best.score - second_score) >= 0.08 then
      return best.id, best.url, "search_fuzzy"
    end
  end

  return nil
end

local function bangumi_binding_process(anime_info, episode_id)
  if not anime_info then
    return nil
  end

  local bgm_url = anime_info.bangumiUrl
  local bgm_id = bgm_url and tonumber(bgm_url:match("/(%d+)$")) or nil
  if bgm_id then
    return bgm_id, bgm_url, "dandanplay"
  end

  local resolved_id, resolved_url, source = bangumi_id_from_online_databases_process(anime_info)
  if not resolved_id then
    resolved_id, resolved_url, source = bangumi_id_from_search_process(anime_info)
  end

  if resolved_id then
    anime_info.bangumiUrl = resolved_url
    json_store.write(db.get_path(episode_id, "info"), anime_info, {atomic = true})
    return resolved_id, resolved_url, source
  end

  return nil
end

-- 归一化 sync_context 入参，统一兼容 boolean 和 table 两种调用方式。
-- 返回 sync_opts 表，包含刷新、来源、远端文件和 episodes 加载开关。
local function sync_opts_normalize(opts)
  opts = opts or {}
  local is_table = type(opts) == "table"
  local source = is_table and opts.source or nil
  local force_refresh = opts == true or (is_table and opts.force_refresh)

  return {
    force_refresh = force_refresh,
    force_episode_id = is_table and opts.episode_id or nil,
    force_manual_bgm_id = is_table and tonumber(opts.manual_bgm_id) or nil,
    source = source,
    ensure_episodes = not is_table or opts.ensure_episodes ~= false,
    refresh = force_refresh or source == "manual" or source == "manual_bgm",
    remote_url = is_table and opts.remote_url or nil,
    remote_path_key = is_table and opts.remote_path_key or nil,
    remote_video_info = is_table and opts.remote_video_info or nil,
  }
end

-- 处理当前视频来源，区分本地文件和远端文件并准备 storage 信息。
-- 成功返回 status=ok 的 video_source；失败返回 VideoPathError。
local function video_source_process(sync_opts)
  local remote_url = sync_opts.remote_url
  local remote_video_info = sync_opts.remote_video_info
  local is_remote_file = remote_url ~= nil or remote_video_info ~= nil
  local file_path = sync_opts.remote_path_key
    or (remote_url and utils.stable_url_key(remote_url))
    or get_current_file_path()

  if is_remote_file then
    remote_video_info = remote_video_info or video_info.get_url_info(remote_url or file_path)
    if not remote_video_info then
      mp.msg.verbose("sync_context: 无法获取远端视频信息")
      mp.msg.error("无法获取远端视频信息")
      return {status = "error", error = "VideoPathError", reason = "RemoteInfoUnavailable"}
    end
  else
    local file_info = file_path and mp_utils.file_info(file_path) or nil
    if not file_info or file_info.is_file ~= true then
      mp.msg.verbose("sync_context: 文件路径无效或不是文件")
      mp.msg.error("视频路径无效或不是文件")
      return {status = "error", error = "VideoPathError", reason = "InvalidPath"}
    end
  end

  mp.msg.verbose("sync_context: 已获取文件路径")
  local storage_config = is_remote_file and {
    key = "network_file",
    storages = {},
    batch_sync_threshold = 1,
    matched_storage = "network_file",
  } or storage_gate.resolve_storage(file_path)
  if not storage_config then
    mp.msg.info("sync_context: 文件不在配置的存储路径内")
    return {
      status = "error",
      error = "VideoPathError",
      reason = "NotInStorage",
    }
  end

  local dir_path, filename
  if is_remote_file then
    dir_path = select(1, split_file_path(file_path))
    filename = remote_video_info.filename
  else
    dir_path, filename = split_file_path(file_path)
  end

  return {
    status = "ok",
    file_path = file_path,
    dir_path = dir_path,
    filename = filename,
    storage_config = storage_config,
    remote_video_info = remote_video_info,
    is_remote_file = is_remote_file,
  }
end

-- 从 DB 读取当前文件已保存的同步状态，包括文件记录、目录记录和手动 Bangumi 绑定。
-- 返回 sync_state 表，包含 db_record、folder_info、manual_bgm_id 和 episode_id。
local function load_sync_state_from_db(sync_opts, video_source)
  local db_record = db.get({path = video_source.file_path})
  mp.msg.verbose(
    string.format(
      "sync_context: db 记录 dandanplay_id=%s bgm_id=%s",
      tostring(db_record and db_record.dandanplay_id),
      tostring(db_record and db_record.bgm_id)
    )
  )

  local folder_info = video_source.dir_path ~= "" and db.get_folder_info(video_source.dir_path) or nil
  local manual_bgm_id = sync_opts.force_manual_bgm_id
  if not manual_bgm_id and folder_info and folder_info.manual and folder_info.bgm_id then
    manual_bgm_id = tonumber(folder_info.bgm_id)
  end

  return {
    db_record = db_record,
    folder_info = folder_info,
    manual_bgm_id = manual_bgm_id,
    episode_id = sync_opts.force_episode_id or (db_record and db_record.dandanplay_id),
  }
end

-- 组装 sync_context 的统一成功结果。
-- 返回 status=ok，并在 context 中携带文件、剧集、Bangumi、episodes 和 storage 信息。
local function sync_context_build(video_source, episode_id, episode_info, anime_info, bgm_id, bgm_url, episodes)
  return {
    status = "ok",
    context = {
      file_path = video_source.file_path,
      episode_id = episode_id,
      episode_info = episode_info,
      anime_info = anime_info,
      bgm_id = bgm_id,
      bgm_url = bgm_url or (bgm_id and ("https://bgm.tv/subject/" .. tostring(bgm_id)) or nil),
      episodes = episodes,
      storage = video_source.storage_config,
    },
  }
end

-- 处理手动 Bangumi 绑定流程，通过文件名集数映射 Bangumi episode。
-- 不适用时返回 nil；成功返回完整 context；失败返回对应 error。
local function manual_bangumi_context_process(sync_opts, video_source, sync_state)
  local manual_bgm_id = sync_state.manual_bgm_id
  if not manual_bgm_id or sync_opts.force_episode_id then
    return nil
  end

  local file_info = utils.extract_info_from_filename(video_source.filename or "")
  local episode_no = file_info and file_info.episode or nil
  if not episode_no then
    mp.msg.error("无法从文件名解析集数: " .. tostring(video_source.filename))
    return {
      status = "error",
      error = "EpisodeNumberNotFound",
      reason = "EpisodeFromFilenameFailed",
    }
  end

  local runtime_episode_id = manual_bgm_id * 10000 + episode_no
  local episodes = get_user_episodes_cached(runtime_episode_id, manual_bgm_id, {force_refresh = sync_opts.refresh})
  if not episodes or not episodes.data then
    mp.msg.error("获取Bangumi剧集列表失败: " .. tostring(manual_bgm_id))
    return {
      status = "error",
      error = "EpisodesError",
      reason = "BangumiEpisodesUnavailable",
    }
  end

  local target_ep, match_result = find_target_episode(episodes.data, episode_no)
  if not target_ep then
    local stats = match_result and match_result.stats or {}
    mp.msg.error(
      string.format(
        "无法在Bangumi剧集中定位当前集: parsed_no=%s max_main_ep=%s mode=%s reason=%s",
        tostring(episode_no),
        tostring(stats and stats.max_main_ep),
        tostring(match_result and match_result.mode),
        tostring(match_result and match_result.reason)
      )
    )
    return {
      status = "error",
      error = "EpisodeMappingNotFound",
      reason = "BangumiEpisodeNotFound",
    }
  end

  mp.msg.verbose(
    string.format(
      "sync_context: manual_bgm 匹配命中 mode=%s reason=%s parsed_no=%s max_main_ep=%s",
      tostring(match_result and match_result.mode),
      tostring(match_result and match_result.reason),
      tostring(episode_no),
      tostring(match_result and match_result.stats and match_result.stats.max_main_ep)
    )
  )
  if match_result and match_result.reason == "sort_fallback_parsed_gt_max_ep" then
    mp.msg.verbose("sync_context: 检测到累计编号映射，已使用 sort 兜底")
  end

  local subject = get_subject_cached(manual_bgm_id, runtime_episode_id, {force_refresh = sync_opts.refresh}) or {}
  local anime_title = first_non_empty(
    subject.name_cn,
    subject.name,
    "Bangumi " .. tostring(manual_bgm_id)
  )
  local episode_title = first_non_empty(
    target_ep.episode and target_ep.episode.name_cn,
    target_ep.episode and target_ep.episode.name,
    "第" .. tostring(episode_no) .. "话"
  )
  local resolved_ep = target_ep.episode and tonumber(target_ep.episode.ep) or episode_no
  local resolved_sort = target_ep.episode and tonumber(target_ep.episode.sort) or nil
  local episode_info = {
    episodeId = runtime_episode_id,
    animeId = manual_bgm_id,
    episodeEp = resolved_ep,
    episodeSort = resolved_sort,
    episodeMatchMode = match_result and match_result.mode or nil,
    animeTitle = anime_title,
    episodeTitle = episode_title,
    bgmEpisodeId = target_ep.episode and target_ep.episode.id or nil,
    shift = 0.0,
  }
  local anime_info = {
    animeTitle = anime_title,
    bangumiUrl = "https://bgm.tv/subject/" .. tostring(manual_bgm_id),
  }

  db.set_bgm_id(video_source.file_path, manual_bgm_id)
  db.set_episode_info(runtime_episode_id, episode_info)
  return sync_context_build(
    video_source,
    runtime_episode_id,
    episode_info,
    anime_info,
    manual_bgm_id,
    "https://bgm.tv/subject/" .. tostring(manual_bgm_id),
    episodes
  )
end

-- 处理 dandanplay episode_id 获取流程，包括强制 ID、自动加载和候选匹配。
-- 成功返回 episode_id/episode_info；多候选返回 select；失败返回 MatchNotFound。
local function dandanplay_context_process(sync_opts, video_source, sync_state)
  local episode_id = sync_state.episode_id
  local episode_info = nil
  local episode_source = episode_id and "db" or nil

  if sync_opts.force_episode_id then
    mp.msg.verbose("sync_context: 强制 episode_id=" .. tostring(sync_opts.force_episode_id))
    db.set_dandanplay_id(video_source.file_path, sync_opts.force_episode_id)
    episode_source = "force"
  end

  if not episode_id and not sync_state.skip_autoload then
    local autoload_id = (not video_source.is_remote_file)
      and db.get_autoload_source(video_source.dir_path, video_source.filename)
      or nil
    if autoload_id then
      if can_use_autoload_source(video_source, sync_state, autoload_id) then
        mp.msg.verbose("sync_context: autoload episode_id=" .. tostring(autoload_id))
        episode_id = autoload_id
        episode_source = "autoload"
      else
        mp.msg.verbose("sync_context: autoload skipped, fallback to dandanplay match")
      end
    else
      mp.msg.verbose("sync_context: 自动加载episode_id失败")
    end
  end

  if episode_id then
    mp.msg.verbose("sync_context: 当前 episode_id=" .. tostring(episode_id))
    episode_info = db.get_episode_info(episode_id)
    if episode_info then
      mp.msg.verbose("sync_context: episode_info 缓存命中")
    end
  end

  if not episode_id then
    local matches = get_match_info(video_source.file_path, video_source.remote_video_info)
    mp.msg.verbose("sync_context: 匹配候选数=" .. tostring(#matches))
    if #matches > 1 then
      local folder_info = sync_state.folder_info
      if (not video_source.is_remote_file) and folder_info and folder_info.manual and folder_info.anime_id then
        for _, match in ipairs(matches) do
          local match_anime_id = math.floor(match.episodeId / 10000)
          if match_anime_id == folder_info.anime_id then
            mp.msg.verbose(
              "sync_context: 通过手动 anime_id 自动选择匹配=" .. tostring(folder_info.anime_id)
            )
            episode_info = match
            episode_id = match.episodeId
            episode_source = "match"
            db.set_dandanplay_id(video_source.file_path, episode_id)
            db.set_episode_info(episode_id, episode_info)
            break
          end
        end
        if not episode_id then
          mp.msg.verbose("sync_context: 候选中未找到手动 anime_id")
        end
      end

      if not episode_id then
        local info = utils.extract_info_from_filename(video_source.filename)
        mp.msg.verbose("sync_context: 匹配结果需要手动选择")
        return {
          status = "select",
          info = info,
          matches = format_match_results(matches),
        }
      end
    end

    if not episode_id then
      episode_info = matches[1]
      if episode_info then
        mp.msg.verbose("sync_context: 选中匹配 episode_id=" .. tostring(episode_info.episodeId))
        episode_id = episode_info.episodeId
        episode_source = "match"
        db.set_dandanplay_id(video_source.file_path, episode_id)
        db.set_episode_info(episode_id, episode_info)
      end
    end
  end

  if not episode_id then
    mp.msg.error("Match failed: " .. video_source.file_path)
    mp.msg.verbose("sync_context: 匹配后仍未获得 episode_id")
    return {status = "error", error = "MatchNotFound", video = video_source.file_path}
  end

  if sync_opts.source == "manual" then
    local anime_id = math.floor(episode_id / 10000)
    db.set_manual_selection(video_source.file_path, anime_id)
    mp.msg.verbose("sync_context: 已保存手动 anime_id=" .. tostring(anime_id))
  end

  return {
    status = "ok",
    episode_id = episode_id,
    episode_info = episode_info,
    episode_source = episode_source,
  }
end

-- 校验 episode_info 是否可用，缺失时从 anime_info 重建并写入缓存。
-- 成功返回 episode_info 和可能已加载的 anime_info；失败返回 EpisodeInfoError。
local function episode_info_ensure_or_rebuild(sync_opts, video_source, episode_id, episode_info)
  local anime_info = nil
  if not episode_info then
    local anime_id = math.floor(episode_id / 10000)
    anime_info = get_anime_info_cached(episode_id, anime_id, {force_refresh = sync_opts.refresh})
    episode_info = build_episode_info_from_anime(anime_info, episode_id)
    if episode_info then
      mp.msg.verbose("sync_context: 已从 anime_info 构建 episode_info")
      db.set_episode_info(episode_id, episode_info)
    end
  end

  if not episode_info then
    mp.msg.error("Episode info not available: " .. tostring(episode_id))
    mp.msg.verbose("sync_context: 查询 anime_info 后仍缺少 episode_info")
    return {status = "error", error = "EpisodeInfoError", episode_id = episode_id}
  end

  db.set_dandanplay_id(video_source.file_path, episode_id)
  return {
    status = "ok",
    episode_info = episode_info,
    anime_info = anime_info,
  }
end

-- 处理 Bangumi 绑定和用户 episodes 加载。
-- 成功返回 anime_info、bgm_id、bgm_url、episodes；失败返回 AnimeInfoError。
local function bangumi_context_process(sync_opts, video_source, episode_id, anime_info)
  if not anime_info then
    local anime_id = math.floor(episode_id / 10000)
    anime_info = get_anime_info_cached(episode_id, anime_id, {force_refresh = sync_opts.refresh})
  end

  if not anime_info then
    mp.msg.error("Anime info not available: " .. tostring(episode_id))
    mp.msg.verbose("sync_context: anime_info 缺失或无 bangumiUrl")
    return {
      status = "error",
      error = "AnimeInfoError",
      reason = "AnimeInfoMissing",
      episode_id = episode_id,
    }
  end

  local bgm_id, bgm_url, bgm_source = bangumi_binding_process(anime_info, episode_id)
  mp.msg.verbose(
    string.format(
      "sync_context: 解析 bgm_id=%s source=%s",
      tostring(bgm_id),
      tostring(bgm_source)
    )
  )
  if not bgm_id then
    mp.msg.error(
      string.format(
        "Bangumi URL missing in anime info: episode_id=%s anime_id=%s",
        tostring(episode_id),
        tostring(anime_info and anime_info.animeId)
      )
    )
    mp.msg.verbose("sync_context: bangumiUrl 缺失，且 Bangumi 条目回退解析失败")
    return {
      status = "error",
      error = "AnimeInfoError",
      reason = "BangumiUrlMissing",
      episode_id = episode_id,
    }
  end

  db.set_bgm_id(video_source.file_path, bgm_id)
  local episodes = nil
  if sync_opts.ensure_episodes then
    episodes = get_user_episodes_cached(episode_id, bgm_id, {force_refresh = sync_opts.refresh})
    mp.msg.verbose("sync_context: episodes 已加载=" .. tostring(episodes ~= nil))
  end

  return {
    status = "ok",
    anime_info = anime_info,
    bgm_id = bgm_id,
    bgm_url = bgm_url,
    episodes = episodes,
  }
end

-- sync_context 主编排函数，按来源、状态、匹配、Bangumi 的顺序串联各阶段。
-- 返回 status=ok/select/error，保持 M.sync_context 和 M.match 的对外契约。
local function sync_context_execute(opts)
  local sync_opts = sync_opts_normalize(opts)
  mp.msg.verbose(
    string.format(
      "sync_context: 开始 source=%s force_refresh=%s ensure_episodes=%s force_episode_id=%s",
      tostring(sync_opts.source),
      tostring(sync_opts.force_refresh == true),
      tostring(sync_opts.ensure_episodes),
      tostring(sync_opts.force_episode_id)
    )
  )

  local video_source = video_source_process(sync_opts)
  if video_source.status ~= "ok" then
    return video_source
  end

  local sync_state = load_sync_state_from_db(sync_opts, video_source)
  local manual_result = manual_bangumi_context_process(sync_opts, video_source, sync_state)
  if manual_result then
    return manual_result
  end

  local dandanplay_result = dandanplay_context_process(sync_opts, video_source, sync_state)
  if dandanplay_result.status ~= "ok" then
    return dandanplay_result
  end

  local episode_result = episode_info_ensure_or_rebuild(
    sync_opts,
    video_source,
    dandanplay_result.episode_id,
    dandanplay_result.episode_info
  )
  if episode_result.status ~= "ok"
    and dandanplay_result.episode_source ~= "match"
    and dandanplay_result.episode_source ~= "force" then
    mp.msg.verbose(
      "sync_context: cached episode_id invalid, fallback to dandanplay match"
    )
    sync_state.episode_id = nil
    sync_state.skip_autoload = true
    dandanplay_result = dandanplay_context_process(sync_opts, video_source, sync_state)
    if dandanplay_result.status ~= "ok" then
      return dandanplay_result
    end
    episode_result = episode_info_ensure_or_rebuild(
      sync_opts,
      video_source,
      dandanplay_result.episode_id,
      dandanplay_result.episode_info
    )
  end
  if episode_result.status ~= "ok" then
    return episode_result
  end

  local bangumi_result = bangumi_context_process(
    sync_opts,
    video_source,
    dandanplay_result.episode_id,
    episode_result.anime_info
  )
  if bangumi_result.status ~= "ok" then
    return bangumi_result
  end

  return sync_context_build(
    video_source,
    dandanplay_result.episode_id,
    episode_result.episode_info,
    bangumi_result.anime_info,
    bangumi_result.bgm_id,
    bangumi_result.bgm_url,
    bangumi_result.episodes
  )
end
function M.sync_context(opts)
  return {
    execute = function()
      return sync_context_execute(opts)
    end,
    async = function(cb)
      cb = cb or {}
      cb.resp = cb.resp or function(_) end
      cb.err = cb.err or function(_) end
      local result = sync_context_execute(opts)
      if result and result.status ~= "error" then
        cb.resp(result)
      else
        cb.err(result)
      end
    end,
  }
end

-- 匹配视频（force_id可选）
function M.match(force_id)
  local opts = {
    episode_id = force_id,
    ensure_episodes = false,
    source = force_id and "manual" or "auto",
  }

  return {
    execute = function()
      local result = sync_context_execute(opts)
      if not result then
        return nil
      end
      if result.status == "select" then
        return {info = result.info, matches = result.matches}
      end
      if result.status == "ok" and result.context and result.context.episode_info then
        local episode_info = result.context.episode_info
        return {
          info = episode_info,
          desc = episode_info.animeTitle .. " " .. episode_info.episodeTitle,
        }
      end
      return nil
    end,
    async = function(cb)
      cb = cb or {}
      cb.resp = cb.resp or function(_) end
      cb.err = cb.err or function() end
      local result = sync_context_execute(opts)
      if not result then
        cb.err()
        return
      end
      if result.status == "select" then
        cb.resp({info = result.info, matches = result.matches})
        return
      end
      if result.status == "ok" and result.context and result.context.episode_info then
        local episode_info = result.context.episode_info
        cb.resp({
          info = episode_info,
          desc = episode_info.animeTitle .. " " .. episode_info.episodeTitle,
        })
        return
      end
      cb.err()
    end,
  }
end


-- 打开URL

M.construct_episode_match = construct_episode_match
M.get_anime_info_cached = get_anime_info_cached
M.get_user_episodes_cached = get_user_episodes_cached

return M
