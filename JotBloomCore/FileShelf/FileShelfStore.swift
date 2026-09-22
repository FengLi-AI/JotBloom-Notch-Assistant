import Foundation

public extension JotBloomStore {
    func loadFileShelf() async throws -> [FileReference] {
        try await performAsync { db in
            let query = try db.prepare("SELECT payload FROM file_shelf ORDER BY sort_order", operation: "load_file_shelf")
            var result: [FileReference] = []
            while try query.stepRow() {
                guard let data = query.text(at: 0).data(using: .utf8) else { throw PersistenceError.invalidSchema(object: "file_shelf_payload") }
                result.append(try JSONDecoder().decode(FileReference.self, from: data))
            }
            return result
        }
    }
    func saveFileShelf(_ items: [FileReference]) async throws {
        let rows = try items.enumerated().map { index, item in
            (item.id.uuidString, String(decoding: try JSONEncoder().encode(item), as: UTF8.self), Int64(index))
        }
        try await performAsync { db in
            try db.transaction {
                try db.execute("DELETE FROM file_shelf", operation: "replace_file_shelf")
                for (id, payload, order) in rows {
                    let insert = try db.prepare("INSERT INTO file_shelf(id,payload,sort_order) VALUES(?,?,?)", operation: "save_file_shelf")
                    try insert.bind(id, at: 1); try insert.bind(payload, at: 2); try insert.bind(order, at: 3)
                    try insert.executeDone()
                }
            }
        }
    }
}
