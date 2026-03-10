import Foundation
import RashunCore

enum SourceResolver {
    static func resolve(_ name: String, in sources: [AISource] = allSources) -> AISource? {
        sources.first { source in
            source.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }
}
