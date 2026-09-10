import Foundation

public enum PersistenceError: Error, Equatable, Sendable {
    case dataDirectoryUnavailable(path: String)
    case invalidDebugDataDirectory(path: String)
    case databaseOpenFailed(code: Int32)
    case databaseClosed
    case corruptedDatabase(code: Int32)
    case unsupportedSchema(found: Int32, supported: Int32)
    case invalidSchema(object: String)
    case invalidStoredValue(column: String)
    case inspirationNotFound(id: Int64)
    case sqliteFailure(operation: String, code: Int32)
    case backupAlreadyExists(path: String)
    case backupFailed(path: String)
    case clipboardDirectoryUnavailable(path: String)
    case invalidClipboardAssetName(name: String)
    case clipboardAssetOperationFailed(operation: String)
}

extension PersistenceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .dataDirectoryUnavailable:
            return "萌生无法创建或访问本地数据目录。"
        case .invalidDebugDataDirectory:
            return "调试数据目录无效。"
        case .databaseOpenFailed, .databaseClosed:
            return "萌生无法打开本地数据库。"
        case .corruptedDatabase:
            return "萌生的本地数据库无法读取。"
        case let .unsupportedSchema(found, supported):
            return "数据来自更高版本的萌生，请升级应用。（数据版本 \(found)，当前支持 \(supported)）"
        case .invalidSchema:
            return "萌生的本地数据库结构不完整。"
        case .invalidStoredValue:
            return "萌生的本地数据包含无法识别的值。"
        case .inspirationNotFound:
            return "这条灵感已不存在。"
        case .sqliteFailure:
            return "萌生读写本地数据时发生错误。"
        case .backupAlreadyExists:
            return "数据库迁移备份已存在，未覆盖原备份。"
        case .backupFailed:
            return "萌生无法创建数据库迁移备份。"
        case .clipboardDirectoryUnavailable:
            return "萌生无法创建或访问剪贴板图片目录。"
        case .invalidClipboardAssetName:
            return "剪贴板图片路径无效。"
        case .clipboardAssetOperationFailed:
            return "萌生读写剪贴板图片时发生错误。"
        }
    }
}
