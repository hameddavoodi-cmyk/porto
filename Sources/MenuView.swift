import SwiftUI
import AppKit
import ServiceManagement

struct MenuView: View {
    @ObservedObject var monitor: ServiceMonitor
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 340)
        .onAppear {
            // Fresh data the instant the menu opens, not up to 3 s later.
            monitor.refresh()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func setLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let a = NSAlert()
            a.messageText = enable ? "Couldn't enable Launch at Login" : "Couldn't disable Launch at Login"
            a.informativeText = error.localizedDescription
            a.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func requestKill(_ svc: Service) {
        monitor.killService(svc)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
                .foregroundStyle(.secondary)
            Text("Porto")
                .font(.system(.headline, design: .rounded))
            Spacer()
            Button {
                monitor.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("Quit")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var content: some View {
        if monitor.services.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "moon.zzz")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text("No listening services")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(groupedCategories, id: \.0) { (cat, items) in
                        Section(header: CategoryHeader(category: cat, count: items.count)) {
                            ForEach(items) { svc in
                                ServiceRow(service: svc) { requestKill(svc) }
                                Divider().opacity(0.2)
                            }
                        }
                    }
                }
            }
            .frame(height: estimatedHeight)
        }
    }

    private var groupedCategories: [(ServiceCategory, [Service])] {
        let grouped = Dictionary(grouping: monitor.services, by: category(for:))
        return ServiceCategory.allCases.compactMap { cat in
            guard let items = grouped[cat], !items.isEmpty else { return nil }
            return (cat, items)
        }
    }

    private var estimatedHeight: CGFloat {
        let rows = CGFloat(monitor.services.count) * 38
        let headers = CGFloat(groupedCategories.count) * 26
        return min(rows + headers + 4, 680)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                Toggle("Launch at Login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings")

            if let date = monitor.lastRefresh {
                Text("Updated \(date.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text("\(monitor.services.count) service\(monitor.services.count == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct CategoryHeader: View {
    let category: ServiceCategory
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(category.rawValue.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            Spacer()
            Text("\(count)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.background.opacity(0.92))
    }

    private var iconName: String {
        switch category {
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .node:   return "shippingbox"
        case .docker: return "shippingbox.fill"
        case .other:  return "circle.grid.2x2"
        case .system: return "gearshape"
        }
    }

    private var tint: Color {
        switch category {
        case .python: return .blue
        case .node:   return .green
        case .docker: return .cyan
        case .other:  return .purple
        case .system: return .gray
        }
    }
}

struct ServiceRow: View {
    let service: Service
    let onKill: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Text(service.port == 0 ? "—" : String(service.port))
                .font(.system(.body, design: .monospaced))
                .frame(width: 56, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(service.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(idText)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if service.address == "0.0.0.0" {
                Image(systemName: "globe")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("Listening on all interfaces — reachable from the network")
            }

            Button(action: onKill) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(hover ? Color.red : Color.red.opacity(0.55))
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .help(service.kind == .docker ? "Stop container" : "Kill process")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(hover ? Color.primary.opacity(0.06) : Color.clear)
        .onHover { hover = $0 }
        .onTapGesture { openInBrowser() }
        .contextMenu {
            if service.port > 0 {
                Button("Open in Browser") { openInBrowser() }
                Button("Copy URL") { copy("http://localhost:\(service.port)") }
                Button("Copy Port") { copy(String(service.port)) }
            }
            if let pid = service.pid {
                Button("Copy PID") { copy(String(pid)) }
            }
            if let id = service.containerId {
                Button("Copy Container ID") { copy(id) }
            }
            Divider()
            Button(service.kind == .docker ? "Stop Container" : "Kill Process", action: onKill)
        }
    }

    private func openInBrowser() {
        guard service.port > 0, let u = URL(string: "http://localhost:\(service.port)") else { return }
        NSWorkspace.shared.open(u)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private var idText: String {
        if let pid = service.pid { return "pid \(pid)" }
        if let id = service.containerId { return String(id.prefix(8)) }
        return ""
    }
}
