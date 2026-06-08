import Foundation

/// The saved workspace: heterogeneous canvas items (cards now, diff objects next)
/// plus the camera. Layout only — agents respawn fresh on reopen; status is never
/// persisted (a restored card is dormant/idle, so the glyph never lies).
struct Workspace: Codable {
    /// One persisted item. `kind` discriminates the type; `folder` is card-specific.
    /// Future item kinds add their own optional fields here.
    struct Item: Codable {
        var kind: String
        var id: String
        var title: String
        var x: Double, y: Double, w: Double, h: Double
        var folder: String?
    }
    struct Viewport: Codable { var cx: Double, cy: Double, mag: Double }

    var seq: Int
    var items: [Item]
    var viewport: Viewport?

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agentcanvas/workspace.json")

    static func load() -> Workspace? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Workspace.self, from: data)
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted]
            try enc.encode(self).write(to: Self.url)
        } catch {
            canvasLog("workspace save failed: \(error)")
        }
    }
}
