import AppKit

nonisolated struct WindowRecord: Codable, Equatable {
    var id: String
    var frame: String?
    var active: Bool = false

    init(id: String, frame: String? = nil, active: Bool = false) { self.id = id; self.frame = frame; self.active = active }
    private enum CodingKeys: String, CodingKey { case id, frame, active }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        frame = try? c.decode(String.self, forKey: .frame)
        active = (try? c.decode(Bool.self, forKey: .active)) ?? false
    }
    var valid: Bool { id == "main" || (id.count > 2 && id.count <= 64 && id.hasPrefix("w-") && id.dropFirst(2).allSatisfy { $0.isHexDigit || $0 == "-" }) }
    var rect: NSRect? {
        guard let frame else { return nil }
        let rect = NSRectFromString(frame)
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.width >= 560, rect.height >= 320, rect.width <= 20000, rect.height <= 20000 else { return nil }
        return rect
    }
}

nonisolated enum WindowCatalog {
    static var url: URL { Workspace.layoutURL.deletingLastPathComponent().appendingPathComponent("windows.json") }
    static func storageURL(_ id: String) -> URL {
        id == "main" ? Workspace.layoutURL : url.deletingLastPathComponent().appendingPathComponent("windows/\(id).json")
    }
    static func decode(_ data: Data) -> [WindowRecord] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        var seen = Set<String>()
        return array.compactMap { object in
            guard let bytes = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]),
                  let record = try? JSONDecoder().decode(WindowRecord.self, from: bytes), record.valid,
                  seen.insert(record.id).inserted else { return nil }
            return record
        }
    }
    static func load() -> [WindowRecord] {
        guard let data = try? Data(contentsOf: url) else { return [WindowRecord(id: "main")] }
        let records = decode(data)
        if let objects = try? JSONSerialization.jsonObject(with: data) as? [Any], objects.count == records.count, !records.isEmpty { return records }
        let backup = url.deletingLastPathComponent().appendingPathComponent("windows-recovery-\(Int(Date().timeIntervalSince1970)).json")
        try? data.write(to: backup, options: .atomic)
        return records.isEmpty ? [WindowRecord(id: "main")] : records
    }
    static func save(_ records: [WindowRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        let path = url
        queue.async { try? data.write(to: path, options: .atomic) }
    }
    static func finishSaving() { queue.sync {} }
    private static let queue = DispatchQueue(label: "tern.window-save")
}
