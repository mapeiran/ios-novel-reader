import Foundation
import Combine

/// 全局错误
enum AppError: LocalizedError {
    case encodingFailed
    case emptyContent
    case fileTooLarge
    case regexInvalid
    case portInUse
    case duplicateBook(String)

    var errorDescription: String? {
        switch self {
        case .encodingFailed: return "无法识别文件编码，请手动选择编码。"
        case .emptyContent:   return "文件内容为空或无法解析。"
        case .fileTooLarge:   return "文件过大，暂不支持。"
        case .regexInvalid:   return "分章正则无效。"
        case .portInUse:      return "端口被占用，请更换端口。"
        case .duplicateBook(let title): return "《\(title)》已经导入过了。"
        }
    }
}
