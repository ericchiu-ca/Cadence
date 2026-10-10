# App Store listing

What goes into App Store Connect for Cadence 1.0.0. Keep this file in step with what is live.

| Field | Value |
| --- | --- |
| Name | Cadence: Offline Music |
| Bundle ID | `io.github.ericchiuca.cadence` |
| SKU | `cadence-ios` |
| Primary language | English (U.S.), with Simplified Chinese |
| Category | Music (secondary: Entertainment) |
| Price | Free |
| Devices | iPhone, iPad (iPhone Duo supported through adaptive layouts) |
| Age rating | 9+ (infrequent profanity and mature themes, because song lyrics can contain them) |
| Support URL | https://github.com/ericchiu-ca/Cadence/issues |
| Marketing URL | https://github.com/ericchiu-ca/Cadence |
| Privacy Policy URL | https://github.com/ericchiu-ca/Cadence/blob/main/docs/PRIVACY.md |
| App Privacy | Data Not Collected |
| Export compliance | Uses only exempt encryption (HTTPS); `ITSAppUsesNonExemptEncryption = NO` |
| Content rights | Yes, it shows third-party content: lyrics fetched from LRCLIB when a song has none of its own |
| Availability | 174 countries and regions: every App Store region except China mainland |
| Release | Automatically after approval |
| App Review contact | Set in App Store Connect (private to Apple, not kept here) |

## English (U.S.)

**Subtitle** (30): Your music, beautifully played

**Promotional text** (170):
A music player for the files you own — FLAC, ALAC, MP3 and more — with an artwork-coloured Now Playing screen, word-by-word synced lyrics and no account, ads or tracking.

**Description:**

Cadence plays the music you already own, and makes it a pleasure to listen to.

Drop your songs into the Cadence folder in Files or iCloud Drive and they show up as a library: albums, artists, playlists and everything you added recently, with the artwork from your files.

NOW PLAYING
• A full-screen player that takes its colours from the artwork and moves gently while the music plays
• Pull it down from anywhere to get back to your library
• Swipe the artwork to skip, and see the next and previous covers slide in

LYRICS
• Synced lyrics that fill word by word, in time with the song
• Tap any line to jump to it
• Lyrics embedded in your files, or fetched for you when there are none

PLAYBACK
• Gapless playback, and a 16-band equaliser with presets
• FLAC, ALAC, AAC, MP3, WAV, AIFF, Opus, Ogg Vorbis, DSD and more
• Repeat, repeat one, shuffle, sleep timer, AirPlay and lock-screen controls
• Siri, widgets and Share-to-Cadence from other apps

MADE FOR EVERY SCREEN
• iPhone, iPad in portrait and landscape, and iPhone Duo
• Light and dark appearance, with an app icon for each

PRIVATE BY DESIGN
• No account, no ads, no analytics, no tracking
• Your library stays on your device or in your own iCloud Drive

Cadence is open source under the GPL and based on Cosmos Music Player. The code is on GitHub: github.com/ericchiu-ca/Cadence

**Keywords** (100):
flac,alac,offline,mp3,lyrics,local,player,equalizer,gapless,hi-res,audio,library,dsd,files,icloud

**What's New:** First release.

## 简体中文

**副标题**（30）：好好听你自己的音乐

**推广文本**（170）：
为你自己的音乐文件打造的播放器：支持 FLAC、ALAC、MP3 等格式，播放界面随封面取色，歌词逐字同步，无需账号，没有广告和追踪。

**描述：**

Cadence 播放你已经拥有的音乐，并让聆听成为一种享受。

把歌曲放进"文件"或 iCloud 云盘里的 Cadence 文件夹，它们就会整理成音乐库：专辑、艺人、播放列表和最近添加，封面直接取自你的文件。

正在播放
• 全屏播放界面随封面取色，音乐播放时背景轻轻流动
• 在任意位置下拉即可回到音乐库
• 左右滑动封面切歌，前后两首的封面随手势滑入

歌词
• 逐字填充的同步歌词，紧跟歌曲节奏
• 点任意一行即可跳转
• 支持文件内嵌歌词，没有时自动为你获取

播放
• 无缝播放，16 段均衡器和多种预设
• 支持 FLAC、ALAC、AAC、MP3、WAV、AIFF、Opus、Ogg Vorbis、DSD 等格式
• 列表循环、单曲循环、随机播放、睡眠定时、隔空播放和锁屏控制
• 支持 Siri、小组件，以及从其他应用"共享到 Cadence"

适配每一块屏幕
• iPhone、iPad 横竖屏，以及 iPhone Duo
• 浅色和深色外观，各有一套应用图标

隐私优先
• 无需账号，没有广告、统计分析和追踪
• 音乐库只保存在你的设备或你自己的 iCloud 云盘

Cadence 以 GPL 协议开源，基于 Cosmos Music Player 开发，代码托管在 GitHub：github.com/ericchiu-ca/Cadence

**关键词**（100）：
无损,FLAC,ALAC,离线,本地音乐,播放器,歌词,均衡器,无缝播放,高解析,音频,DSD,文件,iCloud

**新功能：** 首个版本。

## App Review notes

Cadence plays audio files the user adds through the Files app, iCloud Drive or the Share sheet. To review it without your own files, open Files › On My iPhone › Cadence and add any audio file (FLAC, MP3, M4A…), or share one to Cadence from another app; the library refreshes automatically. No sign-in is required. Online lookups are limited to lyrics from LRCLIB.

## Screenshots

`docs/appstore/promo/` holds what is uploaded, one set per language:

| Slot | Size | Images |
| --- | --- | --- |
| iPhone 6.1"/6.3" (medium display, `APP_IPHONE_61`) | 1206 × 2622 | player, lyrics, library, album, queue |
| iPad 13" (`APP_IPAD_PRO_3GEN_129`) | 2064 × 2752 | player, lyrics, library |

Each image is a caption over a framed capture on a wash of the capture's own colours. The captures themselves are in `docs/appstore/` and come from the simulator with a demo library whose artwork, music and lyrics were generated for the purpose. To rebuild the promo images after replacing a capture:

```sh
swift docs/appstore/make-promo.swift docs/appstore docs/appstore/promo
```

The captions are in `make-promo.swift`. No iPhone Duo screenshots yet; that slot is optional.
