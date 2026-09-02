# 选选鸭 iOS Demo

SwiftUI 原生 iOS 演示版，包含鸭鸭 AI 决策聊天、用户画像、决策历史和 LiveKit 1v1 视频通话入口。

## 运行

1. 用 Xcode 15 或更高版本打开 `选选鸭.xcodeproj`。
2. 选择 `选选鸭` scheme 和 iPhone 模拟器或真机。
3. 本地配置在 `Config.local.xcconfig`，该文件已被 `.gitignore` 忽略。
4. 运行 App 后默认进入启动动效，再进入聊天页。

## 配置项

`Config.example.xcconfig` 会可选包含 `Config.local.xcconfig`。

- `OPENROUTER_API_KEY`: OpenRouter 密钥。
- `OPENROUTER_MODEL`: 默认 `deepseek/deepseek-v4-flash-0731`。
- `OPENROUTER_STT_MODEL`: 默认 `openai/gpt-4o-mini-transcribe`。
- `LIVEKIT_WS_URL`: LiveKit 房间服务地址。
- `LIVEKIT_PARTICIPANT_TOKEN`: 演示用 participant token。

## 注意

当前是客户端直连演示版，适合本机验证产品体验。生产版本应增加后端代理 OpenRouter、签发 LiveKit token、接入好友呼叫和推送通知。

