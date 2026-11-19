import AppKit

/// Minimal MCP (Model Context Protocol) server over stdio: `Clipbay --mcp`.
/// Reads the library directly; writes go through an inbox folder the running app imports.
enum MCPServer {
    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let id = msg["id"]
            let method = msg["method"] as? String ?? ""
            let params = msg["params"] as? [String: Any] ?? [:]
            guard id != nil else { continue } // notifications need no reply
            switch method {
            case "initialize":
                let version = params["protocolVersion"] as? String ?? "2025-06-18"
                reply(id, result: [
                    "protocolVersion": version,
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "clipbay", "version": "1.0.0"],
                    "instructions": "Clipbay is the user's clipboard history manager. Use search_clipboard to find things they copied, list_recent for the latest items, and save_item to add snippets.",
                ])
            case "ping":
                reply(id, result: [String: Any]())
            case "tools/list":
                reply(id, result: ["tools": tools])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                reply(id, result: call(name, args))
            default:
                send(["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "Method not found: \(method)"]])
            }
        }
        exit(0)
    }

    static func reply(_ id: Any?, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    static func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return }
        print(s)
        fflush(stdout)
    }

    static let kindEnum = ClipKind.allCases.map(\.rawValue)

    static var tools: [[String: Any]] {
        [
            tool("search_clipboard", "Search the user's clipboard history and pinboards (text, links, file names, and text recognized in images).",
                 ["query": ["type": "string", "description": "Words to search for"],
                  "type": ["type": "string", "enum": kindEnum, "description": "Only this content type"],
                  "app": ["type": "string", "description": "Only items copied from this app (name)"],
                  "limit": ["type": "integer", "description": "Max results (default 20)"]], required: ["query"]),
            tool("list_recent", "List the most recently copied items, newest first.",
                 ["limit": ["type": "integer", "description": "Max results (default 20)"],
                  "type": ["type": "string", "enum": kindEnum]]),
            tool("get_item", "Get the full content of one item by id. Images are returned as image content.",
                 ["id": ["type": "string"]], required: ["id"]),
            tool("list_pinboards", "List the user's pinboards with item counts.", [:]),
            tool("list_pinboard_items", "List items in a pinboard (by name or id).",
                 ["pinboard": ["type": "string"]], required: ["pinboard"]),
            tool("save_item", "Save a new text item to Clipbay, optionally into a pinboard (created if missing).",
                 ["text": ["type": "string"], "title": ["type": "string"], "pinboard": ["type": "string"]], required: ["text"]),
            tool("copy_to_clipboard", "Put an item (by id) on the system clipboard so the user can paste it.",
                 ["id": ["type": "string"]], required: ["id"]),
        ]
    }

    static func tool(_ name: String, _ desc: String, _ props: [String: Any], required: [String] = []) -> [String: Any] {
        ["name": name, "description": desc,
         "inputSchema": ["type": "object", "properties": props, "required": required]]
    }

    static func loadLibrary() -> Library {
        let url = Paths.activeRoot.appendingPathComponent("library.json")
        guard let data = try? Data(contentsOf: url) else { return Library() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return (try? dec.decode(Library.self, from: data)) ?? Library()
    }

    static func summary(_ it: ClipItem, _ lib: Library) -> [String: Any] {
        var d: [String: Any] = [
            "id": it.id.uuidString, "type": it.kind.rawValue, "title": it.displayTitle,
            "copied_at": ISO8601DateFormatter().string(from: it.date),
        ]
        if let a = it.sourceAppName { d["app"] = a }
        if let p = it.pinboardID, let b = lib.pinboards.first(where: { $0.id == p }) { d["pinboard"] = b.name }
        switch it.kind {
        case .text, .color: d["preview"] = String((it.text ?? "").prefix(300))
        case .link: d["url"] = it.url ?? ""; if let t = it.linkTitle { d["link_title"] = t }
        case .image:
            d["size"] = it.metaLine
            if let o = it.ocrText { d["text_in_image"] = String(o.prefix(300)) }
        case .file: d["files"] = it.fileURLs ?? []
        }
        return d
    }

    static func text(_ obj: Any) -> [String: Any] {
        let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return ["content": [["type": "text", "text": String(data: d, encoding: .utf8) ?? ""]]]
    }

    static func error(_ s: String) -> [String: Any] {
        ["content": [["type": "text", "text": s]], "isError": true]
    }

    static func call(_ name: String, _ args: [String: Any]) -> [String: Any] {
        guard UserDefaults.standard.bool(forKey: "mcpEnabled") else {
            return error("MCP access is turned off. Enable it in Clipbay › Settings › Intelligence.")
        }
        let lib = loadLibrary()
        let items = lib.items.sorted { $0.date > $1.date }
        let limit = (args["limit"] as? Int) ?? 20
        let kind = (args["type"] as? String).flatMap(ClipKind.init(rawValue:))

        switch name {
        case "search_clipboard":
            let words = ((args["query"] as? String) ?? "").lowercased().split(separator: " ").map(String.init)
            let app = (args["app"] as? String)?.lowercased()
            let hits = items.filter { it in
                if let kind, it.kind != kind { return false }
                if let app, !(it.sourceAppName ?? "").lowercased().contains(app) { return false }
                let blob = it.searchBlob.lowercased()
                return words.allSatisfy { blob.contains($0) }
            }
            return text(["count": hits.count, "results": hits.prefix(limit).map { summary($0, lib) }])
        case "list_recent":
            let list = items.filter { kind == nil || $0.kind == kind }
            return text(list.prefix(limit).map { summary($0, lib) })
        case "get_item":
            guard let it = find(args["id"], items) else { return error("No item with that id.") }
            var d = summary(it, lib)
            d["text"] = it.text ?? ""
            if let o = it.ocrText { d["text_in_image"] = o }
            var content: [[String: Any]] = text(d)["content"] as! [[String: Any]]
            if it.kind == .image {
                let url = Paths.activeRoot.appendingPathComponent("Blobs/\(it.id.uuidString)/thumb.png")
                if let png = try? Data(contentsOf: url) {
                    content.append(["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"])
                }
            }
            return ["content": content]
        case "list_pinboards":
            return text(lib.pinboards.sorted { $0.order < $1.order }.map { b in
                ["id": b.id.uuidString, "name": b.name, "items": items.filter { $0.pinboardID == b.id }.count] as [String: Any]
            })
        case "list_pinboard_items":
            let key = (args["pinboard"] as? String ?? "").lowercased()
            guard let b = lib.pinboards.first(where: { $0.name.lowercased() == key || $0.id.uuidString.lowercased() == key }) else {
                return error("No pinboard named \(key).")
            }
            let list = items.filter { $0.pinboardID == b.id }.sorted { ($0.pinOrder ?? 0) < ($1.pinOrder ?? 0) }
            return text(list.map { summary($0, lib) })
        case "save_item":
            guard let t = args["text"] as? String, !t.isEmpty else { return error("text is required") }
            var payload: [String: Any] = ["text": t]
            if let title = args["title"] as? String { payload["title"] = title }
            if let p = args["pinboard"] as? String { payload["pinboard"] = p }
            let dir = Paths.localRoot.appendingPathComponent("Inbox")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = dir.appendingPathComponent("\(UUID().uuidString).json")
            guard let d = try? JSONSerialization.data(withJSONObject: payload), (try? d.write(to: f)) != nil else {
                return error("Could not save the item.")
            }
            return text(["saved": true, "note": "Clipbay will add it within a couple of seconds."])
        case "copy_to_clipboard":
            guard let it = find(args["id"], items) else { return error("No item with that id.") }
            let pb = NSPasteboard.general
            pb.clearContents()
            if it.kind == .file, let urls = it.fileURLs {
                pb.writeObjects(urls.map { URL(fileURLWithPath: $0) as NSURL })
            } else if it.kind == .image,
                      let png = try? Data(contentsOf: Paths.activeRoot.appendingPathComponent("Blobs/\(it.id.uuidString)/\(Paths.safeName(NSPasteboard.PasteboardType.png.rawValue))")) {
                pb.setData(png, forType: .png)
            } else {
                pb.setString(it.text ?? "", forType: .string)
            }
            return text(["copied": true, "title": it.displayTitle])
        default:
            return error("Unknown tool \(name)")
        }
    }

    static func find(_ id: Any?, _ items: [ClipItem]) -> ClipItem? {
        guard let s = id as? String, let u = UUID(uuidString: s) else { return nil }
        return items.first { $0.id == u }
    }
}
