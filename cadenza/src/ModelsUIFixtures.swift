import AppKit

/// Drives the real "My AI models" controls through the accessibility tree of a real settings window, on a scratch configuration
/// and an in-memory Keychain: add a model, edit it, choose it for translation, delete it.
enum ModelsUIFixtures {
    // MARK: Accessibility helpers

    /// Every accessibility element under `root`, depth first.
    static func elements(_ root: Any, depth: Int = 0, into out: inout [NSObject]) {
        guard depth < 60 else { return }
        var children: [Any] = []
        if let view = root as? NSView { children = (view.accessibilityChildren() ?? []) + view.subviews }
        else if let element = root as? NSObject, element.responds(to: NSSelectorFromString("accessibilityChildren")) { children = (element.value(forKey: "accessibilityChildren") as? [Any]) ?? [] }
        for child in children {
            if let object = child as? NSObject { if !out.contains(where: { $0 === object }) { out.append(object) } }
            elements(child, depth: depth + 1, into: &out)
        }
    }
    static func all(_ window: NSWindow) -> [NSObject] { var out: [NSObject] = []; if let view = window.contentView { elements(view, into: &out) }; return out }
    static func label(_ e: NSObject) -> String {
        for key in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] where e.responds(to: NSSelectorFromString(key)) {
            if let s = e.value(forKey: key) as? String, !s.isEmpty { return s }
        }
        return ""
    }
    static func role(_ e: NSObject) -> String { e.responds(to: NSSelectorFromString("accessibilityRole")) ? ((e.value(forKey: "accessibilityRole") as? String) ?? "") : "" }
    static func find(_ window: NSWindow, label wanted: String, role wantedRole: String? = nil) -> NSObject? {
        all(window).first { label($0) == wanted && (wantedRole == nil || role($0) == wantedRole) }
    }
    static func press(_ e: NSObject) -> Bool {
        let sel = NSSelectorFromString("accessibilityPerformPress")
        guard e.responds(to: sel) else { return false }
        return e.perform(sel) != nil || true
    }
    static func pump(_ seconds: TimeInterval) { let end = Date(timeIntervalSinceNow: seconds); repeat { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) } while Date() < end }

    static func run(_ check: (String, Bool) -> Void) {
        let app = NSApplication.shared; app.setActivationPolicy(.regular); app.finishLaunching()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cadenza-models-ui-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ConfigStore(fileURL: root.appendingPathComponent("config.json"))
        let pipeline = VoicePipeline(configStore: store, input: InputSourceController()); pipeline.selfTestMode = true
        let main = SettingsWindowController(); main.configStore = store; main.pipeline = pipeline
        main.showSwift()
        defer { main.window?.close() }
        pump(0.8)
        guard let window = main.window, let model = main.settingsModel else { check("models ui: the settings window and its model exist", false); return }
        model.tab = .aiModels
        for _ in 0..<20 where !(window.isKeyWindow && NSApp.isActive) { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); pump(0.2) }
        pump(0.5)
        let addLabel = L10n.tr("llm.add")
        let tree = all(window)
        print("[models-ui-debug] accessibility elements found: \(tree.count); labels sample: \(tree.prefix(40).map { label($0) }.filter { !$0.isEmpty }.prefix(12))")
        check("models ui: the page shows the add button in the accessibility tree", find(window, label: addLabel) != nil)
        guard let add = find(window, label: addLabel) else { return }

        check("models ui: starts with no models", store.config.llmProfiles.isEmpty)
        _ = press(add); pump(0.6)
        check("models ui: pressing Add creates one model, selected for polish and translation", store.config.llmProfiles.count == 1 && store.config.refine.profileID == store.config.llmProfiles.first?.id && store.config.translate.profileID == store.config.llmProfiles.first?.id)
        let first = store.config.llmProfiles.first
        check("models ui: the new model has a name, an address and its own key account", first?.name.isEmpty == false && first?.baseURL == "https://api.deepseek.com/v1" && first?.keyName == "llm.profile." + (first?.id ?? "?"))
        check("models ui: the editor opened", find(window, label: L10n.tr("llm.delete")) != nil || find(window, label: L10n.tr("refine.test")) != nil)

        // Edit the open model: its name, its consent, its key
        /// The control that follows a row's label in the tree (a form row is a label and its control).
        func control(after labelText: String, role wanted: String) -> NSObject? {
            let sequence = all(window)
            guard let i = sequence.firstIndex(where: { label($0) == labelText && role($0) == "AXStaticText" }) else { return nil }
            return sequence[(i + 1)...].prefix(8).first { role($0) == wanted }
        }
        /// Types into a text field the way a person does: it takes the focus and the field editor receives the text.
        func type(into labelText: String, _ value: String) -> Bool {
            guard let cell = control(after: labelText, role: "AXTextField") as? NSCell, let field = cell.controlView as? NSTextField else { return false }
            window.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { return false }
            editor.selectAll(nil); editor.insertText(value, replacementRange: editor.selectedRange()); pump(0.4)
            return true
        }
        let nameSet = type(into: L10n.tr("llm.name"), "My test model")
        check("models ui: typing a new name is saved (field reachable: \(nameSet))", nameSet && store.config.llmProfiles.first?.name == "My test model")
        if let consent = control(after: L10n.tr("refine.consent"), role: "AXCheckBox") {
            _ = press(consent); pump(0.4)
            check("models ui: the consent switch saves for this model", store.config.llmProfiles.first?.consent == true)
        } else { check("models ui: the consent switch is there for a service that is not on this Mac", false) }
        let keyAccount = first?.keyName ?? "?"
        let keyTyped = type(into: L10n.tr("refine.key"), "sk-test-not-a-real-key")
        if let save = find(window, label: L10n.tr("refine.key.save")) {
            _ = press(save); pump(0.4)
            check("models ui: Save key stores the key under this model's own account (typed: \(keyTyped))", KeychainStore.get(keyAccount) == "sk-test-not-a-real-key")
            if let delete = find(window, label: L10n.tr("refine.key.delete")) {
                _ = press(delete); pump(0.4)
                check("models ui: Delete key removes it", KeychainStore.get(keyAccount) == nil)
            } else { check("models ui: a Delete key button appears once a key is saved", false) }
        } else { check("models ui: a Save key button is there", false) }

        _ = press(find(window, label: addLabel) ?? add); pump(0.6)
        check("models ui: a second Add makes a second model with a different name and key", store.config.llmProfiles.count == 2 && Set(store.config.llmProfiles.map(\.name)).count == 2 && Set(store.config.llmProfiles.map(\.keyName)).count == 2)
        check("models ui: the first model stays the choice for both uses", store.config.refine.profileID == first?.id && store.config.translate.profileID == first?.id)

        if let del = find(window, label: L10n.tr("llm.delete")) {
            _ = press(del); pump(0.4)
            check("models ui: Delete asks again before deleting", store.config.llmProfiles.count == 2 && find(window, label: L10n.tr("llm.delete.confirm")) != nil)
            if let confirm = find(window, label: L10n.tr("llm.delete.confirm")) {
                let editingName = store.config.llmProfiles.last?.name
                _ = press(confirm); pump(0.6)
                check("models ui: confirming deletes the model being edited", store.config.llmProfiles.count == 1 && store.config.llmProfiles.first?.name != editingName)
            }
        } else { check("models ui: a Delete button is there while a model is open", false) }
        check("models ui: the remaining model is still what polish and translation use", store.config.refine.profileID == store.config.llmProfiles.first?.id && store.config.translate.profileID == store.config.llmProfiles.first?.id)
        let reloaded = ConfigStore(fileURL: root.appendingPathComponent("config.json"))
        check("models ui: what was done is saved and reads back", reloaded.config.llmProfiles == store.config.llmProfiles && reloaded.config.refine.profileID == store.config.refine.profileID)
    }
}
