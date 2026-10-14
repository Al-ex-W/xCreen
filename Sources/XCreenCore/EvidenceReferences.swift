import Foundation

/// Finds `xcreen-image:<id>` references in an assistant reply. Only IDs are extracted;
/// the app resolves them through `EvidenceStore`, so a reply can never point the UI at
/// an arbitrary path or a remote URL.
public enum EvidenceReferences {
    public static let scheme = "xcreen-image:"
    public static let maximum = 12

    public static func imageIDs(in text: String) -> [String] {
        var ids: [String] = []
        var rest = text[...]
        while let range = rest.range(of: scheme) {
            let tail = rest[range.upperBound...]
            let id = String(tail.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
            if !id.isEmpty, id.count <= 100, !ids.contains(id) { ids.append(id) }
            if ids.count == maximum { break }
            rest = tail
        }
        return ids
    }
}
