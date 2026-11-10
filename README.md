# autoTrans

贴在 WhatsApp 桌面版旁边的翻译小窗（macOS）。

- **看消息**：对方发来外语，自动显示中文（下面带原文）。群聊会标出是谁说的。
- **发消息**：打中文 → 翻译（同时直译回中文供核对）→ 可改 → 发到 WhatsApp 当前聊天。每个聊天记住目标语言（西语 / 英语 / 不翻译）。
- **新消息**：输入手机号，给还没聊过的人发。
- **语音**（可选）：语音消息在本机用 Whisper large-v3 转成文字（自动识别中文 / 西语 / 英语…），再翻译。录音不上传。
- **提醒**：单聊收到新消息时，系统通知直接显示中文翻译。
- **大字**：⌘+ / ⌘- 调字号，浅色高对比界面。

## 下载安装

到 [Releases](../../releases) 下载 `autoTrans-x.x.dmg`，打开后按里面的「安装说明」操作。

需要：苹果芯片（M 系列）的 Mac、macOS 14 以上、已登录的 WhatsApp 桌面版、一个翻译用的 API key。

> 程序没有经过苹果公证，第一次打开会被拦，需要在「系统设置 → 隐私与安全性」里点「仍要打开」。

## 工作原理

- **不改 WhatsApp，不用非官方接口**（如 Baileys、whatsapp-web.js），没有封号风险。
- **读**：只读打开 WhatsApp 桌面版本机的聊天数据库 `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite`，每 3 秒看一次新消息。需要「完全磁盘访问权限」。
- **发**：通过 macOS 辅助功能（Accessibility）点开 WhatsApp 里的对应聊天，**核对聊天名一致**后填入译文、点发送；给新号码发用官方链接 `whatsapp://send`。需要「设备控制和数据访问」权限。
- **翻译**：
  - 联网：Anthropic Claude（默认 `claude-opus-5-5`）、OpenAI、DeepSeek，或任意 OpenAI 兼容接口。
  - 本机：MLX 格式的本地模型（如 Qwen2.5-7B-Instruct-4bit），不联网。
- **语音转文字**：[WhisperKit](https://github.com/argmaxinc/WhisperKit)（MIT）运行 Whisper large-v3（CoreML）。模型约 2.9 GB，可在设置里下载，或指定已下载的文件夹。WhatsApp 语音是 Ogg/Opus，macOS 自带解码。分词表 `Resources/whisper-tokenizer` 来自 [openai/whisper-large-v3](https://huggingface.co/openai/whisper-large-v3)（Apache-2.0），随 App 打包，转写不用联网。
- API key 存在本机 `~/Library/Application Support/autoTrans/keys.json`（权限 600），不进代码库。

## 从源码编译

需要完整的 Xcode（不是只有命令行工具），因为 MLX 要编译 Metal 着色器。

```bash
./build.sh      # 编译并装到 ~/Applications/autoTrans.app
./package.sh    # 再打成 dist/autoTrans-<版本>.dmg
```

签名：默认找名为 `vInput Dev` 的本机自签名证书，没有就用临时签名。可用 `SIGN_IDENTITY="你的证书名" ./build.sh` 指定。用固定证书签名的好处是重新编译后系统权限不用重新授予。

命令行自检：

```bash
autoTrans --selftest-out "明天见"   # 试翻一句（会调用一次 API）
autoTrans --ax-dump                  # 打印 autoTrans 看到的 WhatsApp 界面
autoTrans --selftest-voice a.opus [模型目录]   # 本机 Whisper 转一段语音
```

## 代码结构

| 文件 | 作用 |
|---|---|
| `WhatsAppDB.swift` | 只读访问 WhatsApp 数据库 |
| `WhatsAppSender.swift` | 辅助功能操作 WhatsApp：打开聊天、核对、发送、状态检测 |
| `Translator.swift` | 联网翻译（Anthropic 原生接口 / OpenAI 兼容接口）、缓存 |
| `LocalTranslator.swift` | 本机 MLX 模型翻译 |
| `AppModel.swift` | 状态、轮询、翻译调度、发送流程、通知 |
| `Views.swift` / `SettingsView.swift` / `SetupWizard.swift` | 界面 |
| `Transcriber.swift` | 语音转文字：模型查找 / 下载 / 加载、转写、结果缓存 |
| `Notifier.swift` | 系统通知 |
| `Keychain.swift` | API key 本机存储（`KeyStore`） |
