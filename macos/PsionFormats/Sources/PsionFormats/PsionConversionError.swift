import Foundation

public enum PsionConversionError: LocalizedError {
    case invalid(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let detail): return "The Psion file is invalid: \(detail)."
        case .unsupported(let detail): return "This Psion format is not supported: \(detail)."
        }
    }
}

func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw PsionConversionError.invalid(message) }
}
