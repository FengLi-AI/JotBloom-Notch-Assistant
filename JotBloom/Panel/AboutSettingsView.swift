import JotBloomCore
import SwiftUI

struct AboutSettingsView: View {
    @Environment(\.openURL) private var openURL
    @State private var checking = false
    @State private var message = "点击检查是否有新版本。"
    @State private var available: AvailableRelease?
    @State private var checkTask: Task<Void, Never>?
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            card {
                Label("萌生 · JotBloom", systemImage: "leaf").font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(BloomTheme.text)
                Text("给闪过的想法，一点空间。")
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(BloomTheme.blue)
                    .fixedSize(horizontal: false, vertical: true)
                Text("记下来，然后继续手头的事。")
                    .font(.system(size: 12)).foregroundStyle(BloomTheme.muted)
                Button("产品官网 ↗") { visit("https://fengli-ai.github.io/JotBloom-Notch-Assistant/") }
                    .buttonStyle(BloomButtonStyle())
            }
            card {
                Text("版本 \(version)").font(.system(size: 13, weight: .medium))
                Text("构建号 \(build)").font(.system(size: 11)).foregroundStyle(BloomTheme.muted)
                HStack(spacing: 10) {
                    Button(checking ? "正在检查…" : "检查最新版本") { check() }
                        .disabled(checking).buttonStyle(BloomButtonStyle())
                    if checking { ProgressView().controlSize(.small).accessibilityLabel("正在检查最新版本") }
                    if let available {
                        Button("查看新版本 ↗") { openURL(available.pageURL) }.buttonStyle(BloomButtonStyle())
                    }
                }
                Text(message).font(.system(size: 11)).foregroundStyle(BloomTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("检查时连接 GitHub；下载后由你安装。")
                    .font(.system(size: 11)).foregroundStyle(BloomTheme.muted)
                Button("打开版本页面 ↗") { openURL(ReleaseChecker.releasesURL) }.buttonStyle(BloomButtonStyle())
            }
            card {
                Text("作者").font(.system(size: 13, weight: .medium))
                Text("李烽立｜Li Fengli").font(.system(size: 13))
                contact("邮箱", "qq204407676@gmail.com", url: "mailto:qq204407676@gmail.com")
                contact("微信", "feNgL1999_")
                contact("小红书", "FengLiAi · 个人主页 ↗", url: "https://www.xiaohongshu.com/user/profile/69b6dd97000000003303a64d")
                contact("抖音号", "N24642464（在抖音内搜索）")
                Text("遇到 Bug 或有功能建议，欢迎通过以上方式联系作者。谢谢你帮助萌生变得更好。")
                    .font(.system(size: 11)).foregroundStyle(BloomTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { checkTask?.cancel(); checkTask = nil; checking = false }
    }

    private func check() {
        guard !checking else { return }
        checking = true; available = nil; message = "正在获取最新版本…"
        checkTask = Task { @MainActor in
            do {
                guard let current = ReleaseVersion(version) else { throw ReleaseCheckError.invalidCurrentVersion }
                let latest = try await ReleaseChecker().check()
                guard !Task.isCancelled else { return }
                if let latest {
                    if latest.version > current {
                        available = latest; message = "发现新版本 v\(latest.version.description)。"
                    } else { message = "当前已是最新版本（v\(version)）。" }
                } else { message = "暂未找到可用的新版本，可打开版本页面查看。" }
            } catch {
                guard !Task.isCancelled else { return }
                message = "暂时无法检查更新，请检查网络后重试，或打开版本页面查看。"
            }
            checking = false
        }
    }
    private func visit(_ address: String) { if let url = URL(string: address) { openURL(url) } }
    private func contact(_ label: String, _ value: String, url: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(BloomTheme.muted)
            if let url {
                Button { visit(url) } label: {
                    Text(value).font(.system(size: 12)).foregroundStyle(BloomTheme.blue)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }.buttonStyle(.plain)
            } else {
                Text(value).font(.system(size: 12)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .modifier(BloomSurface(color: BloomTheme.well))
    }
}
