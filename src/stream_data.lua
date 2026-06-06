local mp_utils = require "mp.utils"
local paths = require "src.paths"
local json_store = require "src.core.json_store"
local title_guess = require "src.title_guess"
local title_variants = require "src.title_variants"
local utils = require "src.utils"

local M = {}

local STREAM_DATA_PATH = mp_utils.join_path(paths.DATA_PATH, "stream_data.json")
local UTF8_PATTERN = "[\1-\127\194-\244][\128-\191]*"
local FUZZY_THRESHOLD = 0.95
local FUZZY_GAP = 0.08
local SEARCH_RANK_SEASON_UNIQUE_LIMIT = 5
local CHINESE_SEASON_NUMS = {
  [1] = "一",
  [2] = "二",
  [3] = "三",
  [4] = "四",
  [5] = "五",
  [6] = "六",
  [7] = "七",
  [8] = "八",
  [9] = "九",
  [10] = "十",
}
local ENGLISH_ORDINAL_SEASONS = {
  [1] = "first",
  [2] = "second",
  [3] = "third",
  [4] = "fourth",
  [5] = "fifth",
  [6] = "sixth",
  [7] = "seventh",
  [8] = "eighth",
  [9] = "ninth",
  [10] = "tenth",
}
local ROMAN_SEASONS = {
  [1] = "i",
  [2] = "ii",
  [3] = "iii",
  [4] = "iv",
  [5] = "v",
  [6] = "vi",
  [7] = "vii",
  [8] = "viii",
  [9] = "ix",
  [10] = "x",
}

local function new_data()
  return {
    version = 1,
    aliases = {},
    subjects = {},
  }
end

local function normalize_data(data)
  if type(data) ~= "table" then
    data = new_data()
  end
  data.version = tonumber(data.version) or 1
  if type(data.aliases) ~= "table" then
    data.aliases = {}
  end
  if type(data.subjects) ~= "table" then
    data.subjects = {}
  end
  return data
end

local function load_data()
  return normalize_data(json_store.read(STREAM_DATA_PATH))
end

local function save_data(data)
  data = normalize_data(data)
  return json_store.write(STREAM_DATA_PATH, data, {atomic = true})
end

local function trim(value)
  if not value then
    return nil
  end
  return tostring(value):match("^%s*(.-)%s*$")
end

local function first_non_empty(...)
  for i = 1, select("#", ...) do
    local value = select(i, ...)
    value = value and trim(value) or nil
    if value and value ~= "" then
      return value
    end
  end
  return nil
end

local function append_unique(list, seen, value)
  value = trim(value)
  if not value or value == "" then
    return
  end
  local key = title_guess.normalize_title(value) or value
  if seen[key] then
    return
  end
  seen[key] = true
  list[#list + 1] = value
end

local function append_infobox_value(list, seen, value)
  if not value then
    return
  end
  if type(value) == "string" then
    append_unique(list, seen, value)
    return
  end
  if type(value) ~= "table" then
    return
  end

  if value.v then
    append_infobox_value(list, seen, value.v)
  end
  if value.value then
    append_infobox_value(list, seen, value.value)
  end
  for _, item in ipairs(value) do
    append_infobox_value(list, seen, item)
  end
end

local function is_alias_key(key)
  if not key then
    return false
  end
  key = tostring(key)
  return key:find("别名", 1, true)
    or key:find("英文名", 1, true)
    or key:find("日文名", 1, true)
    or key:find("原作名", 1, true)
    or key:lower():find("alias", 1, true)
end

local function collect_subject_title_groups(subject)
  local primary_titles = {}
  local alias_titles = {}
  local seen = {}

  append_unique(primary_titles, seen, subject and subject.name_cn)
  append_unique(primary_titles, seen, subject and subject.name)

  for _, item in ipairs(subject and subject.infobox or {}) do
    if is_alias_key(item and item.key) then
      append_infobox_value(alias_titles, seen, item.value)
    end
  end

  return primary_titles, alias_titles
end

local function collect_subject_titles(subject)
  local titles = {}
  local seen = {}
  local primary_titles, alias_titles = collect_subject_title_groups(subject)

  for _, value in ipairs(primary_titles) do
    append_unique(titles, seen, value)
  end
  for _, value in ipairs(alias_titles) do
    append_unique(titles, seen, value)
  end

  return titles
end

local function append_normalized_unique(list, seen, value)
  if not value or value == "" or seen[value] then
    return
  end
  seen[value] = true
  list[#list + 1] = value
end

local function normalize_titles(titles)
  local normalized = {}
  local seen = {}
  for _, title in ipairs(titles or {}) do
    for _, value in ipairs(title_variants.normalized_variants(title)) do
      append_normalized_unique(normalized, seen, value)
    end
  end
  return normalized
end

local function merge_normalized_titles(existing, generated)
  local normalized = {}
  local seen = {}
  for _, value in ipairs(existing or {}) do
    append_normalized_unique(normalized, seen, value)
  end
  for _, value in ipairs(generated or {}) do
    append_normalized_unique(normalized, seen, value)
  end
  return normalized
end

local function title_info_normalized_variants(title_info)
  local normalized = {}
  local seen = {}
  append_normalized_unique(normalized, seen, title_info and title_info.normalized_title)
  for _, value in ipairs(title_variants.normalized_variants(title_info and title_info.title)) do
    append_normalized_unique(normalized, seen, value)
  end
  for _, value in ipairs(title_variants.normalized_variants(title_info and title_info.display_title)) do
    append_normalized_unique(normalized, seen, value)
  end
  return normalized
end

local function utf8_len(value)
  local count = 0
  for _ in tostring(value or ""):gmatch(UTF8_PATTERN) do
    count = count + 1
  end
  return count
end

local function can_fuzzy_match(normalized_title)
  if not normalized_title then
    return false
  end
  return #normalized_title >= 6 or utf8_len(normalized_title) >= 4
end

local function can_fuzzy_match_any(title_info)
  for _, value in ipairs(title_info_normalized_variants(title_info)) do
    if can_fuzzy_match(value) then
      return true
    end
  end
  return false
end

local function append_subject_tag_texts(values, subject)
  for _, tag in ipairs(subject and subject.tags or {}) do
    values[#values + 1] = tag and tag.name
  end
  for _, tag in ipairs(subject and subject.meta_tags or {}) do
    values[#values + 1] = tag
  end
end

local function has_season_marker(value, season)
  season = tonumber(season)
  if not value or not season or season <= 1 then
    return false
  end

  local normalized = title_guess.normalize_title(value)
  if not normalized then
    return false
  end

  local season_text = tostring(season)
  local season_text_zero = season < 10 and ("0" .. season_text) or season_text
  local cn = CHINESE_SEASON_NUMS[season]
  local ordinal = ENGLISH_ORDINAL_SEASONS[season]
  local roman = ROMAN_SEASONS[season]
  local markers = {
    "第" .. season_text .. "季",
    "第" .. season_text_zero .. "季",
    "第" .. season_text .. "期",
    "第" .. season_text_zero .. "期",
    "第" .. season_text .. "部",
    "第" .. season_text_zero .. "部",
    "season" .. season_text,
    "s" .. season_text,
    "part" .. season_text,
  }

  if cn then
    markers[#markers + 1] = "第" .. cn .. "季"
    markers[#markers + 1] = "第" .. cn .. "期"
    markers[#markers + 1] = "第" .. cn .. "部"
    markers[#markers + 1] = cn .. "季"
    markers[#markers + 1] = cn .. "期"
  end
  if ordinal then
    markers[#markers + 1] = ordinal .. "season"
  end
  if roman then
    markers[#markers + 1] = "season" .. roman
    markers[#markers + 1] = "s" .. roman
  end

  for _, marker in ipairs(markers) do
    if normalized:find(marker, 1, true) then
      return true
    end
  end
  return false
end

local function subject_matches_season(subject, titles, season)
  season = tonumber(season)
  if not season or season <= 1 then
    return true
  end

  local values = {}
  for _, title in ipairs(titles or {}) do
    values[#values + 1] = title
  end
  append_subject_tag_texts(values, subject)

  for _, value in ipairs(values) do
    if has_season_marker(value, season) then
      return true
    end
  end
  return false
end

local function build_subject_candidate(subject, subject_id)
  if type(subject) ~= "table" then
    return nil
  end

  local bgm_id = tonumber(subject_id or subject.id)
  if not bgm_id then
    return nil
  end

  local primary_titles = subject.primary_titles
  local alias_titles = subject.alias_titles
  if not primary_titles or not alias_titles then
    primary_titles, alias_titles = collect_subject_title_groups(subject)
  end

  local titles = subject.titles or collect_subject_titles(subject)
  local normalized_primary_titles = merge_normalized_titles(
    subject.normalized_primary_titles,
    normalize_titles(primary_titles)
  )
  local normalized_alias_titles = merge_normalized_titles(
    subject.normalized_alias_titles,
    normalize_titles(alias_titles)
  )
  local normalized_titles = merge_normalized_titles(
    subject.normalized_titles,
    normalize_titles(titles)
  )
  return {
    bgm_id = bgm_id,
    subject = subject,
    titles = titles,
    primary_titles = primary_titles,
    alias_titles = alias_titles,
    normalized_primary_titles = normalized_primary_titles,
    normalized_alias_titles = normalized_alias_titles,
    normalized_titles = normalized_titles,
    search_rank = tonumber(subject.search_rank),
  }
end

local function candidate_matches_season(candidate, season)
  return subject_matches_season(candidate and candidate.subject, candidate and candidate.titles, season)
end

local function candidate_display_name(candidate)
  local subject = candidate and candidate.subject or {}
  return first_non_empty(
    subject.name_cn,
    subject.name,
    candidate and candidate.titles and candidate.titles[1],
    candidate and candidate.bgm_id
  )
end

local function candidate_summary(candidate)
  if not candidate then
    return nil
  end
  return string.format(
    "%s/%s",
    tostring(candidate.bgm_id),
    tostring(candidate_display_name(candidate))
  )
end

local function filter_candidates_by_season(title_info, candidates)
  local season = title_info and tonumber(title_info.season) or nil
  if not season or season <= 1 then
    return candidates
  end

  local filtered = {}
  for _, candidate in ipairs(candidates or {}) do
    if candidate_matches_season(candidate, season) then
      filtered[#filtered + 1] = candidate
    end
  end
  return filtered
end

local function is_season_title_match(title_info, candidate, normalized, input_variants)
  local season = title_info and tonumber(title_info.season) or nil
  if not season or season <= 1 or not normalized or #(input_variants or {}) == 0 then
    return false
  end
  if not candidate_matches_season(candidate, season) then
    return false
  end
  for _, input in ipairs(input_variants or {}) do
    if normalized:find(input, 1, true) ~= nil
      or input:find(normalized, 1, true) ~= nil then
      return true
    end
  end
  return false
end

local function score_subject_candidate(title_info, candidate)
  local input_variants = title_info_normalized_variants(title_info)
  if #input_variants == 0 or not candidate then
    return nil
  end

  candidate.exact = false
  candidate.primary_exact = false
  candidate.alias_exact = false
  candidate.score = 0

  for _, normalized in ipairs(candidate.normalized_primary_titles or {}) do
    for _, input in ipairs(input_variants) do
      if normalized == input then
        candidate.primary_exact = true
        candidate.exact = true
      end
    end
  end

  for _, normalized in ipairs(candidate.normalized_alias_titles or {}) do
    for _, input in ipairs(input_variants) do
      if normalized == input then
        candidate.alias_exact = true
        candidate.exact = true
      end
    end
  end

  for _, normalized in ipairs(candidate.normalized_titles or {}) do
    for _, input in ipairs(input_variants) do
      if is_season_title_match(title_info, candidate, normalized, input_variants) then
        candidate.exact = true
        candidate.score = 1
      end
      candidate.score = math.max(
        candidate.score,
        utils.fuzzy_match_title(input, normalized or "")
      )
    end
  end

  return candidate
end

local function choose_scored_subject(title_info, candidates)
  local source_candidates = candidates or {}
  local source_count = #source_candidates
  local season = title_info and tonumber(title_info.season) or nil
  candidates = filter_candidates_by_season(title_info, source_candidates)
  local filtered_count = #candidates

  if source_count == 0 then
    return nil, nil, nil, nil, {code = "NoCandidates"}
  end
  if filtered_count == 0 then
    return nil, nil, nil, nil, {
      code = "SeasonFilteredAll",
      season = season,
      candidate_count = source_count,
    }
  end

  local exact_hits = {}
  local exact_count = 0
  local exact_hit = nil
  local primary_exact_hits = {}
  local primary_exact_count = 0
  local primary_exact_hit = nil
  local alias_exact_hits = {}
  local alias_exact_count = 0
  local alias_exact_hit = nil
  local best = nil
  local second = nil

  for _, candidate in ipairs(candidates or {}) do
    local scored = score_subject_candidate(title_info, candidate)
    if scored then
      if scored.exact and not exact_hits[scored.bgm_id] then
        exact_hits[scored.bgm_id] = true
        exact_count = exact_count + 1
        exact_hit = scored
      end
      if scored.primary_exact and not primary_exact_hits[scored.bgm_id] then
        primary_exact_hits[scored.bgm_id] = true
        primary_exact_count = primary_exact_count + 1
        primary_exact_hit = scored
      end
      if scored.alias_exact and not alias_exact_hits[scored.bgm_id] then
        alias_exact_hits[scored.bgm_id] = true
        alias_exact_count = alias_exact_count + 1
        alias_exact_hit = scored
      end

      if scored.score > 0 then
        if not best or scored.score > best.score then
          second = best
          best = scored
        elseif not second or scored.score > second.score then
          second = scored
        end
      end
    end
  end

  if primary_exact_count == 1 and primary_exact_hit then
    return primary_exact_hit.bgm_id, "exact", primary_exact_hit.score, primary_exact_hit
  end
  if primary_exact_count > 1 then
    return nil, nil, nil, nil, {
      code = "PrimaryExactNotUnique",
      count = primary_exact_count,
    }
  end
  if alias_exact_count == 1 and alias_exact_hit then
    return alias_exact_hit.bgm_id, "alias_exact", alias_exact_hit.score, alias_exact_hit
  end
  if alias_exact_count > 1 then
    return nil, nil, nil, nil, {
      code = "AliasExactNotUnique",
      count = alias_exact_count,
    }
  end

  if exact_count == 1 and exact_hit then
    return exact_hit.bgm_id, "exact", exact_hit.score, exact_hit
  end

  if not best then
    return nil, nil, nil, nil, {
      code = "NoTitleSimilarity",
      candidate_count = filtered_count,
      season = season,
    }
  end

  if not can_fuzzy_match_any(title_info) then
    return nil, nil, nil, nil, {
      code = "FuzzyDisabledShortTitle",
      best = candidate_summary(best),
      best_score = best.score,
    }
  end

  if best.score < FUZZY_THRESHOLD then
    return nil, nil, nil, nil, {
      code = "FuzzyBelowThreshold",
      best = candidate_summary(best),
      best_score = best.score,
      threshold = FUZZY_THRESHOLD,
    }
  end

  local second_score = second and second.score or 0
  if not second or best.bgm_id == second.bgm_id or (best.score - second_score) >= FUZZY_GAP then
    return best.bgm_id, "fuzzy", best.score, best
  end

  return nil, nil, nil, nil, {
    code = "FuzzyGapTooSmall",
    best = candidate_summary(best),
    best_score = best.score,
    second = candidate_summary(second),
    second_score = second_score,
    gap = best.score - second_score,
    required_gap = FUZZY_GAP,
  }
end

local function choose_unique_season_search_subject(title_info, candidates)
  local season = title_info and tonumber(title_info.season) or nil
  if not season or season <= 1 then
    return nil, nil, nil, nil, {code = "SeasonUniqueNotApplicable"}
  end
  if not can_fuzzy_match_any(title_info) then
    return nil, nil, nil, nil, {code = "SeasonUniqueShortTitle"}
  end

  local filtered = filter_candidates_by_season(title_info, candidates)
  local seen = {}
  local count = 0
  local hit = nil
  for _, candidate in ipairs(filtered or {}) do
    if not seen[candidate.bgm_id] then
      seen[candidate.bgm_id] = true
      count = count + 1
      hit = candidate
    end
  end

  if count == 1
    and hit
    and hit.search_rank
    and hit.search_rank <= SEARCH_RANK_SEASON_UNIQUE_LIMIT then
    return hit.bgm_id, "season_unique", 1, hit
  end

  return nil, nil, nil, nil, {
    code = "SeasonUniqueNotSatisfied",
    season = season,
    count = count,
    hit = candidate_summary(hit),
    rank = hit and hit.search_rank,
    rank_limit = SEARCH_RANK_SEASON_UNIQUE_LIMIT,
  }
end

local function alias_key(title_info)
  local keys = {}
  local seen = {}
  local function append_key(key)
    if key and key ~= "" and not seen[key] then
      seen[key] = true
      keys[#keys + 1] = key
    end
  end

  if not title_info then
    return nil
  end
  local season_hint = title_info.season_hint or "s1"
  append_key(title_info.alias_key)
  for _, normalized in ipairs(title_info_normalized_variants(title_info)) do
    append_key(normalized .. "|" .. season_hint)
  end
  return keys[1], keys
end

local function alias_keys(title_info)
  local _, keys = alias_key(title_info)
  return keys or {}
end

local function save_alias(data, title_info, bgm_id, source)
  local keys = alias_keys(title_info)
  bgm_id = tonumber(bgm_id)
  if #keys == 0 or not bgm_id then
    return false
  end

  local ok = false
  for _, key in ipairs(keys) do
    local existing = data.aliases[key]
    local existing_id = existing and tonumber(existing.bgm_id) or nil
    if existing and existing.source == "manual" and existing_id ~= bgm_id then
      -- 不覆盖用户对同一个简繁 key 做过的手动绑定。
    elseif existing and existing.source == "manual" and source ~= "manual" then
      ok = true
    else
      data.aliases[key] = {
        bgm_id = bgm_id,
        title = title_info.title or title_info.display_title,
        source = source or "auto",
        updated_at = os.time(),
      }
      ok = true
    end
  end
  return ok
end

local function alias_matches_requested_season(data, title_info, entry)
  local season = title_info and tonumber(title_info.season) or nil
  if not season or season <= 1 then
    return true
  end
  if entry and entry.source == "manual" then
    return true
  end

  local subject = entry and data.subjects and data.subjects[tostring(entry.bgm_id)] or nil
  local candidate = build_subject_candidate(subject, entry and entry.bgm_id)
  return candidate and candidate_matches_season(candidate, season) or false
end

local function upsert_subject(data, subject)
  local bgm_id = subject and tonumber(subject.id)
  if not bgm_id then
    return false
  end

  local primary_titles, alias_titles = collect_subject_title_groups(subject)
  local titles = collect_subject_titles(subject)
  local normalized_primary = normalize_titles(primary_titles)
  local normalized_alias = normalize_titles(alias_titles)
  local normalized = normalize_titles(titles)
  data.subjects[tostring(bgm_id)] = {
    titles = titles,
    primary_titles = primary_titles,
    alias_titles = alias_titles,
    normalized_primary_titles = normalized_primary,
    normalized_alias_titles = normalized_alias,
    normalized_titles = normalized,
    updated_at = os.time(),
  }
  return true
end

function M.get_alias(title_info)
  local data = load_data()
  for _, key in ipairs(alias_keys(title_info)) do
    local entry = data.aliases[key]
    if entry and entry.bgm_id and alias_matches_requested_season(data, title_info, entry) then
      return entry
    end
  end
  return nil
end

function M.match_subject(title_info)
  local data = load_data()
  local normalized_title = title_info and title_info.normalized_title or nil
  if not normalized_title then
    return nil
  end

  local candidates = {}
  for subject_id, subject in pairs(data.subjects or {}) do
    local candidate = build_subject_candidate(subject, subject_id)
    if candidate then
      candidates[#candidates + 1] = candidate
    end
  end

  local bgm_id, mode, score = choose_scored_subject(title_info, candidates)
  if bgm_id then
    local source = (mode == "exact" or mode == "alias_exact") and "subject_alias" or "subject_fuzzy"
    save_alias(data, title_info, bgm_id, source)
    save_data(data)
    return bgm_id, source, score
  end

  return nil
end

function M.match_subject_candidates(title_info, subjects, source_prefix)
  local candidates = {}
  for _, subject in ipairs(subjects or {}) do
    local candidate = build_subject_candidate(subject)
    if candidate then
      candidates[#candidates + 1] = candidate
    end
  end

  local bgm_id, mode, score, hit, reason = choose_scored_subject(title_info, candidates)
  if not bgm_id and source_prefix == "search" then
    local fallback_reason
    bgm_id, mode, score, hit, fallback_reason = choose_unique_season_search_subject(title_info, candidates)
    if not bgm_id and fallback_reason and fallback_reason.code == "SeasonUniqueNotSatisfied" then
      reason = fallback_reason
    end
  end
  if not bgm_id then
    return nil, nil, nil, nil, reason
  end

  source_prefix = source_prefix or "subject"
  return bgm_id, source_prefix .. "_" .. mode, score, hit and hit.subject or nil
end

function M.bind_subject(title_info, bgm_id, subject, source)
  local data = load_data()
  if subject then
    upsert_subject(data, subject)
  end
  if not save_alias(data, title_info, bgm_id, source or "manual") then
    return false
  end
  return save_data(data)
end

function M.save_subject(subject)
  local data = load_data()
  if not upsert_subject(data, subject) then
    return false
  end
  return save_data(data)
end

function M.get_path()
  return STREAM_DATA_PATH
end

function M.collect_subject_titles(subject)
  return collect_subject_titles(subject)
end

function M.normalize_titles(titles)
  return normalize_titles(titles)
end

return M
