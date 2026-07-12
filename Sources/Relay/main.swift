import AppKit
import SwiftUI

enum ContextStatus: String, Codable, CaseIterable, Identifiable {
    case active = "正在执行"
    case waiting = "等待中"
    case blocked = "已阻塞"
    case ready = "可恢复"
    case done = "已完成"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .active: return "play.fill"
        case .waiting: return "clock.fill"
        case .blocked: return "exclamationmark.triangle.fill"
        case .ready: return "arrow.clockwise"
        case .done: return "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .active: return .green
        case .waiting: return .orange
        case .blocked: return .red
        case .ready: return .blue
        case .done: return .secondary
        }
    }
}

struct AppReference: Identifiable, Codable, Equatable, Hashable {
    var id: String { bundleIdentifier.isEmpty ? path : bundleIdentifier }
    var bundleIdentifier: String
    var name: String
    var path: String
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

    private let storageKey = "relay.appUsage.v1"

    override init() {
        super.init()
        load()
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

    func activate(_ app: AppReference) {
        if let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == app.bundleIdentifier
        }) {
            runningApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            return
        }

        let url = URL(fileURLWithPath: app.path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.openApplication(
            at: url,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, _ in }
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

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([TrackedApp].self, from: data) else {
            return
        }
        apps = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(apps) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

struct WorkContext: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var content: String
    var address: String
    var apps: [AppReference]
    var status: ContextStatus
    var archived: Bool
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title, content, address, apps, status, archived, updatedAt
    }

    init(
        id: UUID = UUID(),
        title: String,
        content: String = "",
        address: String = "",
        apps: [AppReference] = [],
        status: ContextStatus,
        archived: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.address = address
        self.apps = apps
        self.status = status
        self.archived = archived
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        address = try container.decodeIfPresent(String.self, forKey: .address) ?? ""
        apps = try container.decodeIfPresent([AppReference].self, forKey: .apps) ?? []
        status = try container.decodeIfPresent(ContextStatus.self, forKey: .status) ?? .ready
        archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
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

    private struct Snapshot: Codable {
        var contexts: [WorkContext]
        var activeContextID: UUID?
    }

    private let storageKey = "relay.contexts.v1"
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
        contexts.filter { !$0.archived }
    }

    var archivedContexts: [WorkContext] {
        contexts.filter(\.archived)
    }

    func addContext() {
        var context = WorkContext(
            title: "新的目标",
            content: "",
            address: "",
            status: contexts.isEmpty ? .active : .ready
        )
        context.updatedAt = Date()
        contexts.insert(context, at: 0)
        activate(context.id)
    }

    func delete(_ id: UUID) {
        let deletingActiveContext = activeContextID == id
        contexts.removeAll { $0.id == id }
        if deletingActiveContext {
            activeContextID = contexts.first { !$0.archived }?.id
        }
    }

    func archive(_ id: UUID) {
        guard let index = contexts.firstIndex(where: { $0.id == id }) else { return }
        contexts[index].archived = true
        contexts[index].updatedAt = Date()
        if activeContextID == id {
            activeContextID = contexts.first { !$0.archived }?.id
        }
    }

    func restore(_ id: UUID) {
        guard let index = contexts.firstIndex(where: { $0.id == id }) else { return }
        contexts[index].archived = false
        contexts[index].updatedAt = Date()
        activate(id)
    }

    func activate(_ id: UUID) {
        guard let targetIndex = contexts.firstIndex(where: { $0.id == id }) else { return }

        if let activeContextID,
           activeContextID != id,
           let previousIndex = contexts.firstIndex(where: { $0.id == activeContextID }),
           contexts[previousIndex].status == .active {
            contexts[previousIndex].status = .ready
            contexts[previousIndex].updatedAt = Date()
        }

        contexts[targetIndex].status = .active
        contexts[targetIndex].updatedAt = Date()
        activeContextID = id
    }

    func update(_ id: UUID, _ mutation: (inout WorkContext) -> Void) {
        guard let index = contexts.firstIndex(where: { $0.id == id }) else { return }
        mutation(&contexts[index])
        contexts[index].updatedAt = Date()

    }

    func toggleApp(_ app: AppReference, for id: UUID) {
        update(id) { context in
            if let index = context.apps.firstIndex(where: { $0.id == app.id }) {
                context.apps.remove(at: index)
            } else {
                context.apps.append(app)
            }
        }
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
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            let first = WorkContext(
                title: "创建我的第一个上下文",
                content: "记录并切换正在并行推进的目标",
                address: "Relay",
                status: .active
            )
            contexts = [first]
            activeContextID = first.id
            return
        }

        contexts = snapshot.contexts
        activeContextID = snapshot.activeContextID
    }

    private func persist() {
        guard !isLoading else { return }
        let snapshot = Snapshot(contexts: contexts, activeContextID: activeContextID)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
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

struct StatusBadge: View {
    let status: ContextStatus

    var body: some View {
        Label(status.rawValue, systemImage: status.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(status.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(status.color.opacity(0.12), in: Capsule())
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

struct AddressSelector: View {
    @ObservedObject var store: ContextStore
    @ObservedObject var usageStore: ApplicationUsageStore
    let contextID: UUID

    private var context: WorkContext? {
        store.contexts.first { $0.id == contextID }
    }

    var body: some View {
        if let context {
            VStack(alignment: .leading, spacing: 6) {
                Text("地址")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    if !context.apps.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 5) {
                                ForEach(context.apps) { app in
                                    HStack(spacing: 3) {
                                        Button(app.name) {
                                            usageStore.activate(app)
                                        }
                                        .buttonStyle(.plain)
                                        .help("打开 \(app.name)")

                                        Button {
                                            store.toggleApp(app, for: contextID)
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.caption2)
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.secondary)
                                        .help("从这个目标移除")
                                    }
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(Color.accentColor.opacity(0.1), in: Capsule())
                                }
                            }
                        }
                    }

                    Menu {
                        if usageStore.frequentSuggestions.isEmpty {
                            Text("切换软件后，常用项会出现在这里")
                        } else {
                            Section("最近 / 常用") {
                                ForEach(Array(usageStore.frequentSuggestions.prefix(8))) { app in
                                    let selected = context.apps.contains { $0.id == app.id }
                                    Button {
                                        store.toggleApp(app.reference, for: contextID)
                                    } label: {
                                        Text(selected ? "✓ \(app.name)" : app.name)
                                    }
                                }
                            }
                        }

                        Divider()

                        Menu("全部软件") {
                            ForEach(usageStore.allSuggestions) { app in
                                let selected = context.apps.contains { $0.id == app.id }
                                Button {
                                    store.toggleApp(app.reference, for: contextID)
                                } label: {
                                    Text(selected ? "✓ \(app.name)" : app.name)
                                }
                            }
                        }
                    } label: {
                        Text(context.apps.isEmpty ? "选择软件" : "+ 软件")
                            .font(.caption.weight(.medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("从最近和最常切换的软件中多选")
                }

                TextField(
                    "补充目录或网址（可选）",
                    text: store.binding(for: contextID, keyPath: \.address, fallback: "")
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
                        .fill(context.status.color)
                        .frame(width: 7, height: 7)
                    Text(context.title.isEmpty ? "未命名目标" : context.title)
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
            .confirmationDialog("删除“\(context.title)”？", isPresented: $showingDeleteConfirmation) {
                Button("删除", role: .destructive) {
                    store.delete(contextID)
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这个目标保存的内容和地址也会被删除。")
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
                    HStack(alignment: .bottom, spacing: 12) {
                        LabeledField(
                            label: "标题",
                            placeholder: "这个目标叫什么",
                            text: store.binding(for: contextID, keyPath: \.title, fallback: "")
                        )

                        StatusBadge(status: context.status)
                            .padding(.bottom, 4)
                    }

                    LabeledEditor(
                        label: "内容",
                        placeholder: "我要做什么",
                        text: store.binding(for: contextID, keyPath: \.content, fallback: "")
                    )

                    AddressSelector(store: store, usageStore: usageStore, contextID: contextID)

                    HStack {
                        Picker(
                            "状态",
                            selection: store.binding(for: contextID, keyPath: \.status, fallback: .ready)
                        ) {
                            ForEach(ContextStatus.allCases) { status in
                                Label(status.rawValue, systemImage: status.symbol).tag(status)
                            }
                        }
                        .frame(maxWidth: 190)

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
            .confirmationDialog("删除“\(context.title)”？", isPresented: $showingDeleteConfirmation) {
                Button("删除", role: .destructive) {
                    store.delete(contextID)
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这个目标保存的内容和地址也会被删除。")
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var store = ContextStore()
    @StateObject private var usageStore = ApplicationUsageStore()
    @State private var isCollapsed = false

    private var activeCount: Int {
        store.unarchivedContexts.filter { $0.status != .done }.count
    }

    private var blockedCount: Int {
        store.unarchivedContexts.filter { $0.status == .blocked || $0.status == .waiting }.count
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

                if blockedCount > 0 {
                    Label("\(blockedCount)", systemImage: "pause.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

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
                                    Label(context.title, systemImage: "arrow.uturn.backward")
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
