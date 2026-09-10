import Foundation

public enum SavedLibrary: String, Sendable { case prompts, inspirations }

extension JotBloomStore {
    public func setPromptFavorite(id: Int64, favorite: Bool) async throws {
        try await performAsync { connection in
            let query = try connection.prepare("UPDATE prompts SET is_favorite = ? WHERE id = ?", operation: "favorite_prompt")
            try query.bind(Int64(favorite ? 1 : 0), at: 1); try query.bind(id, at: 2); try query.executeDone()
            guard try connection.changesCount() == 1 else { throw PromptError.missing }
        }
    }
    public func reorderLibrary(_ library: SavedLibrary, id: Int64, relativeTo target: Int64, after: Bool = false, category: InspirationCategory? = nil) async throws {
        guard id != target else { return }
        try await performAsync { connection in
            try connection.transaction {
                if library == .inspirations, let category {
                    let check = try connection.prepare("SELECT COUNT(*) FROM inspirations WHERE id IN (?,?) AND category = ?", operation: "validate_filtered_move")
                    try check.bind(id, at: 1); try check.bind(target, at: 2); try check.bind(category.rawValue, at: 3)
                    guard try check.stepRow(), check.int64(at: 0) == 2 else { throw PromptError.missing }
                }
                let query = try connection.prepare("SELECT id FROM \(library.rawValue) ORDER BY sort_order DESC,id DESC", operation: "read_library_order")
                var ids: [Int64] = []
                while try query.stepRow() { ids.append(query.int64(at: 0)) }
                guard let index = ids.firstIndex(of: id), ids.contains(target) else { throw PromptError.missing }
                ids.remove(at: index)
                let destination = ids.firstIndex(of: target)! + (after ? 1 : 0)
                ids.insert(id, at: destination)
                for (offset, row) in ids.enumerated() {
                    let update = try connection.prepare("UPDATE \(library.rawValue) SET sort_order = ? WHERE id = ?", operation: "write_library_order")
                    try update.bind(Int64(ids.count - offset), at: 1); try update.bind(row, at: 2); try update.executeDone()
                }
            }
        }
    }
}

public enum SavedTime {
    public static func text(_ milliseconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }
}
