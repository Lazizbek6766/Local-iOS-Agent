import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var controller: AgentController
    @State private var showConfiguration = false
    @State private var showDependencyCenter = false
    @State private var showGitChanges = false
    @State private var sessionPendingDeletion: AgentSession?
    @FocusState private var composerIsFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 280, ideal: 312, max: 360)
        } detail: {
            mainContent
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.indigo)
        .toolbar { toolbarContent }
        .task {
            await controller.initialize()
        }
        .sheet(isPresented: $showConfiguration) {
            ConfigurationView(controller: controller)
        }
        .sheet(isPresented: $showDependencyCenter) {
            DependencyCenterView(controller: controller)
        }
        .sheet(isPresented: $showGitChanges) {
            GitChangesView(controller: controller)
        }
        .alert(
            "Sessiyani o‘chirish?",
            isPresented: Binding(
                get: { sessionPendingDeletion != nil },
                set: { if !$0 { sessionPendingDeletion = nil } }
            )
        ) {
            Button("Bekor qilish", role: .cancel) {
                sessionPendingDeletion = nil
            }
            Button("O‘chirish", role: .destructive) {
                guard let sessionPendingDeletion else { return }
                controller.deleteSession(sessionPendingDeletion.id)
                self.sessionPendingDeletion = nil
            }
        } message: {
            Text("Lokal chat tarixi o‘chadi. OpenCode’ning o‘z sessiyasi o‘chirilmaydi.")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                controller.startOllama()
            } label: {
                Label("Ollama’ni ochish", systemImage: "bolt.horizontal.circle")
            }

            Button {
                Task { await controller.refreshHealth() }
            } label: {
                Label("Holatni yangilash", systemImage: "arrow.clockwise")
            }
            .help("Lokal komponentlarni qayta tekshirish")

            Button {
                showDependencyCenter = true
            } label: {
                Label("Dependency Center", systemImage: "stethoscope")
            }
            .help("Dependency va loyiha diagnostikasini ochish")

            Button {
                showGitChanges = true
            } label: {
                Label(
                    controller.gitChangeCount == 0
                        ? "O‘zgarishlar"
                        : "O‘zgarishlar (\(controller.gitChangeCount))",
                    systemImage: "doc.text.magnifyingglass"
                )
            }
            .disabled(controller.projectURL == nil)
            .help("Git o‘zgarishlari va diff’ni ko‘rish")

            Button {
                controller.openInXcode()
            } label: {
                Label("Xcode’da ochish", systemImage: "hammer")
            }
            .disabled(controller.projectURL == nil)

            Button(role: .destructive) {
                controller.stopCurrentTask()
            } label: {
                Label(
                    controller.isStopping ? "To‘xtatilmoqda" : "To‘xtatish",
                    systemImage: "stop.fill"
                )
            }
            .disabled(!controller.isRunning || controller.isStopping)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            brand
                .padding(.horizontal, 18)
                .padding(.vertical, 16)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    projectCard
                    sessionsSection
                    quickActionsSection
                    componentStatusCard
                }
                .padding(14)
            }

            Divider()

            Button {
                showConfiguration = true
            } label: {
                Label("Model va sozlamalar", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
        }
        .background(.regularMaterial)
    }

    private var brand: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.indigo, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)
                    .shadow(color: .indigo.opacity(0.22), radius: 7, y: 3)
                Image(systemName: "apple.terminal")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Local iOS Agent")
                    .font(.headline)
                Text("Terminalsiz · Mac ichida")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var projectCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionEyebrow(title: "AKTIV LOYIHA", symbol: "folder")

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: controller.projectURL == nil ? "folder.badge.questionmark" : "folder.fill")
                    .font(.title3)
                    .foregroundStyle(controller.projectURL == nil ? Color.orange : Color.blue)

                VStack(alignment: .leading, spacing: 3) {
                    Text(controller.projectName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let projectURL = controller.projectURL {
                        Text(projectURL.deletingLastPathComponent().path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("Agent ishlashi uchun papka kerak")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            Button {
                controller.chooseProject()
            } label: {
                Label(
                    controller.projectURL == nil ? "Loyiha tanlash" : "Almashtirish",
                    systemImage: "folder.badge.plus"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(controller.isRunning)

            if controller.projectURL != nil {
                Button {
                    showDependencyCenter = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: controller.projectPreflight.status.symbol)
                            .foregroundStyle(controller.projectPreflight.status.color)
                        Text(controller.projectPreflight.summary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.caption2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Loyiha preflight tafsilotlari")

                Button {
                    showGitChanges = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(controller.agentGitChangeCount > 0 ? Color.indigo : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("O‘zgarishlar")
                                .font(.caption.weight(.semibold))
                            Text(controller.gitStatusMessage)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if controller.isRefreshingGitChanges {
                            ProgressView()
                                .controlSize(.mini)
                        } else if controller.gitChangeCount > 0 {
                            Text("\(controller.gitChangeCount)")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.indigo.opacity(0.12), in: Capsule())
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Git o‘zgarishlari va diff’ni ko‘rish")
            }
        }
        .padding(13)
        .cardBackground()
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionEyebrow(title: "SESSIYALAR", symbol: "bubble.left.and.bubble.right")
                Spacer()
                Button {
                    controller.createNewSession()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .disabled(controller.isRunning)
                .help("Yangi sessiya")
            }

            if controller.isLoadingSessions {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Sessiyalar yuklanmoqda…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
            } else {
                ForEach(controller.orderedSessions) { session in
                    SessionRow(
                        session: session,
                        isSelected: session.id == controller.activeSessionID
                    ) {
                        controller.selectSession(session.id)
                    }
                    .disabled(controller.isRunning && session.id != controller.activeSessionID)
                    .contextMenu {
                        Button("O‘chirish", role: .destructive) {
                            sessionPendingDeletion = session
                        }
                        .disabled(controller.isRunning)
                    }
                }
            }
        }
    }

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionEyebrow(title: "TEZKOR AMALLAR", symbol: "bolt")

            ForEach(QuickAction.allCases) { action in
                Button {
                    controller.execute(action: action)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: action.symbol)
                            .foregroundStyle(.indigo)
                            .frame(width: 20)
                        Text(action.title)
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                .disabled(!controller.canRunQuickAction)
            }
        }
    }

    private var componentStatusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionEyebrow(title: "LOKAL MUHIT", symbol: "waveform.path.ecg")
                Spacer()
                if controller.environmentIssueCount == 0 {
                    Text("Tayyor")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                } else {
                    Text("\(controller.environmentIssueCount) muammo")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Button("Batafsil") {
                    showDependencyCenter = true
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
            }

            StatusRow(name: "Ollama", state: controller.ollamaState)
            StatusRow(name: "OpenCode", state: controller.openCodeState)
            StatusRow(name: "XcodeBuildMCP", state: controller.xcodeBuildMCPState)
        }
        .padding(13)
        .cardBackground()
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            sessionHeader
            Divider()

            if controller.projectURL == nil {
                projectEmptyState
            } else {
                conversation
            }

            Divider()
            composer
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.28))
    }

    private var sessionHeader: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(controller.activeSessionTitle)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 7) {
                    if controller.isRunning {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                    }
                    Text(controller.currentActivity?.title ?? controller.runSummary)
                        .font(.caption)
                        .foregroundStyle(controller.isRunning ? .indigo : .secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Label(controller.modelName, systemImage: "cpu")
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.thinMaterial, in: Capsule())

                Label(
                    controller.activeOpenCodeSessionID == nil ? "Yangi kontekst" : "Kontekst saqlangan",
                    systemImage: controller.activeOpenCodeSessionID == nil ? "link.badge.plus" : "link.circle.fill"
                )
                .font(.caption2)
                .foregroundStyle(
                    controller.activeOpenCodeSessionID == nil ? Color.secondary : Color.green
                )
                .help(controller.activeOpenCodeSessionID ?? "Birinchi javobda OpenCode sessiyasi bog‘lanadi")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
        .background(.bar)
    }

    private var statusColor: Color {
        if controller.lastError != nil { return .red }
        if controller.isEnvironmentReady { return .green }
        return .orange
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    if !controller.messages.contains(where: { $0.role == .user }) {
                        ConversationWelcome(controller: controller)
                    }

                    ForEach(controller.messages) { message in
                        if message.role == .system {
                            SystemNotice(message: message)
                                .id(message.id)
                        } else {
                            ChatBubble(message: message)
                                .id(message.id)
                        }
                    }

                    if let activity = controller.currentActivity, controller.isRunning {
                        ActivityPill(activity: activity)
                            .id("active-agent-activity")
                    }
                }
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 26)
                .padding(.vertical, 24)
            }
            .onChange(of: controller.messagesRevision) { _, _ in
                scrollToBottom(using: proxy)
            }
            .onChange(of: controller.currentActivity) { _, _ in
                guard controller.isRunning else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("active-agent-activity", anchor: .bottom)
                }
            }
        }
    }

    private func scrollToBottom(using proxy: ScrollViewProxy) {
        guard let last = controller.messages.last else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private var projectEmptyState: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(.indigo.opacity(0.1))
                    .frame(width: 100, height: 100)
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(.indigo)
            }

            VStack(spacing: 8) {
                Text("iOS loyihangizni ulang")
                    .font(.title2.weight(.semibold))
                Text("Agent loyiha ichida ishlaydi, AGENTS.md ko‘rsatmalarini o‘qiydi va barcha amallarni shu oynada ko‘rsatadi.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            Button("Loyiha tanlash…") {
                controller.chooseProject()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack(spacing: 18) {
                BenefitLabel(symbol: "lock.shield", text: "Lokal model")
                BenefitLabel(symbol: "terminal", text: "Terminal kerak emas")
                BenefitLabel(symbol: "clock.arrow.circlepath", text: "Sessiya saqlanadi")
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let lastError = controller.lastError {
                ErrorBanner(
                    message: lastError,
                    details: controller.technicalDetails,
                    dismiss: controller.dismissError
                )
            } else if controller.projectURL != nil, !controller.isEnvironmentReady {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Yuborishdan oldin \(controller.environmentIssueCount) ta lokal komponentni tayyorlang.")
                        .font(.caption)
                    Spacer()
                    Button("Diagnostika") {
                        showDependencyCenter = true
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
            }

            HStack(alignment: .bottom, spacing: 12) {
                TextEditor(text: $controller.taskDraft)
                    .font(.body)
                    .focused($composerIsFocused)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 50, maxHeight: 126)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .stroke(
                                composerIsFocused ? Color.indigo.opacity(0.65) : Color.primary.opacity(0.12),
                                lineWidth: composerIsFocused ? 1.5 : 1
                            )
                    )
                    .overlay(alignment: .topLeading) {
                        if controller.taskDraft.isEmpty {
                            Text("Vazifani yozing… Masalan: build xatosini top va tuzat")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Agent vazifasi")

                Button {
                    controller.submitDraft()
                    composerIsFocused = true
                } label: {
                    Image(systemName: controller.isRunning ? "ellipsis" : "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!controller.canSubmit)
                .help("Yuborish (⌘↩)")
            }

            HStack {
                Label("Fayllar o‘zgarishi mumkin — Git holatini kuzating", systemImage: "arrow.triangle.branch")
                Spacer()
                Text("Yuborish: ⌘↩")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.regularMaterial)
    }
}

private extension AgentController {
    var canRunQuickAction: Bool {
        projectURL != nil && isEnvironmentReady && !isRunning
    }
}

private struct SectionEyebrow: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
    }
}

private struct SessionRow: View {
    let session: AgentSession
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: session.openCodeSessionID == nil ? "bubble.left" : "link.circle.fill")
                    .foregroundStyle(isSelected ? Color.indigo : Color.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(session.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Loyihasiz")
                            .lineLimit(1)
                        Text("·")
                        Text(session.updatedAt, style: .time)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? Color.indigo.opacity(0.12) : Color.primary.opacity(0.001),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isSelected ? Color.indigo.opacity(0.2) : .clear, lineWidth: 1)
        }
        .accessibilityLabel("Sessiya: \(session.title)")
    }
}

private struct StatusRow: View {
    let name: String
    let state: ComponentState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.symbol)
                .foregroundStyle(state.color)
                .frame(width: 16)
            Text(name)
                .font(.caption)
            Spacer()
            Text(state.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help("\(name): \(state.title)")
    }
}

private struct ConversationWelcome: View {
    let controller: AgentController

    var body: some View {
        VStack(spacing: 17) {
            ZStack {
                Circle()
                    .fill(.indigo.opacity(0.1))
                    .frame(width: 66, height: 66)
                Image(systemName: "sparkles")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(.indigo)
            }

            VStack(spacing: 6) {
                Text("Nimadan boshlaymiz?")
                    .font(.title3.weight(.semibold))
                Text("Tezkor amalni tanlang yoki pastda o‘z vazifangizni yozing.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(QuickAction.allCases) { action in
                    Button {
                        controller.execute(action: action)
                    } label: {
                        Label(action.title, systemImage: action.symbol)
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .buttonStyle(.plain)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                    .disabled(!controller.canRunQuickAction)
                }
            }
            .frame(maxWidth: 570)
        }
        .padding(.vertical, 30)
    }
}

private struct SystemNotice: View {
    let message: ChatMessage

    var body: some View {
        Label(message.content, systemImage: "info.circle.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.thinMaterial, in: Capsule())
            .frame(maxWidth: .infinity)
    }
}

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .user {
                Spacer(minLength: 90)
            } else {
                avatar
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(roleTitle)
                        .font(.caption.weight(.semibold))
                    Text(message.createdAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if !message.content.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.content, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.mini)
                        .help("Nusxalash")
                    }
                }
                .foregroundStyle(.secondary)

                Group {
                    if message.content.isEmpty {
                        HStack(spacing: 9) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Agent javob tayyorlayapti…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(renderedContent)
                            .textSelection(.enabled)
                            .lineSpacing(3)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(bubbleColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(message.role == .user ? 0.02 : 0.08), lineWidth: 1)
                }
            }
            .frame(maxWidth: 760, alignment: message.role == .user ? .trailing : .leading)

            if message.role == .user {
                avatar
            } else {
                Spacer(minLength: 50)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var renderedContent: AttributedString {
        (try? AttributedString(
            markdown: message.content,
            options: .init(interpretedSyntax: .full)
        )) ?? AttributedString(message.content)
    }

    private var roleTitle: String {
        message.role == .user ? "Siz" : "Lokal agent"
    }

    private var avatar: some View {
        Image(systemName: message.role == .user ? "person.fill" : "cpu.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(message.role == .user ? Color.indigo : Color.blue)
            .frame(width: 32, height: 32)
            .background(
                (message.role == .user ? Color.indigo : Color.blue).opacity(0.12),
                in: Circle()
            )
    }

    private var bubbleColor: Color {
        message.role == .user
            ? .indigo.opacity(0.12)
            : Color(nsColor: .controlBackgroundColor)
    }
}

private struct ActivityPill: View {
    let activity: AgentActivity

    var body: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
            Image(systemName: activity.symbol)
                .foregroundStyle(.indigo)
            Text(activity.title)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 42)
    }
}

private struct ErrorBanner: View {
    let message: String
    let details: String?
    let dismiss: () -> Void
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption.weight(.medium))
                    .textSelection(.enabled)
                Spacer()
                if details != nil {
                    Button(showsDetails ? "Yopish" : "Tafsilot") {
                        showsDetails.toggle()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Xatoni yopish")
            }

            if showsDetails, let details {
                Text(details)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.red.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct BenefitLabel: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct GitChangesView: View {
    @Bindable var controller: AgentController
    @Environment(\.dismiss) private var dismiss
    @State private var selectedChangeID: GitFileChange.ID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 1_040)
        .frame(minHeight: 700)
        .task {
            await controller.refreshGitChanges()
            selectFirstChangeIfNeeded()
        }
        .task(id: selectedChangeID) {
            await controller.loadGitDiff(for: selectedChangeID)
        }
        .onChange(of: controller.gitChangeReport) { _, _ in
            selectFirstChangeIfNeeded()
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("O‘zgarishlar")
                    .font(.title2.weight(.semibold))
                Text(controller.gitStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let report = controller.gitChangeReport, !report.changes.isEmpty {
                GitSummaryPill(
                    title: "Agent",
                    value: report.agentChangeCount,
                    color: .indigo
                )
                GitSummaryPill(
                    title: "Oldindan",
                    value: report.preExistingChangeCount,
                    color: .orange
                )
                GitLineSummary(
                    additions: report.totalAdditions,
                    deletions: report.totalDeletions
                )
            }

            Button {
                Task { await controller.refreshGitChanges() }
            } label: {
                Label(
                    controller.isRefreshingGitChanges ? "Tekshirilmoqda" : "Yangilash",
                    systemImage: "arrow.clockwise"
                )
            }
            .buttonStyle(.bordered)
            .disabled(controller.isRefreshingGitChanges)

            Button {
                dismiss()
            } label: {
                Label("Yopish", systemImage: "xmark")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        if controller.isRefreshingGitChanges, controller.gitChangeReport == nil {
            GitPanelStateView(
                symbol: "arrow.trianglehead.2.clockwise.rotate.90",
                title: "Git holati tekshirilmoqda",
                detail: "Fayllar va qatorlar statistikasi tayyorlanmoqda.",
                showsProgress: true
            )
        } else if let report = controller.gitChangeReport {
            if report.changes.isEmpty {
                GitPanelStateView(
                    symbol: "checkmark.circle.fill",
                    title: "O‘zgarish yo‘q",
                    detail: "Repository ishchi daraxti toza.",
                    color: .green
                )
            } else {
                HSplitView {
                    changeList(report)
                        .frame(minWidth: 300, idealWidth: 340, maxWidth: 410)
                    diffPanel(report)
                        .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            GitPanelStateView(
                symbol: "arrow.triangle.branch",
                title: "Git ma’lumoti mavjud emas",
                detail: controller.gitStatusMessage,
                color: .orange
            )
        }
    }

    private func changeList(_ report: GitChangeReport) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("FAYLLAR")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(report.changes.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Divider()

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(report.changes) { change in
                        Button {
                            selectedChangeID = change.id
                        } label: {
                            GitChangeRow(
                                change: change,
                                isSelected: selectedChangeID == change.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    @ViewBuilder
    private func diffPanel(_ report: GitChangeReport) -> some View {
        if let change = selectedChange(in: report) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: change.kind.symbol)
                        .foregroundStyle(change.kind.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(change.path)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let previousPath = change.previousPath {
                            Text("Oldingi yo‘l: \(previousPath)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer()
                    Button {
                        controller.openGitChangeInXcode(change.id)
                    } label: {
                        Label("Xcode", systemImage: "hammer")
                    }
                    .disabled(change.kind == .deleted)

                    Button {
                        controller.revealGitChangeInFinder(change.id)
                    } label: {
                        Label("Finder", systemImage: "folder")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                Group {
                    if controller.isLoadingGitDiff {
                        GitPanelStateView(
                            symbol: "doc.text.magnifyingglass",
                            title: "Diff tayyorlanmoqda",
                            detail: change.path,
                            showsProgress: true
                        )
                    } else if let error = controller.gitDiffError {
                        GitPanelStateView(
                            symbol: "exclamationmark.triangle.fill",
                            title: "Diff’ni ko‘rsatib bo‘lmadi",
                            detail: error,
                            color: .red
                        )
                    } else if let diff = controller.selectedGitDiff,
                              diff.path == change.path {
                        VStack(spacing: 0) {
                            if diff.isBinary {
                                Label("Binary fayl — matn qatorlari mavjud emas", systemImage: "doc.badge.ellipsis")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 9)
                                Divider()
                            }
                            ScrollView([.horizontal, .vertical]) {
                                Text(diff.content)
                                    .font(.system(size: 12, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: true, vertical: true)
                                    .padding(16)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(Color(nsColor: .textBackgroundColor))
                        }
                    } else {
                        GitPanelStateView(
                            symbol: "doc.text",
                            title: "Faylni tanlang",
                            detail: "Tanlangan fayl diff’i shu yerda ko‘rsatiladi."
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            GitPanelStateView(
                symbol: "doc.text",
                title: "Faylni tanlang",
                detail: "Chap tomondagi ro‘yxatdan o‘zgarishni tanlang."
            )
        }
    }

    private func selectedChange(in report: GitChangeReport) -> GitFileChange? {
        guard let selectedChangeID else { return nil }
        return report.changes.first(where: { $0.id == selectedChangeID })
    }

    private func selectFirstChangeIfNeeded() {
        guard let changes = controller.gitChangeReport?.changes, !changes.isEmpty else {
            selectedChangeID = nil
            return
        }
        if let selectedChangeID,
           changes.contains(where: { $0.id == selectedChangeID }) {
            return
        }
        selectedChangeID = changes[0].id
    }
}

private struct GitChangeRow: View {
    let change: GitFileChange
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(change.kind.shortTitle)
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(change.kind.color)
                .frame(width: 24, height: 24)
                .background(change.kind.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 5) {
                Text((change.path as NSString).lastPathComponent)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                let parentPath = (change.path as NSString).deletingLastPathComponent
                if !parentPath.isEmpty {
                    Text(parentPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 7) {
                    Label(change.origin.title, systemImage: change.origin.symbol)
                        .foregroundStyle(change.origin.color)
                    if change.statistics.isBinary {
                        Text("Binary")
                    } else {
                        Text("+\(change.statistics.additions ?? 0)")
                            .foregroundStyle(.green)
                        Text("−\(change.statistics.deletions ?? 0)")
                            .foregroundStyle(.red)
                    }
                }
                .font(.caption2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            isSelected ? Color.indigo.opacity(0.13) : Color.primary.opacity(0.001),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isSelected ? Color.indigo.opacity(0.22) : .clear, lineWidth: 1)
        }
    }
}

private struct GitSummaryPill: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            Text("\(value)")
                .fontWeight(.bold)
        }
        .font(.caption2)
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.opacity(0.11), in: Capsule())
    }
}

private struct GitLineSummary: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("+\(additions)")
                .foregroundStyle(.green)
            Text("−\(deletions)")
                .foregroundStyle(.red)
        }
        .font(.caption2.monospacedDigit().weight(.semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
    }
}

private struct GitPanelStateView: View {
    let symbol: String
    let title: String
    let detail: String
    var color: Color = .secondary
    var showsProgress = false

    var body: some View {
        VStack(spacing: 14) {
            if showsProgress {
                ProgressView()
                    .controlSize(.large)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(color)
            }
            Text(title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct DependencyCenterView: View {
    @Bindable var controller: AgentController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    overview

                    ForEach(controller.dependencyDiagnostics) { diagnostic in
                        DependencyDiagnosticCard(diagnostic: diagnostic)
                    }

                    ProjectPreflightCard(
                        preflight: controller.projectPreflight,
                        bootstrapReport: controller.projectBootstrapReport
                    )
                }
                .padding(22)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 760)
        .frame(minHeight: 680)
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Dependency Center")
                    .font(.title2.weight(.semibold))
                Text("Lokal muhit va loyiha tayyorgarligi")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await controller.refreshHealth() }
            } label: {
                Label(
                    controller.isRefreshingDiagnostics ? "Tekshirilmoqda" : "Qayta tekshirish",
                    systemImage: "arrow.clockwise"
                )
            }
            .buttonStyle(.bordered)
            .disabled(controller.isRefreshingDiagnostics)

            Button {
                dismiss()
            } label: {
                Label("Yopish", systemImage: "xmark")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.cancelAction)
            .accessibilityHint("Dependency Center dialogini yopadi")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 15)
        .background(.bar)
    }

    private var overview: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(overallColor.opacity(0.12))
                    .frame(width: 52, height: 52)
                Image(systemName: overallSymbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(overallColor)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(overallTitle)
                    .font(.title3.weight(.semibold))
                Text("Ollama modeli, OpenCode provider’i, XcodeBuildMCP va loyiha tuzilmasi bitta joyda tekshiriladi.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(17)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var overallTitle: String {
        if controller.isRefreshingDiagnostics { return "Lokal muhit tekshirilmoqda" }
        if controller.environmentIssueCount == 0 { return "Agent ishlashga tayyor" }
        return "\(controller.environmentIssueCount) ta bloklovchi muammo bor"
    }

    private var overallSymbol: String {
        if controller.isRefreshingDiagnostics { return "arrow.trianglehead.2.clockwise.rotate.90" }
        return controller.environmentIssueCount == 0
            ? "checkmark.shield.fill"
            : "exclamationmark.shield.fill"
    }

    private var overallColor: Color {
        if controller.isRefreshingDiagnostics { return .blue }
        return controller.environmentIssueCount == 0 ? .green : .orange
    }
}

private struct DependencyDiagnosticCard: View {
    let diagnostic: DependencyDiagnostic

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: diagnostic.status.symbol)
                    .font(.title3)
                    .foregroundStyle(diagnostic.status.color)
                    .frame(width: 25)

                VStack(alignment: .leading, spacing: 3) {
                    Text(diagnostic.id.title)
                        .font(.headline)
                    Text(diagnostic.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
                DiagnosticStatusBadge(
                    status: diagnostic.status,
                    blocksAgent: diagnostic.blocksAgent
                )
            }

            if !diagnostic.facts.isEmpty {
                DiagnosticFactsView(facts: diagnostic.facts)
            }

            if !diagnostic.remediation.isEmpty {
                Divider()
                RemediationView(steps: diagnostic.remediation)
            }

            if let technicalDetails = diagnostic.technicalDetails,
               !technicalDetails.isEmpty {
                DisclosureGroup("Texnik tafsilot") {
                    Text(technicalDetails)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 7)
                }
                .font(.caption.weight(.medium))
            }
        }
        .padding(16)
        .cardBackground()
    }
}

private struct ProjectPreflightCard: View {
    let preflight: ProjectPreflight
    let bootstrapReport: ProjectBootstrapReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: preflight.status.symbol)
                    .font(.title3)
                    .foregroundStyle(preflight.status.color)
                    .frame(width: 25)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Loyiha preflight")
                        .font(.headline)
                    Text(preflight.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let projectPath = preflight.projectPath {
                        Text(projectPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                DiagnosticStatusBadge(status: preflight.status, blocksAgent: false)
            }

            if !bootstrapReport.createdItems.isEmpty || !bootstrapReport.failures.isEmpty {
                ProjectBootstrapResultView(report: bootstrapReport)
            }

            if !preflight.artifacts.isEmpty {
                HStack(spacing: 7) {
                    ForEach(preflight.artifacts) { artifact in
                        Label(artifact.name, systemImage: artifact.kind.symbol)
                            .font(.caption2.monospaced())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.blue.opacity(0.08), in: Capsule())
                            .lineLimit(1)
                    }
                }
            }

            if !preflight.facts.isEmpty {
                DiagnosticFactsView(facts: preflight.facts)
            }

            if !preflight.remediation.isEmpty {
                Divider()
                RemediationView(steps: preflight.remediation)
            }

            if let details = preflight.technicalDetails, !details.isEmpty {
                DisclosureGroup("Texnik tafsilot") {
                    Text(details)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.top, 7)
                }
                .font(.caption.weight(.medium))
            }
        }
        .padding(16)
        .cardBackground()
    }
}

private struct ProjectBootstrapResultView: View {
    let report: ProjectBootstrapReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !report.createdItems.isEmpty {
                Label(
                    "Ilova avtomatik qo‘shdi: \(createdItemNames)",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            }

            ForEach(Array(report.failures.enumerated()), id: \.offset) { _, failure in
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .font(.caption.weight(.medium))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(
            (report.failures.isEmpty ? Color.green : Color.red).opacity(0.08),
            in: RoundedRectangle(cornerRadius: 9)
        )
    }

    private var createdItemNames: String {
        report.createdItems.map(\.title).joined(separator: ", ")
    }
}

private struct DiagnosticFactsView: View {
    let facts: [DiagnosticFact]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
            ForEach(facts) { fact in
                GridRow {
                    Text(fact.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(fact.value)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct RemediationView: View {
    let steps: [RemediationStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Tuzatish", systemImage: "wrench.adjustable")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)

            ForEach(steps) { step in
                VStack(alignment: .leading, spacing: 6) {
                    Text(step.instruction)
                        .font(.caption)

                    if let command = step.command {
                        HStack(spacing: 8) {
                            Text(command)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                            } label: {
                                Label("Nusxalash", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.mini)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
        }
    }
}

private struct DiagnosticStatusBadge: View {
    let status: DiagnosticStatus
    let blocksAgent: Bool

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(status.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(status.color.opacity(0.1), in: Capsule())
    }

    private var title: String {
        switch status {
        case .unknown: "Kutilmoqda"
        case .checking: "Tekshirilmoqda"
        case .ready: "Tayyor"
        case .attention: blocksAgent ? "Tuzatish kerak" : "Ogohlantirish"
        case .unavailable: "Topilmadi"
        case .failed: "Xato"
        }
    }
}

private struct ConfigurationView: View {
    @Bindable var controller: AgentController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Lokal agent sozlamalari")
                        .font(.title2.weight(.semibold))
                    Text("OpenCode va Ollama ulanishini shu yerdan boshqaring.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "slider.horizontal.3")
                    .font(.title2)
                    .foregroundStyle(.indigo)
            }

            Form {
                Section("Model") {
                    TextField("provider/model", text: $controller.modelName)
                        .textFieldStyle(.roundedBorder)

                    LabeledContent("Tavsiya") {
                        Text("ollama/qwen3.5-ios:9b-64k")
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                }

                Section("Lokal ishlash") {
                    LabeledContent("Ollama serveri") {
                        Text("127.0.0.1:11434")
                            .font(.body.monospaced())
                    }
                    LabeledContent("Sessiya tarixi") {
                        Text("Application Support ichida")
                    }
                    Text("Masofaviy model API kalitlari agent jarayoniga uzatilmaydi va OpenCode auto-share o‘chirilgan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Standart model") {
                    controller.modelName = "ollama/qwen3.5-ios:9b-64k"
                }
                Spacer()
                Button("Yopish") {
                    Task { await controller.refreshHealth() }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 580)
    }
}

private extension DiagnosticStatus {
    var symbol: String {
        switch self {
        case .unknown: "circle.dashed"
        case .checking: "arrow.trianglehead.2.clockwise.rotate.90"
        case .ready: "checkmark.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .unavailable: "minus.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .unknown: .secondary
        case .checking: .blue
        case .ready: .green
        case .attention: .orange
        case .unavailable: .orange
        case .failed: .red
        }
    }
}

private extension ProjectArtifactKind {
    var symbol: String {
        switch self {
        case .workspace: "square.stack.3d.up.fill"
        case .project: "hammer.fill"
        case .swiftPackage: "shippingbox.fill"
        }
    }
}

private extension GitFileChangeKind {
    var shortTitle: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        }
    }

    var symbol: String {
        switch self {
        case .added: "plus.circle.fill"
        case .modified: "pencil.circle.fill"
        case .deleted: "minus.circle.fill"
        case .renamed: "arrow.right.circle.fill"
        case .copied: "doc.on.doc.fill"
        }
    }

    var color: Color {
        switch self {
        case .added: .green
        case .modified: .blue
        case .deleted: .red
        case .renamed, .copied: .purple
        }
    }
}

private extension GitChangeOrigin {
    var title: String {
        switch self {
        case .preExisting: "Oldindan"
        case .agent: "Agent"
        case .agentModifiedPreExisting: "Agent + oldingi"
        }
    }

    var symbol: String {
        switch self {
        case .preExisting: "clock.arrow.circlepath"
        case .agent: "sparkles"
        case .agentModifiedPreExisting: "exclamationmark.arrow.triangle.2.circlepath"
        }
    }

    var color: Color {
        switch self {
        case .preExisting: .orange
        case .agent: .indigo
        case .agentModifiedPreExisting: .purple
        }
    }
}

private extension View {
    func cardBackground() -> some View {
        background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.035), radius: 3, y: 1)
        )
    }
}
