import Foundation

enum WizardStep: Int, CaseIterable, Identifiable {
    case source, identify, episodes, library, review, exporting
    var id: Int { rawValue }
    static let setup: [WizardStep] = [.source, .identify, .episodes, .library, .review]
    var title: String {
        switch self {
        case .source: return "Source"
        case .identify: return "Show"
        case .episodes: return "Episodes"
        case .library: return "Destination"
        case .review: return "Export"
        case .exporting: return "Export"
        }
    }
}
