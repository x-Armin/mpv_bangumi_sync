# mpv_bangumi_sync

在 mpv 中自动同步 Bangumi 追番进度。

（由于本项目依赖弹弹play API匹配番剧信息，但目前还没有申请到AppId 和 AppSecret，所以目前还不可用，不过如果你有id可以直接填上，已经验证功能是可用的）

## 功能
- 自动识别番剧并匹配到 Bangumi
- 自动同步 Bangumi 追番进度
- 支持手动匹配与搜索

## 依赖
- **curl**（HTTP 请求）
- **ffprobe**（视频信息提取）

## 安装
把仓库克隆或下载 zip 解压到mpv的插件目录，mpv-lazy如下：
```
mpv-lazy/portable_config/scripts/mpv_bangumi_sync
```

## 配置
在 mpv 配置目录创建 `script-opts/mpv_bangumi_sync.conf`：
```
portable_config/script-opts/mpv_bangumi_sync.conf
```

示例配置：
```conf
# Bangumi 访问令牌（必需）
# 获取地址：https://next.bgm.tv/demo/access-token
bgm_access_token=你的访问令牌

# 番剧存储目录（多个目录用分号/冒号分隔）
storages=D:/Anime;E:/Anime

# dandanplay 应用ID/密钥（可选）
# dandanplay_appid=123456
# dandanplay_appsecret=你的密钥
```

## 使用
- 播放视频后会自动匹配并在进度到 80% 时标记为“已看”
- `Alt+o` 打开当前番剧 Bangumi 页面
- `Alt+m` 手动匹配番剧

## 数据目录
- `portable_config/mpv_bangumi_sync_data/`

## 注意
- 插件只在 `storages` 指定的目录下生效

## 后续开发计划
1. 适配补番逻辑，避免短时间每集都标记一次导致刷屏 Bangumi 时间线
2. 适配 uosc，添加按钮弹出同步信息窗口，例如：
```
 番剧：葬送的芙莉莲
 进度：12 / 28
 状态：在看
 标记看过
 打开 Bangumi
```

## 感谢
本项目大量借用 [mpv_bangumi](https://github.com/slqy123/mpv_bangumi)，在此基础上重构了弹弹play匹配与 HTTP 接口，移除了对 Python 和闭源可执行程序的依赖。
