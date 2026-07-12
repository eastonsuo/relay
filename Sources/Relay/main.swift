import AppKit
import SwiftUI

enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct AppReference: Identifiable, Codable, Equatable, Hashable {
    var id: String { bundleIdentifier.isEmpty ? path : bundleIdentifier }
    var bundleIdentifier: String
    var name: String
    var path: String
}

struct WorkspaceContext: Codable, Equatable {
    var applications: [AppReference]
    var note: String
    var extensions: [String: JSONValue]

    init(
        applications: [AppReference] = [],
        note: String = "",
        extensions: [String: JSONValue] = [:]
    ) {
        self.applications = applications
        self.note = note
        self.extensions = extensions
    }

    enum CodingKeys: String, CodingKey {
        case applications, note, extensions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        applications = try container.decodeIfPresent([AppReference].self, forKey: .applications) ?? []
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions) ?? [:]
    }
}

struct TrackedApp: Identifiable, Codable, Equatable {
    var id: String { bundleIdentifier.isEmpty ? path : bundleIdentifier }
    var bundleIdentifier: String
    var name: String
    var path: String
    var switchCount: Int
    var lastActivated: Date

    var reference: AppReference {
        AppReference(bundleIdentifier: bundleIdentifier, name: name, path: path)
    }
}

@MainActor
final class ApplicationUsageStore: NSObject, ObservableObject {
    @Published private(set) var apps: [TrackedApp] = []

    override init() {
        super.init()
        apps = RelayPersistence.shared.document.usage.applications
        seedInstalledApplications()
        seedRunningApplications()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    var suggestions: [TrackedApp] {
        apps.sorted {
            if $0.switchCount != $1.switchCount {
                return $0.switchCount > $1.switchCount
            }
            if $0.lastActivated != $1.lastActivated {
                return $0.lastActivated > $1.lastActivated
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var frequentSuggestions: [TrackedApp] {
        suggestions.filter { $0.switchCount > 0 }
    }

    var allSuggestions: [TrackedApp] {
        apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        record(app, increment: true)
    }

    private func seedRunningApplications() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            record(app, increment: false)
        }
    }

    private func seedInstalledApplications() {
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]

        for root in roots {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for url in urls where url.pathExtension.lowercased() == "app" {
                guard let bundle = Bundle(url: url) else { continue }
                let bundleIdentifier = bundle.bundleIdentifier ?? url.path
                guard bundleIdentifier != Bundle.main.bundleIdentifier else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                register(bundleIdentifier: bundleIdentifier, name: name, path: url.path)
            }
        }

        persist()
    }

    private func record(_ app: NSRunningApplication, increment: Bool) {
        guard app.activationPolicy == .regular,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              let name = app.localizedName,
              let path = app.bundleURL?.path else {
            return
        }

        let bundleIdentifier = app.bundleIdentifier ?? path
        register(bundleIdentifier: bundleIdentifier, name: name, path: path)
        if let index = apps.firstIndex(where: { $0.id == bundleIdentifier }) {
            if increment {
                apps[index].switchCount += 1
                apps[index].lastActivated = Date()
            }
        }

        persist()
    }

    private func register(bundleIdentifier: String, name: String, path: String) {
        if let index = apps.firstIndex(where: { $0.id == bundleIdentifier }) {
            apps[index].name = name
            apps[index].path = path
        } else {
            apps.append(
                TrackedApp(
                    bundleIdentifier: bundleIdentifier,
                    name: name,
                    path: path,
                    switchCount: 0,
                    lastActivated: .distantPast
                )
            )
        }
    }

    private func persist() {
        RelayPersistence.shared.saveApplicationUsage(apps)
    }
}

struct DetailItem: Identifiable, Codable, Equatable {
    var id: UUID
    var text: String
    var createdAt: Date
    var extensions: [String: JSONValue]

    init(
        id: UUID = UUID(),
        text: String = "",
        createdAt: Date = Date(),
        extensions: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.extensions = extensions
    }
}

struct WorkContext: Identifiable, Codable, Equatable {
    var id: UUID
    var focus: String
    var details: [DetailItem]
    var workspace: WorkspaceContext
    var archivedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var extensions: [String: JSONValue]

    var isArchived: Bool { archivedAt != nil }

    enum CodingKeys: String, CodingKey {
        case id, focus, details, workspace, archivedAt, createdAt, updatedAt, extensions
        case title, content
        case status, archived
        case address, apps
    }

    init(
        id: UUID = UUID(),
        focus: String,
        details: [DetailItem] = [],
        workspace: WorkspaceContext = WorkspaceContext(),
        archivedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        extensions: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.focus = focus
        self.details = details
        self.workspace = workspace
        self.archivedAt = archivedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.extensions = extensions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        focus = try container.decodeIfPresent(String.self, forKey: .focus)
            ?? container.decodeIfPresent(String.self, forKey: .title)
            ?? ""
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? updatedAt
        if let decodedDetails = try container.decodeIfPresent([DetailItem].self, forKey: .details) {
            details = decodedDetails
        } else if let legacyContent = try container.decodeIfPresent(String.self, forKey: .content),
                  !legacyContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            details = [DetailItem(text: legacyContent, createdAt: createdAt)]
        } else {
            details = []
        }
        if let decodedWorkspace = try container.decodeIfPresent(WorkspaceContext.self, forKey: .workspace) {
            workspace = decodedWorkspace
        } else {
            workspace = WorkspaceContext(
                applications: try container.decodeIfPresent([AppReference].self, forKey: .apps) ?? [],
                note: try container.decodeIfPresent(String.self, forKey: .address) ?? ""
            )
        }
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        if archivedAt == nil, try container.decodeIfPresent(Bool.self, forKey: .archived) == true {
            archivedAt = updatedAt
        }
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(focus, forKey: .focus)
        try container.encode(details, forKey: .details)
        try container.encode(workspace, forKey: .workspace)
        try container.encodeIfPresent(archivedAt, forKey: .archivedAt)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(extensions, forKey: .extensions)
    }
}

struct UsageData: Codable, Equatable {
    var applications: [TrackedApp]

    init(applications: [TrackedApp] = []) {
        self.applications = applications
    }
}

struct RelayDocument: Codable, Equatable {
    var schemaVersion: Int
    var documentID: UUID
    var applicationVersion: String
    var createdAt: Date
    var updatedAt: Date
    var activeContextID: UUID?
    var contexts: [WorkContext]
    var usage: UsageData
    var extensions: [String: JSONValue]
    var migratedFrom: String?
}

private struct LegacyContextSnapshot: Codable {
    var contexts: [WorkContext]
    var activeContextID: UUID?
}

@MainActor
final class RelayPersistence {
    static let shared = RelayPersistence()
    static let currentSchemaVersion = 1

    private(set) var document: RelayDocument
    let fileURL: URL
    private var canWrite = true
    private var pendingWrite: DispatchWorkItem?

    private init() {
        let fileManager = FileManager.default
        let applicationSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let directory = applicationSupport.appendingPathComponent("Relay", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("relay.json")

        if fileManager.fileExists(atPath: fileURL.path) {
            if let data = try? Data(contentsOf: fileURL),
               let version = Self.schemaVersion(in: data),
               version == Self.currentSchemaVersion,
               let decoded = try? Self.decoder.decode(RelayDocument.self, from: data) {
                document = decoded
            } else {
                document = Self.emptyDocument()
                canWrite = false
                NSLog("Relay data file is invalid or uses an unsupported schema; file left untouched")
            }
        } else if let migrated = Self.migrateLegacyUserDefaults() {
            document = migrated
        } else {
            document = Self.emptyDocument()
        }

        if canWrite {
            writeDocument()
        }
    }

    func saveContexts(_ contexts: [WorkContext], activeContextID: UUID?) {
        guard canWrite else { return }
        document.contexts = contexts
        document.activeContextID = activeContextID
        scheduleWrite()
    }

    func saveApplicationUsage(_ applications: [TrackedApp]) {
        guard canWrite else { return }
        document.usage.applications = applications
        scheduleWrite()
    }

    func flush() {
        guard canWrite else { return }
        pendingWrite?.cancel()
        pendingWrite = nil
        writeDocument()
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingWrite = nil
            self.writeDocument()
        }
        pendingWrite = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func writeDocument() {
        document.schemaVersion = Self.currentSchemaVersion
        document.applicationVersion = Self.applicationVersion
        document.updatedAt = Date()

        do {
            let data = try Self.encoder.encode(document)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Relay could not save %@: %@", fileURL.path, error.localizedDescription)
        }
    }

    private static var applicationVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func schemaVersion(in data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["schemaVersion"] as? Int
    }

    private static func emptyDocument() -> RelayDocument {
        let now = Date()
        return RelayDocument(
            schemaVersion: currentSchemaVersion,
            documentID: UUID(),
            applicationVersion: applicationVersion,
            createdAt: now,
            updatedAt: now,
            activeContextID: nil,
            contexts: [],
            usage: UsageData(),
            extensions: [:],
            migratedFrom: nil
        )
    }

    private static func migrateLegacyUserDefaults() -> RelayDocument? {
        let defaults = UserDefaults.standard
        let legacyContextData = defaults.data(forKey: "relay.contexts.v1")
        let legacyUsageData = defaults.data(forKey: "relay.appUsage.v1")
        guard legacyContextData != nil || legacyUsageData != nil else { return nil }

        let legacyDecoder = JSONDecoder()
        let snapshot = legacyContextData.flatMap {
            try? legacyDecoder.decode(LegacyContextSnapshot.self, from: $0)
        }
        let applications = legacyUsageData.flatMap {
            try? legacyDecoder.decode([TrackedApp].self, from: $0)
        } ?? []
        let now = Date()

        return RelayDocument(
            schemaVersion: currentSchemaVersion,
            documentID: UUID(),
            applicationVersion: applicationVersion,
            createdAt: now,
            updatedAt: now,
            activeContextID: snapshot?.activeContextID,
            contexts: snapshot?.contexts ?? [],
            usage: UsageData(applications: applications),
            extensions: [:],
            migratedFrom: "userDefaults-v1"
        )
    }
}

@MainActor
final class ContextStore: ObservableObject {
    @Published var contexts: [WorkContext] = [] {
        didSet { persist() }
    }

    @Published var activeContextID: UUID? {
        didSet { persist() }
    }

    private var isLoading = true

    init() {
        load()
        isLoading = false
    }

    var activeContext: WorkContext? {
        guard let activeContextID else { return nil }
        return contexts.first { $0.id == activeContextID }
    }

    var unarchivedContexts: [WorkContext] {
        contexts.filter { !$0.isArchived }
    }

    var archivedContexts: [WorkContext] {
        contexts.filter(\.isArchived)
    }

    func addContext() {
        var context = WorkContext(
            focus: "新的上下文",
            details: [DetailItem()]
        )
        context.updatedAt = Date()
        contexts.append(context)
        activate(context.id)
    }

    func delete(_ id: UUID) {
        let deletingActiveContext = activeContextID == id
        contexts.removeAll { $0.id == id }
        if deletingActiveContext {
            activeContextID = contexts.first { !$0.isArchived }?.id
        }
    }

    func archive(_ id: UUID) {
        guard let index = contexts.firstIndex(where: { $0.id == id }) else { return }
        contexts[index].archivedAt = Date()
        contexts[index].updatedAt = Date()
        if activeContextID == id {
            activeContextID = contexts.first { !$0.isArchived }?.id
        }
    }

    func restore(_ id: UUID) {
        guard let index = contexts.firstIndex(where: { $0.id == id }) else { return }
        contexts[index].archivedAt = nil
        contexts[index].updatedAt = Date()
        activate(id)
    }

    func activate(_ id: UUID) {
        guard contexts.contains(where: { $0.id == id && !$0.isArchived }) else { return }
        activeContextID = id
    }

    func update(_ id: UUID, _ mutation: (inout WorkContext) -> Void) {
        guard let index = contexts.firstIndex(where: { $0.id == id }) else { return }
        mutation(&contexts[index])
        contexts[index].updatedAt = Date()

    }

    func toggleApp(_ app: AppReference, for id: UUID) {
        update(id) { context in
            if let index = context.workspace.applications.firstIndex(where: { $0.id == app.id }) {
                context.workspace.applications.remove(at: index)
            } else {
                context.workspace.applications.append(app)
            }
        }
    }

    func addDetail(to id: UUID) {
        update(id) { context in
            context.details.append(DetailItem())
        }
    }

    func removeDetail(_ detailID: UUID, from id: UUID) {
        update(id) { context in
            context.details.removeAll { $0.id == detailID }
        }
    }

    func detailBinding(for id: UUID, detailID: UUID) -> Binding<String> {
        Binding(
            get: { [weak self] in
                self?.contexts
                    .first(where: { $0.id == id })?
                    .details.first(where: { $0.id == detailID })?
                    .text ?? ""
            },
            set: { [weak self] value in
                self?.update(id) { context in
                    guard let index = context.details.firstIndex(where: { $0.id == detailID }) else { return }
                    context.details[index].text = value
                }
            }
        )
    }

    func binding<T>(for id: UUID, keyPath: WritableKeyPath<WorkContext, T>, fallback: T) -> Binding<T> {
        Binding(
            get: { [weak self] in
                self?.contexts.first(where: { $0.id == id })?[keyPath: keyPath] ?? fallback
            },
            set: { [weak self] value in
                self?.update(id) { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func load() {
        let document = RelayPersistence.shared.document
        guard !document.contexts.isEmpty else {
            let first = WorkContext(
                focus: "创建我的第一个上下文",
                details: [DetailItem(text: "记录并切换正在并行推进的目标")],
                workspace: WorkspaceContext(note: "Relay")
            )
            contexts = [first]
            activeContextID = first.id
            return
        }

        contexts = document.contexts
        if let savedID = document.activeContextID,
           contexts.contains(where: { $0.id == savedID && !$0.isArchived }) {
            activeContextID = savedID
        } else {
            activeContextID = contexts.first { !$0.isArchived }?.id
        }
    }

    private func persist() {
        guard !isLoading else { return }
        RelayPersistence.shared.saveContexts(contexts, activeContextID: activeContextID)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        configureMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        RelayPersistence.shared.flush()
    }

    private func configureMainWindow(attempt: Int = 0) {
        guard let window = NSApp.windows.first else {
            guard attempt < 20 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.configureMainWindow(attempt: attempt + 1)
            }
            return
        }

        window.title = "Relay — 人类上下文切换器"
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.setContentSize(NSSize(width: 400, height: 330))
        window.minSize = NSSize(width: 340, height: 280)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct LabeledEditor: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $text)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 36, maxHeight: 54)
            }
            .padding(2)
            .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator.opacity(0.5), lineWidth: 1)
            }
        }
    }
}

struct LabeledField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator.opacity(0.5), lineWidth: 1)
                }
        }
    }
}

struct ApplicationPill: View {
    let app: AppReference
    let selected: Bool
    let action: () -> Void

    private var foregroundColor: Color {
        selected ? .green : .secondary
    }

    private var fillColor: Color {
        selected ? Color.green.opacity(0.16) : Color.secondary.opacity(0.08)
    }

    private var borderColor: Color {
        selected ? Color.green.opacity(0.55) : Color.secondary.opacity(0.18)
    }

    var body: some View {
        Button(action: action) {
            Text(app.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(foregroundColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(fillColor))
                .overlay {
                    Capsule().stroke(borderColor, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .help(selected ? "取消关联 \(app.name)" : "关联 \(app.name)")
    }
}

struct ApplicationPickerMenu: View {
    @ObservedObject var store: ContextStore
    @ObservedObject var usageStore: ApplicationUsageStore
    let contextID: UUID
    let selectedIDs: Set<String>

    var body: some View {
        Menu {
            ForEach(usageStore.allSuggestions) { app in
                Button {
                    store.toggleApp(app.reference, for: contextID)
                } label: {
                    Text(selectedIDs.contains(app.id) ? "✓ \(app.name)" : app.name)
                }
            }
        } label: {
            Text("+ APP")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.08), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("从已安装软件中多选")
    }
}

struct AddressSelector: View {
    @ObservedObject var store: ContextStore
    @ObservedObject var usageStore: ApplicationUsageStore
    let contextID: UUID

    private var context: WorkContext? {
        store.contexts.first { $0.id == contextID }
    }

    private func isSelected(_ app: AppReference, in context: WorkContext) -> Bool {
        context.workspace.applications.contains { $0.id == app.id }
    }

    private func visibleApplications(for context: WorkContext) -> [AppReference] {
        var result = context.workspace.applications
        for app in usageStore.frequentSuggestions.prefix(8).map(\.reference)
            where !result.contains(where: { $0.id == app.id }) {
            result.append(app)
        }
        return Array(result.prefix(10))
    }

    var body: some View {
        if let context {
            VStack(alignment: .leading, spacing: 6) {
                Text("关联 APP")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(visibleApplications(for: context)) { app in
                            ApplicationPill(app: app, selected: isSelected(app, in: context)) {
                                store.toggleApp(app, for: contextID)
                            }
                        }

                        ApplicationPickerMenu(
                            store: store,
                            usageStore: usageStore,
                            contextID: contextID,
                            selectedIDs: Set(context.workspace.applications.map(\.id))
                        )
                    }
                }

                TextField(
                    "补充备注（可选）",
                    text: store.binding(for: contextID, keyPath: \.workspace.note, fallback: "")
                )
                .textFieldStyle(.plain)
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator.opacity(0.5), lineWidth: 1)
                }
            }
        }
    }
}

struct ContextTab: View {
    @ObservedObject var store: ContextStore
    let contextID: UUID
    @State private var showingDeleteConfirmation = false

    private var context: WorkContext? {
        store.contexts.first { $0.id == contextID }
    }

    private var isActive: Bool {
        store.activeContextID == contextID
    }

    var body: some View {
        if let context {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    store.activate(contextID)
                }
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(isActive ? Color.green : Color.secondary.opacity(0.45))
                        .frame(width: 7, height: 7)
                    Text(context.focus.isEmpty ? "未命名上下文" : context.focus)
                        .font(.subheadline.weight(isActive ? .semibold : .regular))
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .background(
                    isActive ? Color(nsColor: .controlBackgroundColor) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
            }
            .buttonStyle(.plain)
            .help("点击切换；右键归档或删除")
            .contextMenu {
                Button {
                    store.archive(contextID)
                } label: {
                    Label("归档", systemImage: "archivebox")
                }

                Divider()

                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
            .confirmationDialog("删除“\(context.focus)”？", isPresented: $showingDeleteConfirmation) {
                Button("删除", role: .destructive) {
                    store.delete(contextID)
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这个上下文的具体展开和关联 APP 也会被删除。")
            }
        }
    }
}

struct ContextPage: View {
    @ObservedObject var store: ContextStore
    @ObservedObject var usageStore: ApplicationUsageStore
    let contextID: UUID
    @State private var showingDeleteConfirmation = false

    private var context: WorkContext? {
        store.contexts.first { $0.id == contextID }
    }

    var body: some View {
        if let context {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledField(
                        label: "我在做什么",
                        placeholder: "一句话记住当前上下文",
                        text: store.binding(for: contextID, keyPath: \.focus, fallback: "")
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        Text("具体展开")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(context.details) { detail in
                            HStack(spacing: 6) {
                                TextField(
                                    "下一步、线索或待处理事项",
                                    text: store.detailBinding(for: contextID, detailID: detail.id)
                                )
                                .textFieldStyle(.plain)
                                .font(.callout)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 7)
                                .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(.separator.opacity(0.5), lineWidth: 1)
                                }

                                Button {
                                    store.removeDetail(detail.id, from: contextID)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("删除这一项")
                            }
                        }

                        Button {
                            store.addDetail(to: contextID)
                        } label: {
                            Label("添加一项", systemImage: "plus")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                    }

                    AddressSelector(store: store, usageStore: usageStore, contextID: contextID)

                    HStack {
                        Text("更新于 \(context.updatedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        Spacer()

                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(14)
            }
            .confirmationDialog("删除“\(context.focus)”？", isPresented: $showingDeleteConfirmation) {
                Button("删除", role: .destructive) {
                    store.delete(contextID)
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这个上下文的具体展开和关联 APP 也会被删除。")
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var store = ContextStore()
    @StateObject private var usageStore = ApplicationUsageStore()
    @State private var isCollapsed = false

    private var activeCount: Int {
        store.unarchivedContexts.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)

                Text("Relay")
                    .font(.subheadline.weight(.bold))

                Text("· 人类上下文切换器")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Label("\(activeCount)", systemImage: "square.stack.3d.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    setCollapsed(!isCollapsed)
                } label: {
                    Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .help(isCollapsed ? "展开窗口" : "收起窗口")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial)

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(store.unarchivedContexts) { context in
                        ContextTab(store: store, contextID: context.id)
                    }

                    Button {
                        store.addContext()
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .help("新建目标")

                    if !store.archivedContexts.isEmpty {
                        Menu {
                            ForEach(store.archivedContexts) { context in
                                Button {
                                    store.restore(context.id)
                                } label: {
                                    Label(context.focus, systemImage: "arrow.uturn.backward")
                                }
                            }
                        } label: {
                            Label("\(store.archivedContexts.count)", systemImage: "archivebox")
                                .frame(height: 28)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("恢复已归档目标")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(Color(nsColor: .windowBackgroundColor))

            if !isCollapsed {
                Divider()

                if store.unarchivedContexts.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "square.stack.3d.up.slash")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)
                        Text("还没有上下文")
                            .font(.headline)
                        Text("创建一个目标。等它卡住，再理直气壮地切走。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("创建目标") {
                            store.addContext()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(40)
                } else if let activeContextID = store.activeContextID {
                    ContextPage(store: store, usageStore: usageStore, contextID: activeContextID)
                } else if let firstContextID = store.unarchivedContexts.first?.id {
                    ContextPage(store: store, usageStore: usageStore, contextID: firstContextID)
                }

                Divider()

                HStack {
                    Text("AI 并行执行，人类无损切换。")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Label("窗口已置顶", systemImage: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial)
            }
        }
        .frame(
            minWidth: 340,
            idealWidth: 400,
            minHeight: isCollapsed ? 70 : 280,
            idealHeight: isCollapsed ? 70 : 330
        )
    }

    private func setCollapsed(_ collapsed: Bool) {
        withAnimation(.easeInOut(duration: 0.18)) {
            isCollapsed = collapsed
        }

        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
            let targetHeight: CGFloat = collapsed ? 70 : 330
            window.minSize = NSSize(width: 340, height: collapsed ? 70 : 280)
            window.setContentSize(NSSize(width: max(window.frame.width, 400), height: targetHeight))
        }
    }
}

@main
struct RelayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
