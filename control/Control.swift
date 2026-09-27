import AppKit
import Foundation
import SQLite3

let routerHome = ProcessInfo.processInfo.environment["LAYA_ROUTER_HOME"] ??
    (NSHomeDirectory() as NSString).appendingPathComponent(".config/laya-opencode-router")
let root = URL(fileURLWithPath: routerHome)
let settingsURL = root.appendingPathComponent("settings.json")
let cli = ProcessInfo.processInfo.environment["OPENCODE_CLI"] ?? "/Applications/OpenCode.app/Contents/Resources/opencode-cli"

struct ModelRef: Codable, Equatable { var providerID: String; var id: String }
struct Settings: Codable { var enabled: Bool; var models: [String: ModelRef] }
struct Model: Equatable {
    var ref: ModelRef; var name: String; var family: String; var released: Double?; var isFree: Bool
    var key: String { "\(ref.providerID):\(ref.id)" }
    var displayName: String { isFree ? "\(name) · 免费" : name }
}

func modelIsFree(_ item: [String: Any]) -> Bool {
    let name = item["name"] as? String ?? ""
    let id = item["id"] as? String ?? ""
    if name.range(of: #"\bfree\b"#, options: .regularExpression.union(.caseInsensitive)) != nil ||
       id.range(of: #"(?:^|[-_])free(?:$|[-_])"#, options: .regularExpression.union(.caseInsensitive)) != nil { return true }
    guard item["providerID"] as? String == "opencode",
          let costs = item["cost"] as? [[String: Any]], !costs.isEmpty else { return false }
    return costs.allSatisfy { ($0["input"] as? NSNumber)?.doubleValue == 0 &&
        ($0["output"] as? NSNumber)?.doubleValue == 0 }
}

// OpenCode Desktop persists UI visibility separately from API model availability.
func readVisibility() throws -> [String: String] {
    let path = ProcessInfo.processInfo.environment["OPENCODE_DRAFTS_DB"] ??
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/ai.opencode.desktop/drafts.sqlite")
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        if db != nil { sqlite3_close(db) }
        throw NSError(domain: "无法读取 OpenCode 的模型显示设置", code: 1)
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 100)
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT value FROM state WHERE name='opencode.global.dat' AND key='model'", -1, &statement, nil) == SQLITE_OK else {
        throw NSError(domain: "OpenCode 模型显示设置格式已变化", code: 2)
    }
    defer { sqlite3_finalize(statement) }
    let result = sqlite3_step(statement)
    if result == SQLITE_DONE { return [:] }
    guard result == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0) else {
        throw NSError(domain: "OpenCode 模型显示设置暂不可读", code: 3)
    }
    let data = Data(String(cString: bytes).utf8)
    let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    var visibility: [String: String] = [:]
    for item in body?["user"] as? [[String: Any]] ?? [] {
        if let provider = item["providerID"] as? String, let id = item["modelID"] as? String,
           let value = item["visibility"] as? String { visibility["\(provider):\(id)"] = value }
    }
    return visibility
}

func visibleModels(_ catalog: [Model], _ visibility: [String: String], now: Double = Date().timeIntervalSince1970) -> [Model] {
    var latest: [String: Model] = [:]
    for model in catalog {
        guard let released = model.released, abs(now - released) < 262974.6 * 60 else { continue }
        let family = "\(model.ref.providerID):\(model.family)"
        if released > (latest[family]?.released ?? -.infinity) { latest[family] = model }
    }
    let defaults = Set(latest.values.map { $0.key })
    return catalog.filter { model in
        if let explicit = visibility[model.key] { return explicit == "show" }
        return model.released == nil || defaults.contains(model.key)
    }
}

func cliJSON(_ path: String, method: String = "GET") throws -> Any {
    let p = Process(); p.executableURL = URL(fileURLWithPath: cli)
    p.arguments = ["api", method, path]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    try p.run()
    DispatchQueue.global().asyncAfter(deadline: .now() + 20) { if p.isRunning { p.terminate() } }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw NSError(domain: "无法读取 OpenCode，请确认应用已安装。", code: 1) }
    return data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data)
}

final class App: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var toggle = NSSwitch()
    var mcpBusy = false
    var mcpReady = false
    var contextDirectory = ""
    var routeState = NSTextField(labelWithString: "正在同步…")
    var selectors: [String: NSPopUpButton] = [:]
    var models: [Model] = []
    var catalog: [Model] = []
    var visibility: [String: String] = [:]
    var providerNames: [String: String] = [:]
    var hasCatalog = false
    var modelSummary = NSTextField(labelWithString: "正在同步 OpenCode 模型显示设置…")
    var settings: Settings!
    var loading = true
    var savedLabel = NSTextField(labelWithString: "正在读取配置…")
    var lastLabel = NSTextField(wrappingLabelWithString: "尚无路由记录")
    var refresh = NSButton()
    var timer: Timer?
    let resultTiers = [("file_search", "本地文件 RAG", "只查找文件名或路径；本地检索后交给所选模型"), ("local", "简单任务", "解释、翻译和小范围修改"), ("standard", "常规任务", "常规开发、调试和多步骤任务"), ("advanced", "复杂任务", "架构、迁移与需要深入推理的任务")]
    let controlTiers = [("classifier", "备用分类模型", "Laya 失败时接手判断任务档位"), ("fallback", "最终处理模型", "两次分类均失败时直接处理任务")]
    var tiers: [(String, String, String)] { resultTiers + controlTiers }

    func label(_ text: String, size: CGFloat = 13, bold: Bool = false) -> NSTextField {
        let v = NSTextField(labelWithString: text)
        v.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        return v
    }
    func vertical(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        return stack
    }
    func row(_ left: NSView, _ right: NSView) -> NSStackView {
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [left, spacer, right]); stack.orientation = .horizontal; stack.alignment = .centerY
        return stack
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 790, height: 710), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Laya 路由控制"; window.center(); window.isReleasedWhenClosed = false
        let menu = NSMenu(); let appMenu = NSMenuItem(); menu.addItem(appMenu)
        let sub = NSMenu(); sub.addItem(withTitle: "退出 Laya 路由控制", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); appMenu.submenu = sub; NSApp.mainMenu = menu

        toggle.target = self; toggle.action = #selector(toggleMCP); toggle.isEnabled = false; toggle.setAccessibilityLabel("启用自动路由")
        routeState.font = .boldSystemFont(ofSize: 13)
        routeState.textColor = .secondaryLabelColor
        let switchGroup = NSStackView(views: [routeState, toggle])
        switchGroup.orientation = .horizontal; switchGroup.alignment = .centerY; switchGroup.spacing = 9
        let titleGroup = vertical([label("Laya 路由控制", size: 25, bold: true), label("为不同复杂度的任务选择模型", size: 12)], spacing: 5)
        let heading = row(titleGroup, switchGroup)
        modelSummary.font = .systemFont(ofSize: 11); modelSummary.textColor = .secondaryLabelColor
        let content = vertical([heading, modelSummary], spacing: 14)
        let topDivider = NSBox(); topDivider.boxType = .separator
        content.addArrangedSubview(topDivider); topDivider.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        func addSection(_ title: String, _ rows: [(String, String, String)]) {
            let sectionTitle = label(title, size: 13, bold: true)
            sectionTitle.textColor = .secondaryLabelColor
            content.addArrangedSubview(sectionTitle)
            for (key, rowTitle, detail) in rows {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false); popup.identifier = NSUserInterfaceItemIdentifier(key)
            popup.target = self; popup.action = #selector(save); popup.isEnabled = false
            popup.widthAnchor.constraint(equalToConstant: 435).isActive = true
            selectors[key] = popup
            let description = label(detail, size: 11); description.textColor = .secondaryLabelColor
            let r = row(vertical([label(rowTitle, size: 14, bold: true), description], spacing: 5), popup)
            content.addArrangedSubview(r); r.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            }
        }
        addSection("路由结果", resultTiers)
        let sectionDivider = NSBox(); sectionDivider.boxType = .separator
        content.addArrangedSubview(sectionDivider); sectionDivider.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        addSection("路由控制", controlTiers)
        let separator = NSBox(); separator.boxType = .separator; content.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        lastLabel.font = .systemFont(ofSize: 11); lastLabel.textColor = .secondaryLabelColor
        lastLabel.maximumNumberOfLines = 1
        lastLabel.lineBreakMode = .byTruncatingMiddle
        content.addArrangedSubview(lastLabel)
        lastLabel.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        refresh = NSButton(title: "刷新模型", target: self, action: #selector(refreshModels)); refresh.bezelStyle = .rounded
        let openButton = NSButton(title: "打开 OpenCode", target: self, action: #selector(openOpenCode)); openButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [refresh, openButton]); buttons.spacing = 10
        content.addArrangedSubview(buttons)
        savedLabel.font = .systemFont(ofSize: 11); savedLabel.textColor = .systemRed
        savedLabel.isHidden = true; content.addArrangedSubview(savedLabel)
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28), content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28), content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 25), heading.widthAnchor.constraint(equalTo: content.widthAnchor), modelSummary.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor)])
        do { settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: settingsURL)); settings.models["classifier"] = settings.models["classifier"] ?? settings.models["standard"]; settings.models["file_search"] = settings.models["file_search"] ?? settings.models["local"]; toggle.state = settings.enabled ? .on : .off }
        catch { toggle.isEnabled = false; savedLabel.stringValue = "无法读取配置：\(error.localizedDescription)"; savedLabel.textColor = .systemRed; savedLabel.isHidden = false }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        refreshModels(); checkStatus(); syncMCP()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.checkStatus(); self?.syncVisibility(); self?.syncMCP() }
    }
    @objc func refreshModels() {
        refresh.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let body = try cliJSON("/api/model") as? [String: Any]
                let list = (body?["data"] as? [[String: Any]] ?? []).compactMap { item -> Model? in
                    guard item["enabled"] as? Bool == true, (item["capabilities"] as? [String: Any])?["tools"] as? Bool == true,
                          let provider = item["providerID"] as? String, let id = item["id"] as? String else { return nil }
                    let milliseconds = (item["time"] as? [String: Any])?["released"] as? Double
                    return Model(ref: ModelRef(providerID: provider, id: id), name: item["name"] as? String ?? id,
                                 family: item["family"] as? String ?? "", released: milliseconds.map { $0 / 1000 },
                                 isFree: modelIsFree(item))
                }.sorted { ($0.ref.providerID, $0.name) < ($1.ref.providerID, $1.name) }
                let visibility = (try? readVisibility()) ?? [:]
                let providers = try cliJSON("/api/provider") as? [String: Any]
                var names: [String: String] = [:]
                for provider in providers?["data"] as? [[String: Any]] ?? [] {
                    if let id = provider["id"] as? String { names[id] = provider["name"] as? String ?? id }
                }
                DispatchQueue.main.async {
                    self.catalog = list; self.visibility = visibility; self.providerNames = names; self.hasCatalog = true
                    self.applyVisibility(); self.refresh.isEnabled = true
                    self.savedLabel.isHidden = true
                }
            } catch {
                DispatchQueue.main.async { self.populate(); self.refresh.isEnabled = true; self.savedLabel.stringValue = "模型刷新失败：\(error.localizedDescription)"; self.savedLabel.textColor = .systemRed; self.savedLabel.isHidden = false }
            }
        }
    }
    func syncVisibility() {
        guard hasCatalog, refresh.isEnabled else { return }
        do {
            let current = try readVisibility()
            if current != visibility { visibility = current; applyVisibility() }
        } catch {
            modelSummary.stringValue = "显示设置同步失败，保留上次列表；可点击刷新重试"
        }
    }
    func applyVisibility() {
        models = visibleModels(catalog, visibility)
        modelSummary.stringValue = "\(models.count) 个可选模型 · \(catalog.count - models.count) 个已隐藏 · 按供应商分组"
        populate()
    }
    func populate() {
        guard settings != nil else { return }
        loading = true
        let groups = Dictionary(grouping: models, by: { $0.ref.providerID })
        let priority = ["opencode-go", "opencode", "anthropic", "github-copilot", "openai", "google", "openrouter", "vercel"]
        let providers = groups.keys.sorted {
            let a = priority.firstIndex(of: $0) ?? priority.count
            let b = priority.firstIndex(of: $1) ?? priority.count
            return a == b ? (providerNames[$0] ?? $0) < (providerNames[$1] ?? $1) : a < b
        }
        for (key, _, _) in tiers {
            guard let popup = selectors[key], let selected = settings.models[key] else { continue }
            popup.removeAllItems(); popup.menu?.autoenablesItems = false
            var selection: NSMenuItem?
            if !models.contains(where: { $0.ref == selected }) {
                let placeholder = NSMenuItem(title: hasCatalog ? "当前模型已隐藏或不可用，请重新选择" : "请刷新模型列表", action: nil, keyEquivalent: "")
                placeholder.isEnabled = false; popup.menu?.addItem(placeholder); selection = placeholder
            }
            for provider in providers {
                if popup.numberOfItems > 0 { popup.menu?.addItem(.separator()) }
                let heading = NSMenuItem(title: providerNames[provider] ?? provider, action: nil, keyEquivalent: "")
                heading.isEnabled = false; popup.menu?.addItem(heading)
                for model in groups[provider] ?? [] {
                    let item = NSMenuItem(title: model.displayName, action: nil, keyEquivalent: "")
                    item.indentationLevel = 1
                    item.representedObject = ["providerID": model.ref.providerID, "id": model.ref.id]
                    item.toolTip = "\(model.ref.providerID)/\(model.ref.id)"
                    popup.menu?.addItem(item)
                    if model.ref == selected { selection = item }
                }
            }
            popup.select(selection); popup.isEnabled = !models.isEmpty
        }
        loading = false; toggle.isEnabled = mcpReady && !mcpBusy
    }
    @objc func save() {
        guard !loading, settings != nil else { return }
        var value = settings!
        value.enabled = settings.enabled
        for (key, popup) in selectors {
            if let item = popup.selectedItem?.representedObject as? [String: String], let provider = item["providerID"], let id = item["id"] { value.models[key] = ModelRef(providerID: provider, id: id) }
        }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: settingsURL, options: .atomic)
            settings = value
            savedLabel.isHidden = true
        } catch {
            toggle.state = settings.enabled ? .on : .off; populate()
            savedLabel.stringValue = "保存失败：\(error.localizedDescription)"; savedLabel.textColor = .systemRed; savedLabel.isHidden = false
        }
    }
    func readContext() -> String {
        if let data = try? Data(contentsOf: root.appendingPathComponent("context.json")),
           let body = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let directory = body["directory"] { return directory }
        return NSHomeDirectory()
    }
    func mcpPath(_ path: String, directory: String) -> String {
        let encoded = directory.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        return path + "?location%5Bdirectory%5D=" + encoded
    }
    func loadMCP(_ directory: String) throws -> String {
        let body = try cliJSON(mcpPath("/api/mcp", directory: directory)) as? [String: Any]
        guard let servers = body?["data"] as? [[String: Any]],
              let laya = servers.first(where: { $0["name"] as? String == "laya" }),
              let status = (laya["status"] as? [String: Any])?["status"] as? String else {
            throw NSError(domain: "此工作区未配置 Laya MCP", code: 1)
        }
        return status
    }
    func applyMCP(_ status: String, directory: String) {
        guard settings != nil else { return }
        let enabled = status != "disabled"
        // Reload model choices before mirroring enablement to avoid overwriting external edits.
        if let fresh = try? JSONDecoder().decode(Settings.self, from: Data(contentsOf: settingsURL)) { settings = fresh }
        if settings.enabled != enabled {
            settings.enabled = enabled
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do { try encoder.encode(settings).write(to: settingsURL, options: .atomic) }
            catch { savedLabel.stringValue = "配置保存失败：\(error.localizedDescription)"; savedLabel.isHidden = false }
        }
        contextDirectory = directory; mcpReady = true
        toggle.state = enabled ? .on : .off; toggle.isEnabled = true
        routeState.stringValue = enabled ? "已启用" : "已关闭"
        routeState.toolTip = "工作区：\(directory)"
        routeState.textColor = enabled ? .systemGreen : .secondaryLabelColor
        savedLabel.isHidden = true
    }
    func syncMCP() {
        guard !mcpBusy else { return }
        mcpBusy = true
        let directory = readContext()
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try self.loadMCP(directory) }
            DispatchQueue.main.async {
                self.mcpBusy = false
                guard directory == self.readContext() else { self.syncMCP(); return }
                switch result {
                case .success(let status): self.applyMCP(status, directory: directory)
                case .failure(let error):
                    self.mcpReady = false; self.toggle.isEnabled = false
                    self.routeState.stringValue = "同步失败"
                    self.routeState.textColor = .systemOrange
                    self.savedLabel.stringValue = "Laya MCP：\(error.localizedDescription)"
                    self.savedLabel.isHidden = false
                }
            }
        }
    }
    @objc func toggleMCP() {
        guard !mcpBusy, mcpReady else { toggle.state = settings.enabled ? .on : .off; return }
        let enabled = toggle.state == .on
        let directory = readContext()
        mcpBusy = true; toggle.isEnabled = false
        routeState.stringValue = "同步中…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () -> String in
                _ = try cliJSON(self.mcpPath("/api/experimental/mcp/laya/" + (enabled ? "connect" : "disconnect"), directory: directory), method: "POST")
                return try self.loadMCP(directory)
            }
            DispatchQueue.main.async {
                self.mcpBusy = false
                switch result {
                case .success(let status): self.applyMCP(status, directory: directory)
                case .failure(let error):
                    self.toggle.state = self.settings.enabled ? .on : .off
                    self.toggle.isEnabled = true
                    self.savedLabel.stringValue = "切换失败：\(error.localizedDescription)"
                    self.savedLabel.textColor = .systemRed
                    self.savedLabel.isHidden = false
                }
            }
        }
    }
    func checkStatus() {
        if let data = try? Data(contentsOf: root.appendingPathComponent("status.json")),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let model = value["model"] as? [String: String] {
            let tier = tiers.first { $0.0 == value["tier"] as? String }?.1 ?? "未知"
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = (value["time"] as? String).flatMap { formatter.date(from: $0) }
            let when = date.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? ""
            let classifier = value["classifier"] as? String
            let backup = value["classifierModel"] as? [String: String]
            let source = classifier == "file-search-policy" ? "本地检索" :
                (classifier == "backup" ? "备用分类 \(backup?["id"] ?? "")" :
                 (classifier == "none" ? "两次分类均失败" : "Laya"))
            lastLabel.stringValue = "最近路由 · \(tier) → \(model["id"] ?? "") · \(source) \(when)"
        }
    }
    @objc func openOpenCode() { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/OpenCode.app")) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let delegate = App()
let app = NSApplication.shared
app.delegate = delegate
app.run()
