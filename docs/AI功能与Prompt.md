# 选选鸭 · AI 功能实现与 Prompt

本文分两块：

1. **AI 工程实现**（流式、解析、多模态、Realtime 半双工 / VAD、兜底、可靠性）——给工程师看「怎么做稳」
2. **Prompt / 指令原文**——给人设与文案迭代看「怎么写」

产品总览见 [README.md](./README.md)。

> 源码真相以仓库为准：
> - `选选鸭/Models/AppModels.swift` → `DuckSpeech`
> - `选选鸭/Services/OpenRouterClient.swift`（SSE、解析、意图兜底）
> - `选选鸭/Services/ChatViewModel.swift`（发送、续传、落库）
> - `选选鸭/Services/QwenOmniRealtimeClient.swift` / `RealtimePCMEngine` / `CallFrameSampler` / `LiveKitCallViewModel`

---

## 总览

| 功能 | 通道 | 模型（默认） | 入口 |
|------|------|--------------|------|
| 决策聊天 / 续聊芯片 | OpenRouter Chat Completions SSE | `qwen/qwen3.5-flash-02-23` | 聊天 Tab |
| 图文 / 视频理解 | 同上，换 Vision 模型 | `qwen/qwen3-vl-30b-a3b-instruct` | 聊天带附件 |
| 确认拍板 / 未纠结好追问 | OpenRouter SSE | 文本模型 | 决策按钮 |
| 鸭鸭眼中的你 | OpenRouter SSE | 文本模型 | 我的 · 保存画像 / 刷新 |
| 试题库解读 | OpenRouter SSE | 文本模型 | 鸭鸭试题库 |
| 语音转文字 | OpenRouter Audio Transcriptions | `openai/gpt-4o-mini-transcribe` | 输入栏麦克风 |
| 实时语音 / 视频通话 | 百炼 DashScope Omni WebSocket | `qwen3.5-omni-flash-realtime` | 通话 Tab |

共性约定：

- **人设统一**：文本能力挂 `DuckSpeech.persona`，通话挂更短的 `DuckSpeech.callPersona`。
- **禁止 markdown**：Prompt 与人设都反复强调；展示层再用 `DuckTextSanitizer` 兜底。
- **结构化输出用标记块**，不用 Function Calling / JSON mode：`<<<OPTIONS>>>` / `<<<CHIPS>>>` … `<<<END>>>`。
- **客户端是控制面**：意图兜底、去重、半双工、本地 barge-in、会话保活都在 App 侧，不假设模型 100% 听话。

---

# Part A · AI 工程实现

## A1. 双通道架构

```
┌──────────────── Chat / 测验 / 画像 / STT ────────────────┐
│  ChatViewModel                                           │
│       │                                                  │
│       ▼                                                  │
│  OpenRouterClient.streamChat                             │
│       │  HTTPS SSE  bytes.lines                          │
│       ▼                                                  │
│  DecisionStreamParser / DuckTextSanitizer                │
│       │                                                  │
│       ▼                                                  │
│  SwiftData ChatMessage（isIncomplete / interactionKind） │
└──────────────────────────────────────────────────────────┘

┌──────────────── 实时语音 / 视频 ─────────────────────────┐
│  LiveKitCallViewModel（编排；命名遗留）                    │
│       ├── RealtimePCMEngine（16k↑ / 24k↓ PCM16）          │
│       ├── CallFrameSampler（≈1fps JPEG，maxSide 640）     │
│       └── QwenOmniRealtimeClient（WSS Realtime 事件）     │
│                turn: server_vad + 本地 RMS barge-in       │
│                duplex: suppressMicrophoneUplink 半双工     │
└──────────────────────────────────────────────────────────┘
```

设计取舍：

| 点 | 选择 | 原因 |
|----|------|------|
| 聊天结构化 | 标记块而非 tool call | 流式友好；中途可裁掉尾巴；实现简单 |
| 通话 | Omni Realtime 优先，LiveKit 降级 | 真正「和鸭鸭说话」；LiveKit 仅遗留房间路径 |
| 推理 | `reasoning.effort = none` + `exclude` | 决策聊天要低延迟，关掉 thinking 外泄 |
| Provider | `provider.sort = throughput` | OpenRouter 侧偏吞吐路由 |

---

## A2. OpenRouter 流式管线

### 请求形态

- Endpoint：`POST https://openrouter.ai/api/v1/chat/completions`
- `Accept: text/event-stream`，`URLSession.bytes` 按行读 SSE
- `timeoutInterval = 120`，`cachePolicy = reloadIgnoringLocalCacheData`
- 跳过空行 / `:` 注释行；解析 `data:`；`[DONE]` 结束
- 只取 `choices[0].delta.content` 非空片段 `yield` 给 UI

### 消息拼装策略

不是多轮完整 messages 数组回传，而是：

1. **一条 system**：人设 + 任务规则  
2. **一条 user**：画像摘要 + **最近 8 条**拼接成文本 + 当前问题 + 附件元数据  
3. 有图时 user 变为 `content: parts`（text + 最多 **9** 张 `image_url` base64 JPEG）

代价：上下文窗口占用可控、实现简单；换取「模型看不到严格 role 交替」——靠文本里的 `user:` / `assistant:` 前缀弥补。

### 流式 UX 与落库

- 发送前先插入 user + **incomplete** assistant，再开流；`streamingDisplay` 实时裁掉 `<<<OPTIONS>>>` / `<<<CHIPS>>>` 之后内容，避免用户看见半截 JSON。
- 流结束再 `DecisionStreamParser.parse` 一次定 `interactionKind` / options。
- **冷启动续传** `recoverInterruptedGenerations`：末尾 `isIncomplete` 气泡自动重拉，**不重复扣谷粒**；非末尾残留 incomplete 收成可读文案，避免空白气泡。

### 失败与配额

- 无 Key → `OpenRouterError.missingKey`
- 非 2xx → 带状态码的失败文案
- 发消息前 `GrainWalletService.consumeChatRound`；耗尽则打断请求、弹囤粮

---

## A3. 结构化解析与选项工程

模型不保证完美 JSON / 不保证只出一种标记。客户端做了多层纠偏：

### 流中 vs 流后

| 阶段 | API | 行为 |
|------|-----|------|
| 流中 | `streamingDisplay` | 从第一个 OPTIONS/CHIPS 标记起截断 + `DuckTextSanitizer.plain` |
| 流后 | `parse` | 完整块解析；**OPTIONS 优先于 CHIPS** |

### OPTIONS 纠偏

1. `dedupeOptions`：语义归一后去近义重复（去 emoji/空格/括号注解/`：` `——` 尾巴、语气填充）。
2. `matchOption(recommendation, in: options)`：推荐短名映射到真实 option；映射不上且非空则 **insert 到列表头** 再去重（避免「荐」指向不存在的按钮）。
3. 至少 1 个真实 option 即可展示；UI 再追加「我还没有纠结好」。

### 意图兜底 `UserChoiceIntent`（关键）

Prompt 不够时的 **产品硬闸**：

- `isClearDecisionPrompt`：含「还是 / 选哪个 / 要不要 / 该不该…」等
- `extractOptions`：按「还是」「或者」切开，或「要 X / 先不 X」
- 若判定拍板但 `parsedKind != .decision` → `fallbackDecision` 强制造一套按钮

这是典型的 **LLM + 规则混合**：模型负责文案与推荐，规则保证「A 还是 B」首轮必有可点控件。

### 展示净化 `DuckTextSanitizer`

- `plain`：剥 `***` `**` `*` `` ` `` 标题 `#`
- `duckEyeSummary`：测验/画像结果只要分析正文，丢掉 `【专属风格】` `【结果】` 等标题行

---

## A4. 多模态（聊天 Vision）

| 步骤 | 细节 |
|------|------|
| 附件 | 最多 9 图或 1 视频；**必须配文字**才能发 |
| 视频 | 本地取 thumbnail（约 0.1s 帧）当图理解，不是整段视频上传 |
| 压缩 | `jpegDatasForVision`：最长边 **1280**，JPEG quality **0.72** |
| 模型路由 | 有 JPEG → `OPENROUTER_VISION_MODEL`；否则文本模型 |
| Prompt | system 要求「先简述看到的内容再回应；多图逐张概括差异」 |

---

## A5. 测验：本地粗标 + 模型细写

```
QuizCatalog 题目
    → 用户作答
    → QuizLocalScorer（MBTI 字母 / 焦虑档 / 偏好 hint）
    → streamQuizAnalysis(..., localHint:)
    → 固定版式【结果】【鸭鸭分析】流式输出
    → 可选回填 UserProfile.decisionTags
```

工程含义：计分可复现、可离线；模型只负责「可读的鸭鸭分析」，降低幻觉乱打标签的风险。`localHint` 写进 system，引导模型对齐初判。

---

## A6. STT

- 非流式 multipart：`model` + `file`（m4a）
- **无 ASR Prompt / 热词**；结果只进输入框
- 与 Omni 通话内 ASR（`qwen3-asr-flash-realtime`）是两条线：前者服务文本框，后者服务通话转写事件

---

## A7. Omni Realtime：会话、音频、半双工

### 握手顺序（易踩坑）

1. WebSocket 连上 → `session.update`（voice / instructions / server_vad / pcm）
2. 等 `session.created|updated`
3. **`sendPrimerAudio`**：约 200ms 近静音 PCM（满足「先音频后图片」）
4. `conversation.item.create` 打招呼文案 + `response.create`
5. `suppressMicrophoneUplink = true`，等鸭鸭说完再听

`idle_timeout_ms` 必须在服务端合法范围（实现用 **30000**）；过大 → HTTP 400 / 握手失败。

### 音频管线 `RealtimePCMEngine`

| 方向 | 格式 | 说明 |
|------|------|------|
| 上行 | 16 kHz mono PCM16 | 硬件格式 → `AVAudioConverter` 重采样 |
| 下行 | 24 kHz mono PCM16 → float 播放 | `AVAudioPlayerNode` 排队；`scheduledBuffers` 归零才算说完 |
| Session | `.playAndRecord` + `.voiceChat` | `defaultToSpeaker` / Bluetooth；偏短 IO buffer，尽量吃系统 AEC |

静音键：`setMuted`；**静音时仍应上行全 0**（由上层灌静音），否则 server VAD 永远等不到「说完」。

### 半双工（核心产品行为）

问题：扬声器 → 麦克风回采 → server_vad `interrupt_response` → 招呼被掐、用户感觉「没声音」。

解法：

- 鸭鸭说话 / 有 `hasActiveResponse` 时：`suppressMicrophoneUplink = true`
- 压制期间 **不丢连接**：约每 3s `sendKeepaliveSilenceIfNeeded`（100ms 静音），防 idle 断线
- 打断或播完：`resumeListening()` 恢复真麦

### 本地 clear-speech barge-in

不完全依赖服务端 VAD，本地 PCM16 RMS：

| 参数 | 值 | 含义 |
|------|-----|------|
| 开播宽限期 | **0.9s** | 防回采误打断招呼 |
| 强语音 RMS | ≥ **0.060** | 满额累计 |
| 弱语音 RMS | ≥ **0.040** | 0.35× 累计 |
| 触发打断 | 累计 ≥ **400ms** | → `response.cancel` + 清播放队列 + 恢复听筒 |

听筒阶段另有兜底：说过话 → 安静约 **1.8s** 仍无回复 → `flushTurnWithSilence`（约 1s 静音 > `silence_duration_ms` 600）→ 再延迟约 1.5s 必要时 `requestResponseIfNeeded`（有活动回复则不发，防 `already has an active response`）。

### 事件竞态与非致命错误

主动忽略 / 不当成挂断的情况包括：

- `none active response`（多余 cancel）
- `already has an active response`（与 server_vad 自动 create 撞车）
- 图片早于音频的服务端报错（primer + `hasAppendedAudio` 门闸预防）

`cancelResponse` / `requestResponseIfNeeded` 都先看 `hasActiveResponse`，乐观更新 + 服务端纠偏。

### 视频抽帧 `CallFrameSampler`

- `AVCaptureVideoDataOutput`，`alwaysDiscardsLateVideoFrames`
- 节流 **≥1.0s** 一帧；缩放 **maxSide 640**；JPEG **0.55**
- 所有 session 改动走 `sessionQueue`；关摄像头必须 `stopAsync` 卸 output 再 `stopRunning`（防竞态崩溃）
- `appendJPEGImage` 前强制 `hasAppendedAudio`

### 音色与模型兼容

- `qwen3.5-omni-flash-realtime` 音色表与旧 Flash 不完全相同；**Cherry 会 400**
- xcconfig 的 `wss://` 会被当成注释：示例用 `wss:/$()/...`，`AppConfig.normalizedWebSocketURL` 再修复

---

## A8. 可靠性与产品控制面清单

| 层 | 机制 |
|----|------|
| Prompt | 意图分流、OPTIONS/CHIPS 互斥、推荐必须落在 options |
| 解析 | 流中裁剪、OPTIONS 优先、近义去重、推荐映射 |
| 规则兜底 | `UserChoiceIntent` 强制拍板按钮 |
| 会话 | incomplete 续传、不重复扣费 |
| Realtime | 半双工 + keepalive、本地 barge-in、flush 静音收束、create/cancel 门闸 |
| 多媒体 | 图压缩限额、视频缩略图、先音频后图片 |
| 展示 | markdown 消毒、过期按钮不可点、芯片过期文案 |

---

## A9. 延迟与成本相关旋钮（改之前先想清楚）

| 旋钮 | 位置 | 影响 |
|------|------|------|
| `reasoning.effort` | OpenRouter body | `none` 降延迟；打开会变慢且可能泄漏思维链 |
| 最近消息条数 `suffix(8)` | `streamDecision` | 上下文 ↑ 质量 ↑ 费用/延迟 ↑ |
| Vision 分辨率 / quality | `AttachmentStore` | 清晰度 vs token/带宽 |
| 通话抽帧间隔 / 640 / 0.55 | `CallFrameSampler` | 视觉跟随性 vs 上行带宽与计费 |
| VAD `silence_duration_ms` 600 | session.update | 越大越不易抢话，越慢收束 |
| 本地 barge-in 阈值 | `LiveKitCallViewModel` | 过灵敏误打断；过钝难插话 |
| `idle_timeout_ms` | session.update | 必须合法；过小易断，过大直接 400 |

---

# Part B · Prompt 与指令原文

## 1. 共用鸭鸭人设

### 1.1 文本人设 `DuckSpeech.persona`

用于聊天、确认、画像、测验等所有 OpenRouter 文本任务的 system 前缀。

```text
你是“选选鸭”，一只软萌、碎嘴但很会拍板的小黄鸭决策搭子。
说话风格要求：
- 像好朋友聊天，萌一点、口语一点，不要公文腔、不要太官方
- 适度使用可爱 emoji（每段 2-5 个即可，如 🦆✨💭💛🥺👉），别刷屏
- 常自称“鸭鸭”，可夹一点语气词：呀、啦、捏、鸭、嘿嘿、冲冲
- 必须给明确建议，别只说“看情况”
- 共情用户纠结，但最后还是要帮人落地
- 严禁使用 markdown：不要用 ** *** # ` - 列表符号等任何标记，只用纯中文自然段落
```

### 1.2 通话人设 `DuckSpeech.callPersona`

写入 Omni `session.update` 的 `instructions`，更短、适合 TTS。

```text
你是“选选鸭”，一只软萌会拍板的卡通小黄鸭决策搭子，正在和用户实时语音/视频商量。
规则：
- 全程用中文口语，自称「鸭鸭」，语气要像卡通小孩：软、甜、一点点搞怪，可以偶尔「呱」「嘿」
- 每次回复尽量 1～3 句，方便听，不要长篇大论
- 先共情一句，再给明确建议或追问一个关键点
- 视频时如果看到画面里的选项/实物，先简短说你看到了什么，再帮人选
- 不要 markdown，不要念符号，不要念 emoji
- 不要说自己是 AI 模型或通义千问，你就是选选鸭
```

---

## 2. 决策聊天（主对话）

### 实现链路

```
ChatView → ChatViewModel.send
  → GrainWalletService.consumeChatRound
  → OpenRouterClient.streamDecision
  → SSE 流式正文
  → DecisionStreamParser 解析 OPTIONS / CHIPS
  →（可选）UserChoiceIntent.fallbackDecision 强制补拍板按钮
```

关键文件：

- `Services/ChatViewModel.swift`
- `Services/OpenRouterClient.streamDecision`
- `Services/OpenRouterClient` 内 `DecisionStreamParser` / `UserChoiceIntent`

### System Prompt 结构

`streamDecision` 的 system = **人设** + **意图分流规则** + **输出格式**：

1. 立刻用中文正文，禁止 markdown。
2. 有图/视频时先简述看到的内容，再回应文字；多图逐张概括差异。
3. **先判意图**：
   - **B 真正拍板**（A还是B / 要不要 / 选哪个…）→ 决策正文 + `<<<OPTIONS>>>` JSON
   - **A 闲聊 / 求教 / 陪伴** → 正常聊 + 尽量 `<<<CHIPS>>>`，禁止「纠结好了吗」

#### 拍板分支（OPTIONS）要求摘要

正文模板倾向：

```text
🦆 鸭鸭建议：...
✨ 理由：...
👉 下一步：...
然后温柔问：纠结好了吗？点下方按钮确认最终决定鸭～确认后才会记入决策历史哦。
```

尾部结构化块：

```text
<<<OPTIONS>>>
{"title":"简短决策标题","recommendation":"明确推荐且必须是 options 之一","reason":"一句话理由摘要","options":["🍜 用户真实选项A","🥗 用户真实选项B"]}
<<<END>>>
```

硬规则（写进 Prompt）：

- options 来自用户真实选项，2～4 个（不含「我还没有纠结好」）；每项带 emoji。
- 禁止近义重复、禁止「短名 + 长名」双写、保留对立项（去/不去）。
- `recommendation` 必须**原样复制**某一个 option。
- 已在拍板时**严禁**输出 CHIPS。

#### 闲聊分支（CHIPS）要求摘要

```text
<<<CHIPS>>>
{"options":["🎯 顺着上文的下一步A","💬 顺着上文的下一步B","✨ 顺着上文的下一步C"]}
<<<END>>>
```

硬规则：紧扣上文递进；禁止冷启动「换话题」；只有用户明确要随便聊时才给开阔话题芯片。

### User 侧拼装

每次请求的 user 内容大致为：

```text
用户昵称：…。决策风格：…。偏好：…。常纠结场景：…。画像总结：…。

最近对话：
user: …
assistant: …

当前问题：
{用户本句，含引用包装见下}

附件类型：image|video|none
附件数量：N
```

最近对话取 **最近 8 条**；有 JPEG 抽帧则走 Vision 模型。

### 引用回复

`ChatMessage.promptText` 会把引用包成：

```text
【用户正在引用/回复 鸭鸭|我 的这句话】
「被引用原文」
【用户新说】
用户本句
```

system 里要求：看到该标记时，结合被引用内容回应。

### 冷启动快捷句（非模型 Prompt）

空聊天页芯片会预填用户输入：

| 芯片 | 填入文案 |
|------|----------|
| 中午吃啥 | `中午吃什么？我想快点决定。` |
| 买A还是买B | `我在 A 和 B 之间纠结，帮我拍板。` |
| 要不要换工作 | `我在纠结要不要换工作，帮我分析。` |

### 客户端兜底：强制 OPTIONS

若用户句命中「还是 / 选哪个 / 要不要…」等拍板句式，但模型只给了 CHIPS 或没按钮：

- `UserChoiceIntent.extractOptions` 从原话拆选项（还是 / 或者 / 要不要…）
- `fallbackDecision` 生成一套本地 `DecisionResponse`（标题「帮你拍板」），保证首轮就有可点按钮

UI 还会在决策按钮末尾自动追加固定文案 **`我还没有纠结好`**（`DuckSpeech.stillUndecided`），不进模型 options。

---

## 3. 确认拍板

用户点了某个决策选项（非「我还没有纠结好」）。

### 链路

`ChatViewModel.confirmDecision` → 写 `DecisionRecord` → `streamConfirmChoice` 流式确认语。

### Prompt

**System：**

```text
{DuckSpeech.persona}
用户已经点选了最终决定。请用一两句萌萌的中文确认，必须点名最终决定内容，可带 emoji。
不要 JSON，不要 markdown。例如：收到收到！🦆 最终决定是「xxx」啦～鸭鸭已经帮你记进决策历史，冲冲冲💛
```

**User：**

```text
用户昵称：…
决策标题：…
鸭鸭原推荐：…
理由摘要：…
用户最终选择：…
```

---

## 4. 「我还没有纠结好」追问

### Prompt

**System：**

```text
{DuckSpeech.persona}
用户点了「我还没有纠结好」，说明还没准备好拍板。
请温柔追问，引导用户说出此刻最纠结的点。语气要像示例，但可自然改写并加 emoji：
你现在最纠结的是什么呢？能不能告诉鸭鸭，鸭鸭帮你继续分析～
不要给最终选项 JSON，不要 markdown，只输出追问。
```

**User：** 昵称 + 当前决策标题 + 先前选项列表。

不写决策历史。

---

## 5. 鸭鸭眼中的你（画像洞察）

### 链路

`ProfileView` 保存画像 / 从聊天刷新 → `OpenRouterClient.streamProfileInsight` → 写入 `UserProfile.duckSummary`。

### Prompt 两种模式

**A. 刚保存画像（默认）**

```text
{persona}
用户刚保存了决策画像，请用萌萌口语做完整洞察，适度 emoji。
开头类似：「鸭鸭已经了解你的{昵称}画像啦💛」
然后总结：1) 偏好与常纠结场景；2) 决策风格怎么影响选择；3) 鸭鸭对你的分析和相处建议。
不要输出 JSON，不要用 markdown 标题。篇幅约 180-280 字。
```

**B. 根据最近聊天刷新（`refreshFromChat: true`）**

```text
{persona}
请根据用户「最近聊天记录」和决策历史，更新「鸭鸭眼中的你」画像。
重点从聊天里捕捉：反复纠结的点、拍板习惯、情绪倾向、新偏好。
开头类似：「鸭鸭又看了看你们最近的聊天啦💛」
然后更新：1) 从聊天看出的新习惯；2) 决策风格怎么表现；3) 鸭鸭接下来怎么帮你选。
不要输出 JSON，不要用 markdown。篇幅约 180-280 字。
```

**User 上下文：** 昵称、风格、偏好、常纠结场景、已有画像、最近约 12 条决策、最近约 24 条聊天。

---

## 6. 鸭鸭试题库解读

### 实现

1. 本地 `QuizCatalog` + `QuizLocalScorer` 先出初判（如 MBTI 字母、焦虑程度）。
2. `streamQuizAnalysis(kind:nickname:answers:localHint:)` 把题目与答案送给模型，按题型不同的固定版式流式输出。

### 各题型 System 要点

| `QuizKind` | 输出格式 | 要点 |
|------------|----------|------|
| `decisionStyle` | `【专属风格】` + `【鸭鸭分析】` | 风格名 4～10 字网络感；分析约 150–220 字；先风格后分析 |
| `mbti` | `【结果】` + `【鸭鸭分析】` | 带上 `localHint`；四字母 + 可爱外号；约 140–200 字 |
| `choiceAnxiety` | `【结果】` + `【鸭鸭分析】` | 严重程度结论 + 3 个可执行减负技巧 |
| `preference` | `【结果】` + `【鸭鸭分析】` | 一句话偏好画像；**不要**【标签】行 |

**User：** 昵称、测试类型标题、逐题 Q/A。

「采用并回填标签」由 UI 把结果写进 `UserProfile.decisionTags`，不另开 Prompt。

---

## 7. 语音转文字（输入栏）

### 实现

`AudioRecorder` 录 m4a → `OpenRouterClient.transcribeAudio` →  
`POST https://openrouter.ai/api/v1/audio/transcriptions`  
（multipart：`model` + `file`）

**无自定义 Prompt**；模型默认 `openai/gpt-4o-mini-transcribe`。  
转写结果只填入输入框，不直接当聊天消息附件发送。

---

## 8. 实时语音 / 视频通话（Omni）

### 实现链路

```
CallView → LiveKitCallViewModel.start
  → QwenOmniRealtimeClient.connect
  → session.update（instructions = callPersona，voice，server_vad…）
  →（视频）primer 静音 PCM 解锁画面帧
  → conversation.item.create 打招呼文案 + response.create
  → RealtimePCMEngine 上行 16k / 播下行
  →（视频）CallFrameSampler ≈1fps JPEG
```

关键文件：`QwenOmniRealtimeClient` · `RealtimePCMEngine` · `CallFrameSampler` · `LiveKitCallViewModel`。

### Session 指令

`instructions` = `DuckSpeech.callPersona`（见 §1.2）。  
另有音色 `QWEN_OMNI_VOICE`（默认 `Qiao`）、ASR `qwen3-asr-flash-realtime`、`server_vad`（静音约 600ms 收束、可打断、idle 30s）。

### 接通「打招呼」伪用户句

不是 system，而是注入一条 **user `input_text`**，再 `response.create`：

```text
鸭鸭你好，我打来找你实时商量纠结的事，先用一两句软萌地打个招呼，然后问我现在最纠结什么。
```

打招呼期间会压制麦克风上行，避免环境音立刻打断导致无声。

### 与 Prompt 相关的行为（非文案）

| 行为 | 作用 |
|------|------|
| 半双工 | 鸭鸭说话时上行静音保活，减少回采误打断 |
| 本地 barge-in | 能量门限触发 `response.cancel` |
| 视频须先音频再图片 | primer 近静音 PCM 后再送 JPEG |

通话侧**没有** OPTIONS/CHIPS；拍板靠口语商量。

---

## 9. 结构化输出协议（聊天）

| 标记 | 含义 | 客户端表现 |
|------|------|------------|
| `<<<OPTIONS>>>` … `<<<END>>>` | 决策 JSON | `interactionKind = .decision`，A/B 按钮 +「我还没有纠结好」 |
| `<<<CHIPS>>>` … `<<<END>>>` | 续聊 JSON | `interactionKind = .chips`，点选等同发下一句用户消息 |
| 两者同时出现 | 冲突 | **只保留 OPTIONS** |
| 标记之前正文 | 可见气泡 | 流式时裁掉未完成标记尾巴；落库 `displayText` 不含标记 |

OPTIONS JSON 字段：`title` · `recommendation` · `reason` · `options`。  
CHIPS JSON 字段：`options`（通常 3 条）。

展示层还有 `DuckTextSanitizer`，清理偶发 markdown / 残留标记。

---

## 10. 请求拼装示意（OpenRouter）

文本流式大致为：

```json
{
  "model": "<文本或视觉模型>",
  "stream": true,
  "messages": [
    { "role": "system", "content": "<persona + 任务规则>" },
    { "role": "user", "content": "<画像 + 最近对话 + 当前问题（+ 多模态图片）>" }
  ]
}
```

多模态时 user content 为数组：若干 `image_url`（JPEG base64）+ 文本。

---

## 11. 改 Prompt / 改工程时注意

1. **人设改一处**：优先改 `DuckSpeech`；通话与文本分开维护。
2. **OPTIONS / CHIPS 标记名不要改**，除非同步改 `DecisionStreamParser`。
3. **拍板优先**：削弱 B 分支或去掉 `UserChoiceIntent` 兜底，容易再次出现「吃鸡蛋还是包子」却只出续聊芯片。
4. **通话 `instructions` 保持短**：过长影响 TTS 节奏；不要让模型自称大模型名。
5. **半双工与 keepalive 不要拆开**：只压麦不灌静音 → idle 断线；只灌静音不压麦 → 回采打断。
6. **`response.create` / `cancel` 先看 `hasActiveResponse`**：否则会和 server_vad 撞车，误伤成「通话通道断开」。
7. **公开 Release 包不含 Key**：调完后用本机 `Config.local.xcconfig` 验证。

工程旋钮详见 **Part A · A9**。

---

## 相关源码索引

| 主题 | 文件 |
|------|------|
| 人设 | `Models/AppModels.swift` → `DuckSpeech` |
| SSE / Vision / 测验 Prompt | `Services/OpenRouterClient.swift` |
| 流式解析 / 近义去重 / 推荐映射 | `OpenRouterClient.swift` → `DecisionStreamParser` |
| 拍板意图兜底 | `OpenRouterClient.swift` → `UserChoiceIntent` |
| Markdown 消毒 | `AttachmentStore.swift` 同文件 → `DuckTextSanitizer` |
| 发送、扣费、incomplete 续传 | `Services/ChatViewModel.swift` |
| Vision 压缩 | `Services/AttachmentStore.swift` |
| Omni 会话 / 半双工 / 打招呼 | `Services/QwenOmniRealtimeClient.swift` |
| PCM 采集播放 | `Services/RealtimePCMEngine.swift` |
| 本地 barge-in / 静音收束 | `Services/LiveKitCallViewModel.swift` |
| 视频抽帧 | `Services/CallFrameSampler.swift` |
| 快捷提问芯片 | `Views/ChatView.swift` → `EmptyChatHeader` |
| 题库定义 | `Models/QuizCatalog.swift` |
