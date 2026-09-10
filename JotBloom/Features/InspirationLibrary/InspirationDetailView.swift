import AppKit
import Combine
import JotBloomCore
import SwiftUI

struct InspirationDetailView: View {
    @ObservedObject var viewModel: InspirationLibraryViewModel
    let onBack: () -> Void
    let backDestinationName: String

    private enum Field: Hashable {
        case title
        case body
    }

    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(spacing: 0) {
            backRow

            Spacer().frame(height: 8)

            TextField("标题", text: $viewModel.detailTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 46)
                .modifier(BloomSurface(color: BloomTheme.well))
                .focused($focusedField, equals: .title)
                .disabled(viewModel.isDetailLoading)
                .accessibilityLabel("灵感标题")

            Spacer().frame(height: 8)

            TextEditor(text: $viewModel.detailBody)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(BloomSurface(color: BloomTheme.well))
                .focused($focusedField, equals: .body)
                .disabled(viewModel.isDetailLoading)
                .accessibilityLabel("灵感正文")

            Spacer().frame(height: 8)

            if let feedback = viewModel.feedback, feedback.kind == .error {
                Text(feedback.message).font(.system(size: 11))
                    .foregroundStyle(BloomTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 6)
            }
            metadataRow
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if viewModel.isDetailLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在读取灵感详情")
            }
        }
        .onReceive(viewModel.$detailFocusRequest.dropFirst()) { _ in
            DispatchQueue.main.async {
                focusedField = .title
            }
        }
        .onChange(of: focusedField) { newValue in
            if newValue == nil {
                viewModel.flushAfterFocusLoss()
            }
        }
    }

    private var backRow: some View {
        HStack(spacing: 8) {
            Button {
                onBack()
            } label: {
                Label("返回\(backDestinationName)", systemImage: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 10).frame(height: 28)
                    .modifier(BloomSurface(color: BloomTheme.raised, radius: 12))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("返回\(backDestinationName)")
            .accessibilityLabel("返回\(backDestinationName)")

            Text(viewModel.saveStatusMessage)
            .font(.system(size: 11))
            .foregroundColor(BloomTheme.muted)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(statusAccessibilityLabel)
            if viewModel.textSaveFailed {
                Button("重试保存") { viewModel.commandSave() }
                    .buttonStyle(BloomButtonStyle())
                    .disabled(viewModel.isSavingText || viewModel.isSavingCategory)
            }
        }
        .frame(minHeight: 32)
    }

    private var metadataRow: some View {
        HStack(spacing: 10) {
            Picker(
                "分类",
                selection: Binding(
                    get: { viewModel.detailCategory },
                    set: viewModel.chooseCategory
                )
            ) {
                ForEach(InspirationCategory.allCases, id: \.self) { category in
                    Text(category.rawValue).tag(category)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(viewModel.isDetailLoading || viewModel.isSavingCategory)
            .accessibilityLabel("灵感分类")

            Spacer(minLength: 8)
            Button("AI 整理") { viewModel.retryEnrichment() }
                .disabled(viewModel.enrichmentEnabled?() != true || viewModel.isSavingText || viewModel.isSavingCategory)
                .help("生成短标题与分类；手动修改过的字段保留。需先在 AI 接口设置开启灵感 AI 整理。")

            if let detail = viewModel.detailInspiration {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("保存于 \(SavedTime.text(detail.createdAtUTCms))")
                }
                .font(.system(size: 10)).lineLimit(1)
            }
        }
        .font(.system(size: 11))
        .foregroundColor(BloomTheme.muted)
        .padding(.trailing, 36)
        .frame(height: 28)
    }

    private var statusAccessibilityLabel: String {
        viewModel.saveStatusMessage
    }

    private func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
