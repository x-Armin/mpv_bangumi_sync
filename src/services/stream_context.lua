local title_guess = require "src.title_guess"
local stream_data = require "src.stream_data"
local sync_context = require "src.services.sync_context"
local bangumi_api = require "src.bangumi_api"
local episode_matcher = require "src.episode_matcher"
local utils = require "src.utils"
local bangumi_episode_selector = require "src.services.bangumi_episode_selector"

local M = {}

local SEARCH_LIMIT = 10
local SEARCH_DETAIL_LIMIT = 5

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

local function format_match_failure_reason(title_info, reason)
  if not reason then
    return "原因未知"
  end

  local prefix = string.format(
    "title=%s season=%s episode=%s",
    tostring(title_info and title_info.title),
    tostring(title_info and title_info.season),
    tostring(title_info and title_info.episode_no)
  )
  local code = reason.code
  if code == "NoCandidates" then
    return prefix .. " reason=无候选结果"
  end
  if code == "SeasonFilteredAll" then
    return string.format(
      "%s reason=季度过滤后无候选 parsed_season=%s candidate_count=%s",
      prefix,
      tostring(reason.season),
      tostring(reason.candidate_count)
    )
  end
  if code == "PrimaryExactNotUnique" then
    return string.format("%s reason=name/name_cn 精确命中不唯一 count=%s", prefix, tostring(reason.count))
  end
  if code == "AliasExactNotUnique" then
    return string.format("%s reason=别名精确命中不唯一 count=%s", prefix, tostring(reason.count))
  end
  if code == "NoTitleSimilarity" then
    return string.format(
      "%s reason=候选标题与输入无有效相似度 candidate_count=%s parsed_season=%s",
      prefix,
      tostring(reason.candidate_count),
      tostring(reason.season)
    )
  end
  if code == "FuzzyDisabledShortTitle" then
    return string.format(
      "%s reason=标题过短不启用模糊匹配 best=%s best_score=%s",
      prefix,
      tostring(reason.best),
      tostring(reason.best_score)
    )
  end
  if code == "FuzzyBelowThreshold" then
    return string.format(
      "%s reason=相似度低于阈值 best=%s best_score=%s threshold=%s",
      prefix,
      tostring(reason.best),
      tostring(reason.best_score),
      tostring(reason.threshold)
    )
  end
  if code == "FuzzyGapTooSmall" then
    return string.format(
      "%s reason=最佳候选分差不够 best=%s best_score=%s second=%s second_score=%s gap=%s required_gap=%s",
      prefix,
      tostring(reason.best),
      tostring(reason.best_score),
      tostring(reason.second),
      tostring(reason.second_score),
      tostring(reason.gap),
      tostring(reason.required_gap)
    )
  end
  if code == "SeasonUniqueNotSatisfied" then
    return string.format(
      "%s reason=季度唯一兜底不满足 parsed_season=%s count=%s hit=%s rank=%s rank_limit=%s",
      prefix,
      tostring(reason.season),
      tostring(reason.count),
      tostring(reason.hit),
      tostring(reason.rank),
      tostring(reason.rank_limit)
    )
  end
  return prefix .. " reason=" .. tostring(code)
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

  local bgm_id, source, score, subject, reason = stream_data.match_subject_candidates(
    title_info,
    subjects,
    "search"
  )
  if not bgm_id then
    mp.msg.verbose(
      "stream_context: Bangumi搜索结果未达到自动绑定阈值 "
        .. format_match_failure_reason(title_info, reason)
    )
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

local function get_stream_episodes(runtime_episode_id, bgm_id, opts)
  local episodes = sync_context.get_user_episodes_cached(
    runtime_episode_id,
    bgm_id,
    {force_refresh = opts and opts.force_refresh == true}
  )
  if episodes and episodes.data then
    return episodes
  end

  return bangumi_episode_selector.fetch_subject_episodes(bgm_id)
end

local function current_url_key()
  local path = mp.get_property("path")
  if not path or path == "" then
    return nil
  end
  return utils.stable_url_key(path)
end

local function build_context_from_url_binding(binding, opts)
  local bgm_id = tonumber(binding and binding.bgm_id)
  local bgm_episode_id = tonumber(binding and binding.bgm_episode_id)
  if not bgm_id or not bgm_episode_id then
    return nil
  end

  local runtime_episode_id = bgm_id * 10000
  local episodes = get_stream_episodes(runtime_episode_id, bgm_id, opts)

  local subject = fetch_subject(bgm_id) or {}
  local anime_title = first_non_empty(
    subject.name_cn,
    subject.name,
    "Bangumi " .. tostring(bgm_id)
  )
  local _, selected_episode = bangumi_episode_selector.find_episode_by_bgm_id(episodes, bgm_episode_id)
  local episode_ep = selected_episode and tonumber(selected_episode.ep) or nil
  local episode_sort = selected_episode and tonumber(selected_episode.sort) or nil
  local episode_title = first_non_empty(
    selected_episode and selected_episode.name_cn,
    selected_episode and selected_episode.name,
    episode_ep and ("Episode " .. tostring(episode_ep)) or nil
  )
  runtime_episode_id = bgm_id * 10000 + (episode_ep or episode_sort or 0)
  if not episodes then
    episodes = {
      data = {
        {
          type = 0,
          episode = {
            id = bgm_episode_id,
            ep = episode_ep,
            sort = episode_sort,
            name = episode_title,
            name_cn = episode_title,
            type = 0,
          },
        },
      },
      total = 1,
      limit = 1,
      offset = 0,
    }
  end
  local bgm_url = "https://bgm.tv/subject/" .. tostring(bgm_id)
  local episode_info = {
    episodeId = runtime_episode_id,
    animeId = bgm_id,
    episodeEp = episode_ep,
    episodeSort = episode_sort,
    episodeMatchMode = "manual_url",
    animeTitle = anime_title,
    episodeTitle = episode_title,
    bgmEpisodeId = bgm_episode_id,
    shift = 0.0,
    stream = true,
  }
  local anime_info = {
    animeTitle = anime_title,
    bangumiUrl = bgm_url,
    stream = true,
    streamMatchSource = binding.source or "manual_url",
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
    },
  }
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
  local episodes = get_stream_episodes(runtime_episode_id, bgm_id, opts)
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
  local anime_title = first_non_empty(subject.name_cn, subject.name, title_info.title)
  local episode = target_ep.episode
  local episode_title = first_non_empty(
    episode.name_cn,
    episode.name,
    "第" .. tostring(title_info.episode_no) .. "话"
  )
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

local function fallback_to_dandanplay_file_match(opts, reason)
  local path = mp.get_property("path")
  if not path or path == "" then
    return nil
  end
  mp.msg.verbose(
    "stream_context: fallback to dandanplay file match reason=" .. tostring(reason)
  )
  return sync_context.sync_context({
    force_refresh = opts and opts.force_refresh == true,
    source = "stream_fallback",
    remote_url = path,
    remote_path_key = utils.stable_url_key(path),
  }).execute()
end

local function sync_context_execute(opts)
  opts = opts or {}
  local url_binding = stream_data.get_url_episode_binding(current_url_key())
  if url_binding then
    local bound_context = build_context_from_url_binding(url_binding, opts)
    if bound_context then
      return bound_context
    end
  end

  local title_info = title_guess.get_current_title_info()
  if not title_info or not title_info.normalized_title then
    local fallback = fallback_to_dandanplay_file_match(opts, "TitleUnavailable")
    if fallback and fallback.status ~= "error" then
      return fallback
    end
    return {
      status = "error",
      error = "StreamTitleError",
      reason = "TitleUnavailable",
    }
  end
  if not title_info.episode_no then
    local fallback = fallback_to_dandanplay_file_match(opts, "EpisodeFromStreamTitleFailed")
    if fallback and fallback.status ~= "error" then
      return fallback
    end
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
    local fallback = fallback_to_dandanplay_file_match(opts, bgm_source)
    if fallback and fallback.status ~= "error" then
      return fallback
    end
    return {
      status = "select_subject",
      title_info = title_info,
      query = title_info.title,
    }
  end

  local result = build_context(title_info, bgm_id, bgm_source, subject, opts)
  if result and result.status == "error" then
    local fallback = fallback_to_dandanplay_file_match(opts, result.reason or result.error)
    if fallback and fallback.status ~= "error" then
      return fallback
    end
  end
  return result
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
