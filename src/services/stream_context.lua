local title_guess = require "src.title_guess"
local stream_data = require "src.stream_data"
local sync_context = require "src.services.sync_context"
local bangumi_api = require "src.bangumi_api"
local episode_matcher = require "src.episode_matcher"

local M = {}

local SEARCH_LIMIT = 10
local SEARCH_DETAIL_LIMIT = 5

local function fetch_subject(bgm_id, opts)
  bgm_id = tonumber(bgm_id)
  if not bgm_id then
    return nil
  end

  local res = bangumi_api.get_subject(bgm_id)
  if not res or tonumber(res.status_code or 0) >= 400 or not res.body then
    return nil
  end
  if not opts or opts.save ~= false then
    stream_data.save_subject(res.body)
  end
  return res.body
end

local function ensure_subject_binding(title_info, bgm_id, source)
  local subject = fetch_subject(bgm_id, {save = false}) or {
    id = tonumber(bgm_id),
    name_cn = title_info and title_info.title or nil,
  }
  return stream_data.bind_subject(title_info, bgm_id, subject, source), subject
end

local function fetch_search_subject(item, fetch_detail, search_rank)
  local bgm_id = item and tonumber(item.id)
  if not bgm_id then
    return nil
  end

  if fetch_detail then
    local subject = fetch_subject(bgm_id, {save = false})
    if subject then
      subject.search_rank = search_rank
      return subject
    end
  end

  return {
    id = bgm_id,
    name = item.name,
    name_cn = item.name_cn,
    search_rank = search_rank,
  }
end

local function search_bangumi_subject(title_info)
  local query = title_info and title_info.title or nil
  if not query or query == "" then
    return nil
  end

  mp.msg.verbose("stream_context: 搜索Bangumi条目 " .. tostring(query))
  local res = bangumi_api.search_subjects(query, {limit = SEARCH_LIMIT, type_filter = {2}})
  if not res or tonumber(res.status_code or 0) >= 400 or not res.body then
    mp.msg.verbose("stream_context: Bangumi搜索失败 " .. tostring(query))
    return nil
  end

  local subjects = {}
  for index, item in ipairs(res.body.data or {}) do
    local subject = fetch_search_subject(item, index <= SEARCH_DETAIL_LIMIT, index)
    if subject then
      subjects[#subjects + 1] = subject
    end
  end

  local bgm_id, source, score, subject = stream_data.match_subject_candidates(
    title_info,
    subjects,
    "search"
  )
  if not bgm_id then
    mp.msg.verbose("stream_context: Bangumi搜索结果未达到自动绑定阈值")
    return nil
  end

  mp.msg.info(
    string.format(
      "流媒体自动匹配Bangumi条目: bgm_id=%s source=%s score=%s",
      tostring(bgm_id),
      tostring(source),
      tostring(score)
    )
  )
  if not stream_data.bind_subject(title_info, bgm_id, subject, source) then
    return nil, "SaveFailed"
  end

  return bgm_id, source, subject
end

local function resolve_bgm_id(title_info, opts)
  local manual_bgm_id = opts and tonumber(opts.manual_bgm_id) or nil
  if manual_bgm_id then
    local ok, subject = ensure_subject_binding(title_info, manual_bgm_id, "manual")
    if not ok then
      return nil, "SaveFailed"
    end
    return manual_bgm_id, "manual", subject
  end

  local alias = stream_data.get_alias(title_info)
  if alias and alias.bgm_id then
    return tonumber(alias.bgm_id), alias.source or "alias", nil
  end

  local bgm_id, source = stream_data.match_subject(title_info)
  if bgm_id then
    return bgm_id, source, nil
  end

  local subject
  bgm_id, source, subject = search_bangumi_subject(title_info)
  if bgm_id then
    return bgm_id, source, subject
  end
  if source == "SaveFailed" then
    return nil, "SaveFailed"
  end

  return nil, "NeedSubjectSelection"
end

local function resolve_target_episode(episodes, episode_no)
  local match = episode_matcher.match_by_number(episodes, episode_no)
  return match and match.target or nil, match
end

local function build_context(title_info, bgm_id, bgm_source, subject, opts)
  if not title_info.episode_no then
    return {
      status = "error",
      error = "EpisodeNumberNotFound",
      reason = "EpisodeFromStreamTitleFailed",
      title_info = title_info,
    }
  end

  local runtime_episode_id = tonumber(bgm_id) * 10000 + title_info.episode_no
  local episodes = sync_context.get_user_episodes_cached(
    runtime_episode_id,
    bgm_id,
    {force_refresh = opts and opts.force_refresh == true}
  )
  if not episodes or not episodes.data then
    return {
      status = "error",
      error = "EpisodesError",
      reason = "BangumiEpisodesUnavailable",
      title_info = title_info,
    }
  end

  local target_ep, match_result = resolve_target_episode(episodes.data, title_info.episode_no)
  if not target_ep or not target_ep.episode then
    return {
      status = "error",
      error = "EpisodeMappingNotFound",
      reason = "BangumiEpisodeNotFound",
      title_info = title_info,
    }
  end

  subject = subject or fetch_subject(bgm_id) or {}
  local anime_title = subject.name_cn or subject.name or title_info.title
  local episode = target_ep.episode
  local episode_title = episode.name_cn or episode.name or ("第" .. tostring(title_info.episode_no) .. "话")
  local resolved_ep = tonumber(episode.ep) or title_info.episode_no
  local resolved_sort = tonumber(episode.sort)
  local bgm_url = "https://bgm.tv/subject/" .. tostring(bgm_id)

  local episode_info = {
    episodeId = runtime_episode_id,
    animeId = bgm_id,
    episodeEp = resolved_ep,
    episodeSort = resolved_sort,
    episodeMatchMode = match_result and match_result.mode or nil,
    animeTitle = anime_title,
    episodeTitle = episode_title,
    bgmEpisodeId = episode.id,
    shift = 0.0,
    stream = true,
  }

  local anime_info = {
    animeTitle = anime_title,
    bangumiUrl = bgm_url,
    stream = true,
    streamTitle = title_info.title,
    streamMatchSource = bgm_source,
  }

  return {
    status = "ok",
    context = {
      file_path = mp.get_property("path"),
      episode_id = runtime_episode_id,
      episode_info = episode_info,
      anime_info = anime_info,
      bgm_id = bgm_id,
      bgm_url = bgm_url,
      episodes = episodes,
      storage = {
        key = "stream",
        storages = {},
        batch_sync_threshold = 1,
        matched_storage = "stream",
      },
      stream_title_info = title_info,
    },
  }
end

local function sync_context_execute(opts)
  opts = opts or {}
  local title_info = title_guess.get_current_title_info()
  if not title_info or not title_info.normalized_title then
    return {
      status = "error",
      error = "StreamTitleError",
      reason = "TitleUnavailable",
    }
  end
  if not title_info.episode_no then
    return {
      status = "error",
      error = "EpisodeNumberNotFound",
      reason = "EpisodeFromStreamTitleFailed",
      title_info = title_info,
    }
  end

  local bgm_id, bgm_source, subject = resolve_bgm_id(title_info, opts)
  if not bgm_id then
    if bgm_source == "SaveFailed" then
      return {
        status = "error",
        error = "StreamBindingError",
        reason = "SaveFailed",
        title_info = title_info,
      }
    end
    return {
      status = "select_subject",
      title_info = title_info,
      query = title_info.title,
    }
  end

  return build_context(title_info, bgm_id, bgm_source, subject, opts)
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

function M.bind_current_subject(bgm_id)
  local title_info = title_guess.get_current_title_info()
  if not title_info or not title_info.normalized_title then
    return false, "TitleUnavailable"
  end
  local ok = ensure_subject_binding(title_info, bgm_id, "manual")
  if not ok then
    return false, "SaveFailed"
  end
  return true, nil
end

function M.get_current_title_info()
  return title_guess.get_current_title_info()
end

return M
