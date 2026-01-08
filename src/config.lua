local Options = require "src.options"

local M = {}

-- 配置对象
M.config = {
  access_token = Options.bgm_access_token,
  storages = Options.storages_list,
  dandanplay_appid = Options.dandanplay_appid,
  dandanplay_appsecret = Options.dandanplay_appsecret,
}

return M
