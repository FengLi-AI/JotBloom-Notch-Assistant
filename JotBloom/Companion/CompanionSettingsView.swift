import SwiftUI

struct CompanionSettingsView: View {
    @ObservedObject var model: CompanionController
    @State private var previewMood = "curious"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("住在刘海旁的小伙伴").font(BloomTypography.font(18, role: .label))
                Text("陪你待一会，也给手头的事情让个位。")
                    .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
            }
            Toggle("显示小伙伴", isOn: $model.enabled).toggleStyle(BloomToggleStyle())
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(CompanionController.characters, id: \.0) { character in
                    Button { model.preset = character.0 } label: {
                        VStack(spacing: 8) {
                            if let image = model.thumbnail(character.0) {
                                Image(decorative: image, scale: 2).resizable().interpolation(.none)
                                    .aspectRatio(contentMode: .fit).frame(width: 60, height: 48)
                            }
                            Text(character.1).font(BloomTypography.font(12, role: .label))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(model.preset == character.0 ? BloomTheme.selected : BloomTheme.well)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(model.preset == character.0 ? BloomTheme.blue : .clear, lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain).accessibilityLabel(character.1)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("陪伴方式").font(BloomTypography.font(13, role: .label))
                Picker("陪伴方式", selection: $model.resident) {
                    Text("常驻").tag(true)
                    Text("偶尔出现").tag(false)
                }.pickerStyle(.segmented).labelsHidden()
                if model.resident {
                    Text("平时安静陪伴，偶尔活动一下。点击它会回应；常驻时不显示黑色底框。")
                        .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
                } else {
                    Toggle("显示黑色底框", isOn: $model.backdrop).toggleStyle(BloomToggleStyle())
                    VStack(spacing: 5) {
                        HStack { Text("出现频率"); Spacer(); Text(model.frequency < 34 ? "低" : model.frequency > 66 ? "高" : "适中").foregroundStyle(BloomTheme.muted) }
                        Slider(value: $model.frequency, in: 0...100).accessibilityLabel("出现频率")
                        HStack { Text("偶尔探头"); Spacer(); Text("多陪一会") }.foregroundStyle(BloomTheme.muted)
                    }.font(BloomTypography.font(11))
                    Text("想让它收回去，随时点一下就好。睡觉和累趴时，会保持趴着滑入滑出。")
                        .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
                }
            }.padding(16).modifier(BloomSurface(color: BloomTheme.well))
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("看看它的动作").font(BloomTypography.font(13, role: .label))
                    Spacer()
                    Picker("动作", selection: $previewMood) {
                        Text("常态").tag("idle"); Text("好奇").tag("curious")
                        Text("精神好").tag("energetic"); Text("睡觉").tag("sleep"); Text("累趴了").tag("tired")
                    }.labelsHidden().frame(width: 118)
                }
                Button { model.preview(previewMood) } label: {
                    BloomActionLabel(title: "收起面板，看一看", symbol: "play.fill")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(BloomButtonStyle()).disabled(!model.enabled || !model.hasNotch)
                Text("打开萌生时，它会先跑回刘海里；收起萌生后，常驻的小伙伴会再出来。")
                    .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
            }
            if !model.hasNotch {
                Text("需要内置刘海屏。接回带刘海的显示屏后，小伙伴会自动回来。")
                    .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
            }
            VStack(alignment: .leading, spacing: 10) {
                Toggle("拖入刘海，收录灵感", isOn: $model.captureEnabled).toggleStyle(BloomToggleStyle())
                Text("选中文字，拖到刘海本体后松手。原文会存进灵感库；刘海下方的提示条不接收拖入。")
                    .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
                if let status = model.captureStatus { Text(status).font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted) }
            }.padding(16).modifier(BloomSurface(color: BloomTheme.well))
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Codex 后台完成提醒", isOn: $model.codexEnabled).toggleStyle(BloomToggleStyle())
                Text("本机 Codex 完成一轮回复后，小伙伴递来纸条。Codex 所在应用在前台时不提醒；VS Code 按整个应用判断。")
                    .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
                Text(model.codexStatus).font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
                Button("选择 Codex 数据目录…") { model.chooseCodexDirectory() }
                    .buttonStyle(BloomButtonStyle())
                Text("只在本机识别完成事件，不保存或上传对话。关闭此项即停止监测。")
                    .font(BloomTypography.font(10)).foregroundStyle(BloomTheme.muted)
            }.padding(16).modifier(BloomSurface(color: BloomTheme.well))
            if let issue = model.issue { Text(issue).foregroundStyle(BloomTheme.danger) }
        }.foregroundStyle(BloomTheme.text)
    }
}
