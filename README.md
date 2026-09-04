# 选选鸭

纠结的事，交给鸭鸭帮你拍板。

选选鸭是一只软萌、会拍板的卡通小黄鸭决策搭子（SwiftUI 原生 iOS Demo）。在「吃什么、买哪个、要不要去、周末去哪」这类日常纠结里，用**聊天 / 语音 / 视频**帮用户落地选择；画像与测验结果会回填决策标签，影响后续建议。

当前为**客户端直连演示版**：密钥放在本机 `Config.local.xcconfig`，适合验证产品体验，不适合直接当生产架构。

演示视频：https://drive.google.com/file/d/1-7Xj1grG4skVJMz06LQCWQGkbFydqbx1/view?usp=sharing 


---

## 功能一览

底部四个 Tab：**聊天** · **通话** · **囤粮** · **我的**

| 场景 | 用户看到什么 | 核心实现 |
|------|-------------|---------|
| 决策聊天 | 流式对话 + A/B 拍板按钮 | OpenRouter SSE + `<<<OPTIONS>>>` |
| 续聊芯片 | 轻量话题入口，不记决策历史 | OpenRouter SSE + `<<<CHIPS>>>` |
| 图文 / 视频聊 | 最多 9 图或 1 视频，需配文字 | Vision 模型多模态 |
| 语音输入 | 麦 → 转文字进输入框 | OpenRouter STT |
| 语音通话 | 和鸭鸭打电话商量 | 百炼 Qwen Omni Realtime |
| 视频通话 | 鸭鸭看得见你的选项 | Omni + 本地相机抽帧 |
| 囤粮 | 谷粒直购包 / 月卡 / 流水 | 本地钱包（无真实 IAP） |
| 我的 | 画像、洞察、决策历史 | SwiftData + OpenRouter |
| 鸭鸭试题库 | 4 套测验，可回填标签 | 本地计分 + 流式分析 |

---

## 场景与实现方式

### 1. 决策聊天

**入口**：聊天 Tab · `Views/ChatView.swift`  
**编排**：`Services/ChatViewModel.swift`  
**API**：`Services/OpenRouterClient.streamDecision`（SSE）

流程：

1. 发送前 `GrainWalletService.consumeChatRound`（先扣今日免费轮次，再扣 1 谷粒/轮）。
2. 插入 user 消息 + 未完成 assistant，流式追加正文。
3. 模型在正文尾部输出结构化块：
   - **真正二选一拍板** → `<<<OPTIONS>>>` … `<<<END>>>`（决策按钮，可记历史）。
   - **闲聊 / 求建议 / 继续聊** → `<<<CHIPS>>>` … `<<<END>>>`（续聊芯片，不记历史）。
4. 两者互斥；冲突时以 OPTIONS 为准。若用户明显在拍板但模型没给按钮，`UserChoiceIntent.fallbackDecision` 会补一套 OPTIONS。
5. 点决策选项可「确认拍板」写 `DecisionRecord`，或点「我还没有纠结好」继续追问。
6. 推荐项会标「荐」；旧交互按钮在用户另开话题后会过期展示。

冷启动时 `recoverInterruptedGenerations` 可续传未完成回复，且不重复扣谷粒。

**人设**：`DuckSpeech`（自称「鸭鸭」，口语、emoji，禁止 markdown）；展示前经 `DuckTextSanitizer` 清理。

---

### 2. 续聊芯片

- `ChatMessage.interactionKind == .chips`
- 点选等同填入输入并发送；用于「怎么做 / 下一步 / 换个角度」这类递进闲聊
- 不写入决策历史；后续新消息会使旧芯片过期

---

### 3. 附件与语音输入

| 能力 | 实现 |
|------|------|
| 图片 / 视频 | `AttachmentStore` + 系统相册；有媒体时走 `OPENROUTER_VISION_MODEL` |
| 引用回复 | 长按菜单；prompt 带引用语境 |
| 语音转文字 | `AudioRecorder` → `OpenRouterClient.transcribeAudio` → 写入输入框（不作为聊天附件） |

---

### 4. 语音 / 视频通话

**入口**：通话 Tab · `Views/CallView.swift`  
**编排**：`Services/LiveKitCallViewModel.swift`（命名遗留；实际优先 Omni）  
**实时链路**：

| 组件 | 职责 |
|------|------|
| `QwenOmniRealtimeClient` | DashScope WebSocket Realtime 会话 |
| `RealtimePCMEngine` | 麦克风上行 16 kHz PCM、播放下行 24 kHz |
| `LocalCameraPreview` | 本地预览（视频） |
| `CallFrameSampler` | 约 1 fps JPEG 抽帧给 Omni（视频） |

**启动优先级**：

1. 已配置 `DASHSCOPE_API_KEY` → **Qwen Omni Realtime**（真正和鸭鸭说话）
2. 否则有 LiveKit 凭证 → LiveKit 房间（遗留降级）
3. 视频且以上皆无 → 仅本地摄像头预览（无 AI 对话）

**计费**：挂断时 `GrainWalletService.consumeCall`（先扣免费分钟，再按分钟扣谷粒；`ceil(秒/60)`，至少 1 分钟）。

**通话人设**：`DuckSpeech.callPersona`（更短，适合 TTS）。  
**音色**：`QWEN_OMNI_VOICE`（默认 `Qiao`）；大厅文案只写「和鸭鸭打电话商量」，不暴露供应商音色名。

#### 通话行为细节

| 行为 | 做法 |
|------|------|
| 半双工 | 鸭鸭说话时压制真实麦上行，改发静音帧保活，避免回采触发 VAD 打断 |
| 手动打断 | 「打断」→ `response.cancel` + 清空播放 + 恢复倾听 |
| 自动打断 | 开播约 0.9s 宽限期后，本地 RMS 清晰人声累计约 ≥400ms 才打断 |
| 静音 | 上行全 0 PCM，帮助服务端 VAD 收束；不强制 `response.create`（避免与 server VAD 撞车） |
| Session | `server_vad`，`interrupt_response: true`，静音约 600ms 收束，`idle_timeout_ms` 合法上限 30s |
| 视频约束 | 须先有音频再 append 图片；接通时 primer 静音 + 打招呼期间压制上行 |
| 轮次 UI | 打断 / 在听你 / 听你说 |

> qwen3.5-omni 音色请用 `Qiao` / `Serena` / `Tina` 等官方表内值；旧音色 `Cherry` 会 HTTP 400。

---

### 5. 囤粮（谷粒经济）

**入口**：囤粮 Tab · `Views/RechargeCenterView.swift`  
**目录**：`Models/GrainCatalog.swift` · `Models/GrainWalletModels.swift`  
**服务**：`Services/GrainWalletService.swift`

| 项目 | 数值 |
|------|------|
| 聊天 | 1 谷粒 / 轮 |
| 语音通话 | 2 谷粒 / 分钟 |
| 视频通话 | 5 谷粒 / 分钟 |
| 每日免费聊天 | 8 轮 |
| 每日免费通话 | 3 分钟 |
| 扣费顺序 | 会员赠送 → 充值赠送 → 付费谷粒 |

分段：**临时补粮**（直购包）· **鸭粮月卡** · **流水**。  
Demo 内「购买」为本地入账，无真实 App Store IAP。谷粒用尽时会弹出 Sheet 引导去囤粮。

---

### 6. 我的（画像与历史）

**入口**：我的 Tab · `Views/ProfileView.swift`

- 昵称、个性签名、决策标签、偏好、常纠结场景
- 「鸭鸭眼中的你」：`OpenRouterClient.streamProfileInsight` → `duckSummary`
- 决策历史分页（约 5 条/页）
- 头像裁剪：`AvatarCropView`
- 入口进入「鸭鸭试题库」

画像标签会影响后续聊天 / 通话建议；清空总结不影响偏好与决策历史。

---

### 7. 鸭鸭试题库

**入口**：我的 → 鸭鸭试题库 · `Views/QuizHubView.swift`  
**题库**：`Models/QuizCatalog.swift`

四套题：决策风格人格 · 鸭鸭版 MBTI · 选择困难症指数 · 个人偏好雷达。

流程：本地 `QuizLocalScorer` 计分 → `OpenRouterClient.streamQuizAnalysis` 流式解读 → 可选「采用并回填标签」写入 `UserProfile.decisionTags`。

---

## 架构与技术栈

```
┌─────────────┐     OpenRouter SSE      ┌──────────────────┐
│  聊天 / 测验 │ ─────────────────────► │ Qwen3.5 / VL / STT│
│  画像 / STT  │                        └──────────────────┘
└─────────────┘
┌─────────────┐   DashScope WebSocket   ┌──────────────────┐
│ 语音 / 视频  │ ─────────────────────► │ Qwen Omni Realtime│
│    通话      │   PCM + 可选 JPEG 帧    └──────────────────┘
└─────────────┘
┌─────────────┐                         ┌──────────────────┐
│ 囤粮 / 画像  │ ◄──── SwiftData ──────► │ 本地持久化        │
└─────────────┘                         └──────────────────┘
```

| 层 | 技术 |
|----|------|
| UI | SwiftUI，iOS 17+ |
| 持久化 | SwiftData（画像、消息、决策、钱包、月卡、流水、测验结果） |
| 聊天 / 测验 / 画像 / STT | OpenRouter |
| 实时通话 | 阿里云百炼 DashScope · Qwen Omni Realtime |
| 音频 | `AVAudioEngine`（`RealtimePCMEngine`） |
| 视频输入 | `AVCaptureSession` + `CallFrameSampler` |
| 遗留降级 | LiveKit Swift SDK（工程内仍保留） |
| 配置 | xcconfig → Info.plist → `AppConfig` |

**默认模型（可被 xcconfig 覆盖）**：

| 用途 | 默认 |
|------|------|
| 聊天 | `qwen/qwen3.5-flash-02-23` |
| 视觉 | `qwen/qwen3-vl-30b-a3b-instruct` |
| 语音转写 | `openai/gpt-4o-mini-transcribe` |
| 实时通话 | `qwen3.5-omni-flash-realtime` |
| 通话音色 | `Qiao` |

---

## 运行与配置

1. 用 Xcode 15+ 打开 `选选鸭.xcodeproj`，选择 scheme `选选鸭`。
2. 复制示例配置到本机私密文件（已被 `.gitignore`）：

```bash
cp Config.example.xcconfig Config.local.xcconfig
```

3. 在 `Config.local.xcconfig` 填入密钥后运行（模拟器或真机）。

| 配置项 | 用途 |
|--------|------|
| `OPENROUTER_API_KEY` | 聊天 / 测验 / 画像 / STT（要聊天必填） |
| `OPENROUTER_MODEL` | 文本模型 |
| `OPENROUTER_VISION_MODEL` | 多模态模型 |
| `OPENROUTER_STT_MODEL` | 语音转写模型 |
| `DASHSCOPE_API_KEY` | Omni 通话（有则优先走实时鸭鸭） |
| `QWEN_OMNI_MODEL` | 实时模型名 |
| `QWEN_OMNI_VOICE` | 音色参数（默认 Qiao） |
| `QWEN_OMNI_WS_URL` | Realtime WebSocket（国内 / 新加坡） |
| `LIVEKIT_WS_URL` / `LIVEKIT_PARTICIPANT_TOKEN` | 无 DashScope 时的降级房间 |

**注意**：

- xcconfig 会把 `//` 当注释。WebSocket 请写成 `wss:/$()/dashscope...`；`AppConfig.normalizedWebSocketURL` 会修复被截断的 `wss:`。
- 国内默认 `wss://dashscope.aliyuncs.com/api-ws/v1/realtime`；新加坡可改 intl 域名。
- 真机需相机 / 麦克风权限（工程内已配用途说明）。

---

## 目录结构

```
选选鸭/
├── Config.example.xcconfig          # 配置模板（无密钥）
├── Config.local.xcconfig            # 本机密钥（gitignore）
├── 选选鸭.xcodeproj/
└── 选选鸭/
    ├── 选选鸭App.swift              # @main + ModelContainer
    ├── Info.plist                   # xcconfig 键注入
    ├── Models/
    │   ├── AppModels.swift          # 人设、消息、画像、决策
    │   ├── GrainCatalog.swift       # 费用与商品
    │   ├── GrainWalletModels.swift
    │   └── QuizCatalog.swift
    ├── Services/
    │   ├── AppConfig.swift
    │   ├── OpenRouterClient.swift   # 聊天 / 测验 / 画像 / STT
    │   ├── ChatViewModel.swift
    │   ├── QwenOmniRealtimeClient.swift
    │   ├── LiveKitCallViewModel.swift
    │   ├── RealtimePCMEngine.swift
    │   ├── CallFrameSampler.swift
    │   ├── LocalCameraPreview.swift
    │   ├── GrainWalletService.swift
    │   ├── AttachmentStore.swift
    │   └── AudioRecorder.swift
    └── Views/
        ├── RootView.swift           # Splash + Tab
        ├── ChatView.swift
        ├── CallView.swift
        ├── RechargeCenterView.swift
        ├── ProfileView.swift
        └── QuizHubView.swift
```

---

## 聊天交互协议（模型侧）

助手正常说话后，可选附加其一：

```text
<<<OPTIONS>>>
选项A
选项B
<<<END>>>
```

```text
<<<CHIPS>>>
接着聊：……
换个角度：……
<<<END>>>
```

客户端解析后渲染按钮 / 芯片，并从可见正文中裁掉标记。用户侧「我还没有纠结好」由 UI 在决策按钮末尾自动追加。

---

## 已知限制与生产注意

- 密钥在客户端，仅适合 Demo；生产应后端代理 OpenRouter / DashScope，并签发短时凭证。
- 囤粮为本地模拟入账，无真实支付与账务对账。
- LiveKit 路径仍保留，但主通话体验已切到 Omni Realtime。
- Omni 会话参数（如 `idle_timeout_ms`）受服务端合法范围约束，过大会握手失败。
- 无好友呼叫、推送、账号体系；当前为单机鸭鸭陪聊 / 陪拍板。
