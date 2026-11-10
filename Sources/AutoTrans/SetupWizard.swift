import SwiftUI
import AppKit

/// 新机器第一次打开时的设置向导：欢迎 → 开权限 → 选翻译方式 → 完成
struct SetupWizard: View {
    @EnvironmentObject var model: AppModel
    @State private var step = 0
    @State private var axOK = WhatsAppSender.hasPermission
    private let titles = ["欢迎", "读取权限", "发送权限", "选翻译方式", "完成"]

    var body: some View {
        VStack(spacing: 0) {
            // 顶部进度：第几步 + 每步名称（当前步加粗、带 ▶）
            HStack(spacing: 18) {
                ForEach(titles.indices, id: \.self) { i in
                    Text((i == step ? "▶ " : (i < step ? "✓ " : "")) + "\(i + 1). \(titles[i])")
                        .font(Theme.f(16, i == step ? .bold : .regular))
                        .foregroundStyle(i == step ? Theme.ink : Theme.inkSoft)
                }
                Spacer()
            }
            .padding(.horizontal, 28).padding(.vertical, 14)
            Divider().overlay(Theme.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch step {
                    case 0: welcome
                    case 1: permission
                    case 2: sendPermission
                    case 3: EngineSection()
                    default: finish
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(Theme.border)
            HStack(spacing: 14) {
                if step > 0 && step < 4 { Button("上一步") { step -= 1 } }
                Spacer()
                if step == 2 && !axOK {
                    Button("先跳过（只看翻译，不发消息）") { step = 3 }
                }
                if step == 3 && model.configProblem != nil {
                    Button("先跳过，以后在设置里配") { step = 4 }
                }
                if step < 4 {
                    Button("下一步") { step += 1 }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canGoNext)
                } else {
                    Button("开始使用") {
                        model.setupDone = true
                        model.checkAccess()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .font(Theme.body).controlSize(.large)
            .padding(.horizontal, 28).padding(.vertical, 14)
        }
        .onAppear {
            // 已经设置过、只是权限被关掉了：直接跳到开权限那一步
            if model.setupDone && !model.hasDBAccess { step = 1 }
        }
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
        VStack(alignment: .leading, spacing: 16) {
            Text("欢迎使用 autoTrans").font(Theme.title)
            Text("autoTrans 放在 WhatsApp 旁边，自动把对方发来的外语消息翻成中文。")
            Text("第一次使用要做三件事，大约 5 分钟：")
            Text("1. 允许 autoTrans 读取 WhatsApp 的聊天记录")
            Text("2. 允许 autoTrans 替你在 WhatsApp 里发消息（只在你点「发送」时才会发）")
            Text("3. 选择用什么翻译：联网模型（如 Claude，效果最好）或本机模型（不联网、不花钱）")
            Text("autoTrans 只读取，不会修改或删除你的聊天记录。")
                .foregroundStyle(Theme.inkSoft)
        }
        .font(Theme.body).lineSpacing(6)
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("允许读取 WhatsApp 聊天记录").font(Theme.title)
            Text(model.hasDBAccess ? "✓ 已经可以读取了，点「下一步」" : "✗ 还没有权限")
                .font(Theme.f(19, .bold))
                .foregroundStyle(model.hasDBAccess ? Theme.accent : Theme.warn)
            if !model.hasDBAccess {
                Text("macOS 要求在「完全磁盘访问权限」里手动打开。autoTrans 不会自己出现在列表里，需要把它加进去：")
                VStack(alignment: .leading, spacing: 10) {
                    Text("1. 点「打开系统设置」和「在访达中显示 autoTrans」，把两个窗口并排放好")
                    Text("2. 把访达里的 autoTrans 图标拖进系统设置的列表，输入开机密码")
                    Text("3. 确认 autoTrans 右边的开关是打开的")
                    Text("4. 回到这里。系统要求「退出并重新打开」时，点下面的「重新打开 autoTrans」")
                }
                HStack(spacing: 12) {
                    Button("打开系统设置") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    Button("在访达中显示 autoTrans") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                }
                HStack(spacing: 12) {
                    Button("重新检查") { model.checkAccess() }
                    Button("重新打开 autoTrans") { relaunch() }
                }
            }
        }
        .font(Theme.body).lineSpacing(6).controlSize(.large)
        // 停在这一步时每 2 秒自动检查一次，开好就自动变 ✓
        .task {
            while !Task.isCancelled && !model.hasDBAccess {
                try? await Task.sleep(for: .seconds(2))
                model.checkAccess()
            }
        }
    }

    private var sendPermission: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("允许替你在 WhatsApp 里发消息").font(Theme.title)
            Text(axOK ? "✓ 已经允许了，点「下一步」" : "✗ 还没有允许")
                .font(Theme.f(19, .bold))
                .foregroundStyle(axOK ? Theme.accent : Theme.warn)
            Text("你在 autoTrans 里点「发送」时，它会打开 WhatsApp 里对应的聊天、核对名字、填入译文并发出。这需要「设备控制和数据访问」权限（旧版系统叫「辅助功能」）。")
            if !axOK {
                VStack(alignment: .leading, spacing: 10) {
                    Text("1. 点「请求权限」，系统会弹窗，点「打开系统设置」")
                    Text("2. 在列表里把 autoTrans 的开关打开（没有的话，用上一步的办法把 autoTrans 拖进去）")
                    Text("3. 回到这里，会自动变成 ✓")
                }
                HStack(spacing: 12) {
                    Button("请求权限") { WhatsAppSender.requestPermission() }
                    Button("打开系统设置") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    Button("在访达中显示 autoTrans") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                }
                Text("只想看翻译、不用发消息的话，可以跳过这一步。").foregroundStyle(Theme.inkSoft)
            }
        }
        .font(Theme.body).lineSpacing(6).controlSize(.large)
        .task {
            while !Task.isCancelled && !axOK {
                try? await Task.sleep(for: .seconds(2))
                axOK = WhatsAppSender.hasPermission
            }
        }
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置完成").font(Theme.title)
            Text(model.hasDBAccess ? "✓ 可以读取 WhatsApp 聊天记录" : "✗ 还不能读取聊天记录")
            Text(axOK ? "✓ 可以在 WhatsApp 里发消息" : "✗ 还不能发消息（只能看翻译）")
            if let problem = model.configProblem {
                Text("✗ 翻译还不能用：\(problem)").foregroundStyle(Theme.warn)
                Text("以后可以在菜单「autoTrans → 设置…」里补上。")
            } else {
                Text("✓ 翻译：" + (model.engine == .online
                    ? "\(model.provider.title)，模型 \(model.modelName)"
                    : "本机模型"))
            }
            Text("以后要更换翻译方式或 key，在菜单「autoTrans → 设置…」（快捷键 ⌘,）。")
                .foregroundStyle(Theme.inkSoft)
        }
        .font(Theme.body).lineSpacing(6)
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
