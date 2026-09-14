import JotBloomCore
import SwiftUI

struct SystemPromptEditor: View {
    @ObservedObject var model: SettingsViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI 对话的工作方式").font(BloomTypography.font(14, role: .label))
            TextEditor(text: $model.systemPromptDraft)
                .font(BloomTypography.font(14)).scrollContentBackground(.hidden)
                .padding(12).frame(height: 260)
                .modifier(BloomSurface(color: BloomTheme.well))
                .accessibilityLabel("系统提示词内容")
            Text("\(model.systemPromptDraft.count) / 2000 字符")
                .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
            Text(model.hasUnsavedSystemPrompt ? "有未保存的修改；保存后对新会话生效" : "已保存；现有会话保持原设置")
                .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
            HStack {
                Button("保存修改") { model.saveSystemPrompt() }.buttonStyle(BloomButtonStyle(primary: true))
                    .disabled(!model.hasUnsavedSystemPrompt || model.systemPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.systemPromptDraft.count > 2000)
                Button("恢复默认") { model.restoreDefaultSystemPrompt() }
                Button("放弃修改") { model.discardSystemPrompt() }.disabled(!model.hasUnsavedSystemPrompt)
            }.buttonStyle(BloomButtonStyle())
            Text("不影响灵感分类、标题生成及对话整理。这些任务有独立规则。")
                .font(BloomTypography.font(11)).foregroundStyle(BloomTheme.muted)
        }
    }
}
