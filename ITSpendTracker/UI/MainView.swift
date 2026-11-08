import SwiftUI

enum Route: Hashable {
    case services
    case history
    case tags
    case chat
    case service(UUID)
    case key(service: UUID, key: String)
    case addService
    case settings
}

/// The main window (REQ-001, REQ-014, DEC-029): a sidebar that always lists every section and service,
/// and the selected page on the right. Cached data shows immediately; refresh runs in the background (REQ-009).
struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Route? = .services
    @State private var pickingInvoice = false
    @State private var invoiceFile: InvoiceFile?

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection, onAddInvoice: { pickingInvoice = true })
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(\.isLargeLayout, true)
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        .invoicePicker(isPresented: $pickingInvoice, file: $invoiceFile)
        // A PDF dropped anywhere on the window starts the import; the service is matched by vendor name (DEC-046).
        .dropDestination(for: URL.self) { urls, _ in
            guard let pdf = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { return false }
            invoiceFile = InvoiceFile(url: pdf)
            return true
        }
        .sheet(item: $invoiceFile) { file in InvoiceImportSheet(file: file.url, preselected: nil) }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .services {
        case .services: OverviewView(selection: $selection)
        case .history: HistoryView()
        case .tags: TagsView(selection: $selection)
        case .chat: ChatView()
        case .service(let id): ServiceDetailView(serviceID: id, selection: $selection).id(id)
        case .key(let service, let key): KeyDetailView(serviceID: service, keyID: key, selection: $selection).id("\(service)|\(key)")
        case .addService: AddServiceView(selection: $selection)
        case .settings: SettingsView()
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Route?
    var onAddInvoice: () -> Void = {}

    var body: some View {
        let month = model.today.calendarMonth
        List(selection: $selection) {
            Section {
                Label("Services", systemImage: "square.grid.2x2").tag(Route.services)
                Label("History", systemImage: "chart.bar").tag(Route.history)
                Label("Tags", systemImage: "tag").tag(Route.tags)
                Label("Chat", systemImage: "bubble.left.and.text.bubble.right").tag(Route.chat)
            }
            Section("Services") {
                ForEach(model.summaries) { summary in
                    HStack(spacing: 4) {
                        Text(summary.name).lineLimit(1)
                        WarningBadges(summary: summary).imageScale(.small)
                        Spacer()
                        AmountText(amount: summary.currentMonthSpend, approximate: summary.isApproximate).font(.callout).foregroundStyle(.secondary)
                    }
                    .tag(Route.service(summary.id))
                }
                Label("Add service…", systemImage: "plus").tag(Route.addService)
                Button(action: onAddInvoice) { Label("Add invoice from PDF…", systemImage: "doc.badge.plus") }
                    .buttonStyle(.plain)
            }
            Section {
                Label("Settings", systemImage: "gearshape").tag(Route.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(Format.monthLong(month)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await model.refresh.refreshAll(onlyStale: false) }
                    } label: {
                        if model.refresh.isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                    .help(Text("Refresh"))
                    .accessibilityLabel(Text("Refresh"))
                    .disabled(model.refresh.isRefreshing)
                }
                AmountText(amount: model.total(in: month), approximate: model.totalIsApproximate(in: month))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("total of selected services").font(.caption).foregroundStyle(.secondary)
                if let error = model.startupError {
                    Label(error, systemImage: "exclamationmark.octagon").font(.caption).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .safeAreaInset(edge: .bottom) {
            Button("Quit IT Spend Tracker") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// All services with the include-in-total checkboxes (REQ-002).
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Route?

    var body: some View {
        let month = model.today.calendarMonth
        let summaries = model.summaries
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("IT spend").font(.title2.weight(.semibold))
                Text(Format.monthLong(month)).foregroundStyle(.secondary)
                Spacer()
                AmountText(amount: model.total(in: month), approximate: model.totalIsApproximate(in: month)).font(.system(size: 30, weight: .semibold, design: .rounded))
            }
            .padding(20)
            Divider()
            if summaries.isEmpty {
                ContentUnavailableView {
                    Label("No services yet", systemImage: "tray")
                } description: {
                    Text("Add a service with an API connection or a manual subscription.")
                } actions: {
                    Button("Add service") { selection = .addService }
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(summaries) { summary in
                        ServiceRow(summary: summary) { selection = .service(summary.id) }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

struct ServiceRow: View {
    @Environment(AppModel.self) private var model
    let summary: ServiceSummary
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { summary.includedInTotal },
                set: { included in
                    if let service = model.store.service(id: summary.id) {
                        try? model.store.setIncludedInTotal(service, included)
                    }
                })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(Text("Include in total"))
                .accessibilityLabel(Text("Include \(summary.name) in total"))
            Button(action: open) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(summary.name).font(.body.weight(.medium)).lineLimit(1)
                            WarningBadges(summary: summary)
                        }
                        statusLine
                    }
                    Spacer()
                    AmountText(amount: summary.currentMonthSpend, approximate: summary.isApproximate).font(.body.weight(.semibold))
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusLine: some View {
        if !summary.isConnected {
            Text("Manual entry").font(.caption).foregroundStyle(.secondary)
        } else if model.refresh.refreshing.contains(summary.id) {
            Text("Updating…").font(.caption).foregroundStyle(.secondary)
        } else if let last = summary.lastSuccessfulRefresh {
            Text("Updated \(Format.relative(last))").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Not updated yet").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Visible indicators for REQ-008 warnings and REQ-009 refresh errors.
struct WarningBadges: View {
    let summary: ServiceSummary

    var body: some View {
        if !summary.expiringKeys.isEmpty {
            Image(systemName: "key.fill").foregroundStyle(.orange)
                .help(Text("Keys expiring within 14 days: \(summary.expiringKeys.joined(separator: ", "))"))
                .accessibilityLabel(Text("Key expiring soon"))
        }
        if let increase = summary.increase {
            Image(systemName: "arrow.up.right.circle.fill").foregroundStyle(.orange)
                .help(Text("Spend is up: \(Format.usd(increase.monthToDate)) vs \(Format.usd(increase.previousSamePeriod)) in the same days of last month"))
                .accessibilityLabel(Text("Spend increased"))
        }
        if let error = summary.refreshError {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                .help(Text("Last update failed: \(error)"))
                .accessibilityLabel(Text("Update failed"))
        }
    }
}
