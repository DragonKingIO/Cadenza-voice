import SwiftUI
import AppKit

/// Result of asking the running interface about itself, for the "Test the interface" button.
enum LocalAPIProbeResult: Equatable { case ok(engine: String), notRunning, badToken, failed }

enum LocalAPIProbe {
    /// One authenticated GET to the loopback interface. Calls back on the main thread.
    static func run(port: Int, token: String, completion: @escaping (LocalAPIProbeResult) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/capabilities") else { completion(.failed); return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
            let result: LocalAPIProbeResult
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200:
                    let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                    // The interface answering with its version is what "working" means; the engine name is a bonus.
                    result = body?["api_version"] == nil ? .failed : .ok(engine: ((body?["engine"] as? [String: Any])?["title"] as? String) ?? "–")
                case 401: result = .badToken
                default: result = .failed
                }
            } else if let error = error as? URLError, [.cannotConnectToHost, .timedOut, .networkConnectionLost].contains(error.code) { result = .notRunning }
            else { result = .failed }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}

/// The Developer page is hidden for new users, but stays visible for anyone who has used the local interface
/// (an access token already exists), unless they switched it off themselves.
enum DeveloperPageVisibility {
    private static let key = "showDeveloperOptions"
    static func resolve(stored: Bool?, hasUsedInterface: Bool) -> Bool { stored ?? hasUsedInterface }
    static var current: Bool {
        resolve(stored: UserDefaults.standard.object(forKey: key) as? Bool, hasUsedInterface: FileManager.default.fileExists(atPath: LocalAPIStore.standard.tokenURL.path))
    }
    static func set(_ on: Bool) { UserDefaults.standard.set(on, forKey: key) }
}

enum DeveloperDocument {
    /// The interface documentation is shipped inside the app (English).
    static func text(directory: URL? = Bundle.main.resourceURL?.appendingPathComponent("legal", isDirectory: true)) -> String? {
        directory.flatMap { try? String(contentsOf: $0.appendingPathComponent("LOCAL-API.md"), encoding: .utf8) }
    }
}

/// Developer page (shown only when "Show developer options" is on): the loopback interface, a test, documentation, tools.
struct DeveloperView: View {
    var model: SettingsModel
    @State private var enabled = false
    @State private var portText = String(LocalAPISettings().port)
    @State private var status = LocalAPIService.Status.stopped
    @State private var connections = 0
    @State private var copied = false
    @State private var copiedExample = false
    @State private var confirmingRegenerate = false
    @State private var portInvalid = false
    @State private var testMessage = ""
    @State private var testing = false
    @State private var showingDocs = false
    @State private var allowInsert = false
    @State private var confirmingInsert = false
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var service: LocalAPIService? { model.localAPI }
    private var port: String { portText.isEmpty ? String(LocalAPISettings().port) : portText }
    private var address: String { "http://127.0.0.1:\(port)" }
    /// Uses a placeholder, so no internal folder name is shown; the Copy token button supplies the real value.
    static func exampleCommand(address: String) -> String { "curl -H \"Authorization: Bearer <token>\" \(address)/v1/capabilities" }
    private var example: String { Self.exampleCommand(address: address) }
    private static var tools: [(String, String)] { [
        ("--local-accuracy-probe", L10n.tr("developer.tool.probe")),
        ("--update-feed-override=http://127.0.0.1:8765/latest.json", L10n.tr("developer.tool.feed")),
        ("--selftest", L10n.tr("developer.tool.selftest"))] }

    private func refresh() {
        guard let service else { return }
        let settings = service.store.settings
        enabled = settings.enabled
        portText = String(settings.port)
        status = service.status
        connections = service.connectionCount
        allowInsert = settings.allowInsert
    }

    private func setAllowInsert(_ on: Bool) {
        guard let service else { return }
        var settings = service.store.settings; settings.allowInsert = on; service.store.settings = settings
        allowInsert = on
    }

    private var statusText: String {
        switch status {
        case .stopped: return L10n.tr("developer.status.off")
        case .running(let port): return L10n.format("developer.status.running", "127.0.0.1:\(port)")
        case .failed: return L10n.tr("developer.status.failed")
        }
    }

    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }

    var body: some View {
        SettingsPage {
            Section {
                Toggle(L10n.tr("developer.enable"), isOn: Binding(get: { enabled }, set: { value in
                    enabled = value; service?.setEnabled(value); status = service?.status ?? .stopped
                }))
                LabeledContent(L10n.tr("developer.status")) {
                    Text(statusText).foregroundStyle(status == .failed ? Color.orange : Color.secondary)
                }
                if case .running = status {
                    LabeledContent(L10n.tr("developer.connections")) {
                        Text(connections == 0 ? L10n.tr("developer.connections.none") : String(connections)).foregroundStyle(.secondary)
                    }
                }
                LabeledContent(L10n.tr("developer.port")) {
                    TextField("", text: $portText).frame(width: 80).multilineTextAlignment(.trailing)
                        .onSubmit {
                            guard let service, let value = Int(portText), LocalAPISettings.validPort(value) else { portInvalid = true; refresh(); return }
                            portInvalid = false
                            var settings = service.store.settings; settings.port = value; service.store.settings = settings
                            service.apply()
                        }
                }
                if portInvalid { Text(L10n.tr("developer.port.invalid")).font(.callout).foregroundStyle(.orange) }
            } footer: {
                Text(L10n.tr("developer.enable.hint")).font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Label(L10n.tr("developer.can.record"), systemImage: "checkmark.circle.fill").foregroundStyle(.primary, .green)
                Label(L10n.tr("developer.can.read"), systemImage: "checkmark.circle.fill").foregroundStyle(.primary, .green)
                Label(L10n.tr("developer.can.audio"), systemImage: "checkmark.circle.fill").foregroundStyle(.primary, .green)
                if allowInsert { Label(L10n.tr("developer.insert.on"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.primary, .orange) }
                else { Label(L10n.tr("developer.insert.off"), systemImage: "xmark.circle.fill").foregroundStyle(.secondary, .red) }
                Label(L10n.tr("developer.cannot.keys"), systemImage: "xmark.circle.fill").foregroundStyle(.secondary, .red)
                Label(L10n.tr("developer.cannot.network"), systemImage: "xmark.circle.fill").foregroundStyle(.secondary, .red)
                Toggle(L10n.tr("developer.insert.toggle"), isOn: Binding(get: { allowInsert }, set: { value in
                    if value { confirmingInsert = true } else { setAllowInsert(false) }
                }))
            } header: { Text(L10n.tr("developer.can.header")) }

            DeviceListSection(service: service)

            Section {
                LabeledContent(L10n.tr("developer.token")) {
                    HStack {
                        Button(L10n.tr(copied ? "developer.token.copied" : "developer.token.copy")) {
                            guard let service else { return }
                            copy(service.store.token()); copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                        }.buttonStyle(.borderless)
                        Button(L10n.tr("developer.token.regenerate"), role: .destructive) { confirmingRegenerate = true }.buttonStyle(.borderless)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(example).font(.system(.callout, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Button(L10n.tr(copiedExample ? "developer.token.copied" : "developer.example.copy")) {
                        copy(example); copiedExample = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedExample = false }
                    }.buttonStyle(.borderless)
                }
            } header: { Text(L10n.tr("developer.example")) } footer: {
                Text(L10n.tr("developer.token.footer")).font(.callout).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button(L10n.tr("developer.test.run")) {
                        guard let service else { return }
                        testing = true; testMessage = ""
                        LocalAPIProbe.run(port: Int(port) ?? LocalAPISettings().port, token: service.store.token()) { result in
                            testing = false
                            switch result {
                            case .ok(let engine): testMessage = L10n.format("developer.test.ok", engine)
                            case .notRunning: testMessage = L10n.tr("developer.test.off")
                            case .badToken: testMessage = L10n.tr("developer.test.token")
                            case .failed: testMessage = L10n.tr("developer.test.failed")
                            }
                        }
                    }.buttonStyle(.bordered).disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    if !testMessage.isEmpty { Text(testMessage).font(.callout).foregroundStyle(.secondary) }
                }
            } header: { Text(L10n.tr("developer.test")) }

            Section {
                Button(L10n.tr("developer.docs.open")) { showingDocs = true }.buttonStyle(.link)
            } header: { Text(L10n.tr("developer.docs.header")) }

            Section {
                ForEach(Self.tools, id: \.0) { tool in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.0).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            Text(tool.1).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L10n.tr("developer.tools.copy")) { copy(tool.0) }.buttonStyle(.borderless)
                    }
                }
                Button(L10n.tr("developer.tools.dataFolder")) { NSWorkspace.shared.open(AppPaths.supportDir) }.buttonStyle(.link)
            } header: { Text(L10n.tr("developer.tools.header")) } footer: {
                Text(L10n.tr("developer.tools.footer")).font(.callout).foregroundStyle(.secondary)
            }
        }
        .onAppear { refresh(); service?.onChange = { refresh() } }
        .onReceive(tick) { _ in if case .running = status { connections = service?.connectionCount ?? 0 } }
        .sheet(isPresented: $showingDocs) { MarkdownSheet(title: L10n.tr("legal.api"), markdown: DeveloperDocument.text()) { showingDocs = false } }
        .confirmationDialog(L10n.tr("developer.insert.confirm"), isPresented: $confirmingInsert, titleVisibility: .visible) {
            Button(L10n.tr("developer.insert.confirm.button")) { setAllowInsert(true) }
            Button(L10n.tr("developer.devices.cancel"), role: .cancel) {}
        }
        .confirmationDialog(L10n.tr("developer.token.regenerate.confirm"), isPresented: $confirmingRegenerate) {
            Button(L10n.tr("developer.token.regenerate"), role: .destructive) { service?.regenerateToken() }
        }
    }
}

// MARK: - Devices

struct DeviceListSection: View {
    let service: LocalAPIService?
    @State private var devices: [LocalAPIDevice] = []
    @State private var adding = false
    @State private var removing: LocalAPIDevice?

    private func summary(_ d: LocalAPIDevice) -> String {
        LocalAPIPermission.allCases.filter { d.permissionSet.contains($0) }.map { L10n.tr($0.titleKey) }.joined(separator: " · ")
    }

    var body: some View {
        Section {
            if devices.isEmpty { Text(L10n.tr("developer.devices.none")).font(.callout).foregroundStyle(.secondary) }
            ForEach(devices) { device in
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name).font(.headline)
                        Text(summary(device)).font(.callout).foregroundStyle(.secondary)
                        Text(L10n.format("developer.devices.created", device.created.formatted(date: .abbreviated, time: .omitted))).font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button(L10n.tr("developer.devices.revoke"), role: .destructive) { removing = device }.buttonStyle(.borderless)
                }
            }
            Button(L10n.tr("developer.devices.add")) { adding = true }.disabled(service == nil || devices.count >= LocalAPIDeviceStore.maxDevices)
        } header: { Text(L10n.tr("developer.devices.header")) } footer: {
            Text(L10n.tr("developer.devices.footer")).font(.callout).foregroundStyle(.secondary)
        }
        .onAppear { devices = service?.devices.devices ?? [] }
        .sheet(isPresented: $adding) { AddDeviceSheet(service: service) { devices = service?.devices.devices ?? []; adding = false } }
        .confirmationDialog(L10n.format("developer.devices.revoke.confirm", removing?.name ?? ""), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button(L10n.tr("developer.devices.revoke"), role: .destructive) {
                if let d = removing { service?.revokeDevice(id: d.id); devices = service?.devices.devices ?? [] }
                removing = nil
            }
        }
    }
}

struct AddDeviceSheet: View {
    let service: LocalAPIService?
    var onClose: () -> Void
    @State private var name = ""
    @State private var permissions: Set<LocalAPIPermission> = [.audio]
    @State private var error = ""
    @State private var created: (name: String, token: String)?
    @State private var copied = false

    private func create() {
        guard let service else { return }
        switch service.devices.add(name: name, permissions: permissions) {
        case .success(let result): created = (result.device.name, result.token)
        case .failure(let e):
            switch e {
            case .invalidName: error = L10n.tr("developer.devices.error.name")
            case .noPermissions: error = L10n.tr("developer.devices.error.permissions")
            case .tooMany: error = L10n.tr("developer.devices.error.many")
            case .saveFailed: error = L10n.tr("developer.devices.error.save")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let created {
                Text(L10n.format("developer.devices.token.title", created.name)).font(.headline)
                Text(created.token).font(.system(.callout, design: .monospaced)).textSelection(.enabled).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                Label(L10n.tr("developer.devices.token.warning"), systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L10n.tr(copied ? "developer.token.copied" : "developer.token.copy")) {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(created.token, forType: .string); copied = true
                    }
                    Spacer()
                    Button(L10n.tr("developer.devices.done")) { onClose() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text(L10n.tr("developer.devices.add")).font(.headline)
                TextField(L10n.tr("developer.devices.name"), text: $name, prompt: Text(L10n.tr("developer.devices.name.hint"))).textFieldStyle(.roundedBorder)
                Text(L10n.tr("developer.devices.permissions")).font(.subheadline.bold())
                ForEach(LocalAPIPermission.allCases, id: \.self) { p in
                    Toggle(L10n.tr(p.titleKey), isOn: Binding(get: { permissions.contains(p) }, set: { on in if on { permissions.insert(p) } else { permissions.remove(p) } })).toggleStyle(.checkbox)
                }
                if !error.isEmpty { Text(error).font(.callout).foregroundStyle(.orange) }
                HStack {
                    Button(L10n.tr("developer.devices.cancel")) { onClose() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(L10n.tr("developer.devices.create")) { create() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20).frame(width: 440)
    }
}
