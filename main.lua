require "src.options"
local bgm = require "src.bgm"
local mp_utils = require "mp.utils"
local utils = require "src.utils"
local input = require "mp.input"

-- global variables
AnimeInfo = nil
UpdateEpisodeTimer = nil
BangumiSucessFlag = 0
MatchResults = nil

local function reset_globals()
  AnimeInfo = nil
  if UpdateEpisodeTimer then
    UpdateEpisodeTimer:kill()
    UpdateEpisodeTimer = nil
  end
  BangumiSucessFlag = 0
  MatchResults = nil
end

local function init_after_bangumi_id()
  bgm.update_bangumi_collection().async {
    resp = function(resp)
      if resp.update_message then
        mp.osd_message(resp.update_message, 3)
      else
        mp.msg.verbose "Collection status unchanged"
      end
      BangumiSucessFlag = BangumiSucessFlag + 1
    end,
    err = function(err)
      mp.msg.error("更新Bangumi条目失败:", err)
    end,
  }
  bgm.fetch_episodes().async {
    resp = function(_)
      mp.msg.verbose "Fetch episodes success"
      BangumiSucessFlag = BangumiSucessFlag + 1
    end,
    err = function(err)
      mp.msg.error("获取剧集信息失败:", err)
    end,
  }
  UpdateEpisodeTimer = mp.add_periodic_timer(5, function()
    local current_time = mp.get_property_number "time-pos"
    local total_time = mp.get_property_number "duration"
    if not current_time or not total_time then
      return
    end
    local ratio = current_time / total_time
    if ratio < 0.8 then
      return
    end
    if BangumiSucessFlag ~= 2 then
      mp.msg.verbose "Bangumi collection or episodes not updated or failed, skip update."
      return
    end
    if UpdateEpisodeTimer then
      UpdateEpisodeTimer:kill()
      UpdateEpisodeTimer = nil
      bgm.update_episode().async {
        resp = function(data)
          if data.skipped then
            mp.msg.verbose "同步Bangumi追番记录进度成功（无需更新）"
            mp.osd_message("同步Bangumi追番记录进度成功（无需更新）")
          else
            mp.msg.info "同步Bangumi追番记录进度成功"
            mp.osd_message("同步Bangumi追番记录进度成功")
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

local function init(episode_id)
  reset_globals()
  bgm.match(episode_id).async {
    resp = function(data)
      -- 处理匹配结果（如果有多个匹配，让用户选择）
      if data and data.matches and #data.matches > 1 then
        mp.msg.info "匹配结果不唯一，请手动选择"
        mp.osd_message("匹配结果不唯一，请手动选择", 3)
        MatchResults = data.matches
        return
      end

      bgm.update_metadata().async {
        resp = function(anime_info)
          if not anime_info or not anime_info.bgm_id then
            mp.msg.error "获取番剧元信息失败"
            return
          end
          AnimeInfo = anime_info
          mp.msg.verbose(
            "Bangumi ID:",
            anime_info.bgm_id,
            "Bangumi Url:",
            anime_info.bgm_url
          )
          init_after_bangumi_id()
        end,
      }
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
  ["Alt+o"] = { "open-bangumi-url" },
  ["Alt+m"] = { "manual-match" },
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

mp.register_script_message("manual-match", function()
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
            init(selected_episode.id)
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
      init(selected_match.episodeId)
    end,
    closed = function()
      mp.set_property("pause", "no")
    end,
  }
end)
