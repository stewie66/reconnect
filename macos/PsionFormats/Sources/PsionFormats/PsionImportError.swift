import Foundation

public enum PsionImportError: LocalizedError {
    case invalid(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let detail): return "The file cannot be imported: \(detail)."
        case .unsupported(let detail): return "Psion import does not support \(detail)."
        }
    }
}
