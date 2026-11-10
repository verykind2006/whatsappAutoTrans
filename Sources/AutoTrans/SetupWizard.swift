import SwiftUI
import AppKit

/// 新机器第一次打开时的设置向导：欢迎 → 开权限 → 选翻译方式 → 语音（可选）→ 完成
struct SetupWizard: View {
    @EnvironmentObject var model: AppModel
    @State private var step: Int
    init(startStep: Int = 0) { _step = State(initialValue: startStep) }
    @State private var axOK = WhatsAppSender.hasPermission
    private let titles = ["欢迎", "读取权限", "发送权限", "翻译方式", "语音（可选）", "完成"]

    var body: some View {
        HStack(spacing: 0) {
            stepList
            Rectangle().fill(Theme.hairline).frame(width: 1)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch step {
                        case 0: welcome
                        case 1: permission
                        case 2: sendPermission
                        case 3:
                            PageHeader(title: "选翻译方式", subtitle: "以后随时可以在菜单「autoTrans → 设置…」里改。")
                            EngineSection()
                        case 4:
                            PageHeader(title: "语音消息（可选）", subtitle: "不需要的话直接跳过。")
                            VoiceSection()
                        default: finish
                        }
                    }
                    .frame(maxWidth: 660, alignment: .leading)
                    .padding(.horizontal, 36).padding(.vertical, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Theme.canvas)
                .tint(Theme.accent)

                Rectangle().fill(Theme.hairline).frame(height: 1)
                bottomBar
            }
        }
        .background(Theme.canvas)
        .onAppear {
            // 已经设置过、只是权限被关掉了：直接跳到开权限那一步
            if model.setupDone && !model.hasDBAccess { step = 1 }
        }
    }

    /// 左边：竖排的步骤，圆圈里是序号，做完的打 ✓，当前步浅绿底 + 粗体
    private var stepList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if let icon = NSImage(named: "AppIcon") {
                    Image(nsImage: icon).resizable().frame(width: 36 * Theme.scale, height: 36 * Theme.scale)
                }
                Text("autoTrans").font(Theme.f(20, .bold))
            }
            .padding(.horizontal, 12).padding(.bottom, 18)

            ForEach(titles.indices, id: \.self) { i in
                let current = i == step, done = i < step
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(current || done ? Theme.accent : Color.white)
                        Circle().stroke(current || done ? Theme.accent : Theme.hairline, lineWidth: 1.5)
                        if done {
                            Image(systemName: "checkmark").font(Theme.f(13, .bold)).foregroundStyle(.white)
                        } else {
                            Text("\(i + 1)").font(Theme.f(14, .bold)).foregroundStyle(current ? .white : Theme.inkSoft)
                        }
                    }
                    .frame(width: 28 * Theme.scale, height: 28 * Theme.scale)
                    Text(titles[i])
                        .font(Theme.f(17, current ? .bold : .medium))
                        .foregroundStyle(current ? Theme.ink : Theme.inkSoft)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8).fill(current ? Theme.accentBg : .clear))
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 22)
        .frame(width: 230 * Theme.scale)
        .background(Color.white)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if step > 0 && step < 5 { Button("上一步") { step -= 1 }.appButton() }
            Spacer()
            if step == 2 && !axOK {
                Button("先跳过（只看翻译，不发消息）") { step = 3 }.appButton()
            }
            if step == 3 && model.configProblem != nil {
                Button("先跳过，以后在设置里配") { step = 4 }.appButton()
            }
            if step == 4 && model.whisperFolder == nil {
                Button(model.whisperDownload != nil ? "先进入，模型在后台继续下载" : "不需要，跳过") { step = 5 }.appButton()
            }
            if step < 4 || (step == 4 && model.whisperFolder != nil) {
                Button("下一步") { step += 1 }
                    .appButton(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canGoNext)
            } else if step == 5 {
                Button("开始使用") {
                    model.setupDone = true
                    model.checkAccess()
                }
                .appButton(.primary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
        .background(Color.white)
    }

    private var canGoNext: Bool {
        switch step {
        case 1: return model.hasDBAccess
        case 2: return axOK
        case 3: return model.configProblem == nil
        default: return true
        }
    }

    // MARK: 各步

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "欢迎使用 autoTrans",
                       subtitle: "autoTrans 放在 WhatsApp 旁边，自动把对方发来的外语消息翻成中文；你写中文，它翻好再发出去。")
            Card("第一次使用要做三件事，大约 5 分钟") {
                NumberedSteps(steps: [
                    "允许 autoTrans 读取 WhatsApp 的聊天记录",
                    "允许 autoTrans 替你在 WhatsApp 里发消息（只在你按「发送」时才会发）",
                    "选择用什么翻译：联网模型（如 Claude，效果最好）或本机模型（不联网、不花钱）",
                ])
            }
            Card {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "lock.fill").foregroundStyle(Theme.accent)
                    Text("autoTrans 只读取，不会修改或删除你的聊天记录。").font(Theme.text)
                }
            }
        }
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "允许读取 WhatsApp 聊天记录",
                       subtitle: "macOS 要求在「完全磁盘访问权限」里手动打开。autoTrans 只读，不会改动聊天记录。")
            Card("当前状态") {
                StatusBadge(ok: model.hasDBAccess, text: model.hasDBAccess ? "已经可以读取了" : "还没有权限")
            } content: {
                if model.hasDBAccess {
                    Text("点右下角「下一步」继续。").font(Theme.text)
                } else {
                    NumberedSteps(steps: [
                        "点「打开系统设置」和「在访达中显示 autoTrans」，把两个窗口并排放好",
                        "把访达里的 autoTrans 图标拖进系统设置的列表，输入开机密码",
                        "确认 autoTrans 右边的开关是打开的",
                        "回到这里。系统要求「退出并重新打开」时，点「重新打开 autoTrans」",
                    ])
                    CardDivider()
                    HStack(spacing: 10) {
                        Button("打开系统设置") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }.appButton(.primary)
                        Button("在访达中显示 autoTrans") {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        }.appButton()
                        Spacer()
                        Button("重新检查") { model.checkAccess() }.appButton()
                        Button("重新打开 autoTrans") { relaunch() }.appButton()
                    }
                    Text("⏳ 每 2 秒自动检查一次，开好了这里会自动变成 ✓").font(Theme.caption).foregroundStyle(Theme.inkSoft)
                }
            }
        }
        // 停在这一步时每 2 秒自动检查一次，开好就自动变 ✓
        .task {
            while !Task.isCancelled && !model.hasDBAccess {
                try? await Task.sleep(for: .seconds(2))
                model.checkAccess()
            }
        }
    }

    private var sendPermission: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "允许替你在 WhatsApp 里发消息",
                       subtitle: "你在 autoTrans 里按「发送」时，它会打开 WhatsApp 里对应的聊天、核对名字、填入译文并发出。这需要「设备控制和数据访问」权限（旧版系统叫「辅助功能」）。")
            Card("当前状态") {
                StatusBadge(ok: axOK, text: axOK ? "已经允许了" : "还没有允许")
            } content: {
                if axOK {
                    Text("点右下角「下一步」继续。").font(Theme.text)
                } else {
                    NumberedSteps(steps: [
                        "点「请求权限」，系统会弹窗，点「打开系统设置」",
                        "在列表里把 autoTrans 的开关打开（没有的话，用上一步的办法把 autoTrans 拖进去）",
                        "回到这里，会自动变成 ✓",
                    ])
                    CardDivider()
                    HStack(spacing: 10) {
                        Button("请求权限") { WhatsAppSender.requestPermission() }.appButton(.primary)
                        Button("打开系统设置") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }.appButton()
                        Button("在访达中显示 autoTrans") {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        }.appButton()
                    }
                    Text("只想看翻译、不用发消息的话，可以跳过这一步。").font(Theme.caption).foregroundStyle(Theme.inkSoft)
                }
            }
        }
        .task {
            while !Task.isCancelled && !axOK {
                try? await Task.sleep(for: .seconds(2))
                axOK = WhatsAppSender.hasPermission
            }
        }
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "设置完成", subtitle: "以后要更换翻译方式、key 或语音设置，在菜单「autoTrans → 设置…」（快捷键 ⌘,）。")
            Card {
                CardRow(title: "读取聊天记录") {
                    StatusBadge(ok: model.hasDBAccess, text: model.hasDBAccess ? "可以" : "还不能")
                }
                CardDivider()
                CardRow(title: "在 WhatsApp 里发消息", detail: axOK ? nil : "不能发时，只能看翻译") {
                    StatusBadge(ok: axOK, text: axOK ? "可以" : "还不能")
                }
                CardDivider()
                CardRow(title: "翻译",
                        detail: model.configProblem ?? (model.engine == .online
                            ? "\(model.provider.title) · \(model.modelName)" : "本机模型")) {
                    StatusBadge(ok: model.configProblem == nil, text: model.configProblem == nil ? "可以" : "还不能")
                }
                CardDivider()
                CardRow(title: "语音转文字",
                        detail: model.whisperFolder != nil ? "语音消息会转成文字再翻译"
                            : model.whisperDownload != nil ? "模型正在后台下载，下完自动开启" : "以后可以在设置里开启") {
                    StatusBadge(ok: model.whisperFolder != nil, text: model.whisperFolder != nil ? "已开启" : "未开启")
                }
            }
        }
    }

    /// 授权完全磁盘访问后，macOS 要求重启 App 才生效
    private func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}
