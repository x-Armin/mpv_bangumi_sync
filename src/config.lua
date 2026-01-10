local Options = require "src.options"

local M = {}

-- 配置对象
M.config = {
  access_token = Options.bgm_access_token,
  storages = Options.storages_list,
}

return M
