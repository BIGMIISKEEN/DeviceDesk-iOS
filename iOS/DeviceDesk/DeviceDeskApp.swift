import SwiftUI

@main @MainActor struct DeviceDeskApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environment(\.locale, Locale(identifier: "en"))
                .tint(.blue)
                .overlay {
                    if scenePhase != .active {
                        ZStack {
                            Color(uiColor: .systemBackground).ignoresSafeArea()
                            Label("DeviceDesk", systemImage: "lock.shield.fill").font(.title2.bold())
                        }
                    }
                }
        }
    }
}
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var clearPending = false
    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedPage) {
                Section {
                    Label("DeviceDesk", systemImage: "desktopcomputer.and.arrow.down").font(.title2.bold()).padding(.vertical, 12)
                    Text("YOUR SUPPORT WORKSPACE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Section {
                    ForEach(Page.allCases) { page in
                        NavigationLink(value: page) { Label(page.rawValue, systemImage: page.symbol).padding(.vertical, 5) }
                    }
                }
                if model.demo { Label("Demo data", systemImage: "eye").foregroundStyle(.orange) }
            }
            .navigationTitle("DeviceDesk")
            .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 320)
        } detail: {
            Group {
                switch model.selectedPage ?? .overview {
                case .overview: OverviewView()
                case .devices: DevicesView()
                case .directory: DirectoryView()
                case .actions: ActionsView()
                case .connection: ConnectionView()
                }
            }
            .navigationTitle((model.selectedPage ?? .overview).rawValue)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    if model.busy { ProgressView().controlSize(.small).accessibilityLabel("Operation running") }
                    Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if model.pending != nil && !model.busy {
                        ViewThatFits(in: .horizontal) {
                            HStack { pendingButtons }
                            VStack(alignment: .leading) { pendingButtons }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12).background(.regularMaterial)
            }
        }
        .alert("DeviceDesk", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
        .confirmationDialog("Clear the pending operation reference?", isPresented: $clearPending, titleVisibility: .visible) {
            Button("I checked the target; clear reference", role: .destructive) { model.persistPending(nil) }
        } message: { Text("This does not cancel the operation. It may still be running or may already have completed. Check the target before submitting another change.") }
    }
    @ViewBuilder private var pendingButtons: some View {
        Button("Check pending operation") { Task { await model.resume() } }.disabled(!model.connected)
        Button("Clear reference", role: .destructive) { clearPending = true }
    }
}
struct TargetPicker: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if model.demo { Label(model.target, systemImage: "desktopcomputer").font(.headline) }
        else if let caps = model.capabilities {
            Picker("Computer", selection: Binding(get: { model.target }, set: { model.changeTarget($0) })) {
                ForEach(caps.targets, id: \.self) { Text($0).tag($0) }
            }.disabled(model.busy || model.pending != nil)
        } else { Label("Connect to your Windows bridge first.", systemImage: "network.slash").foregroundStyle(.secondary) }
    }
}
struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    let sections = ["Network", "Programs", "Drivers", "Disks", "Volumes", "Processes", "SCCM", "Errors"]
    var body: some View {
        List {
            Section {
                TargetPicker()
                Button { Task { await model.run("Inventory") } } label: { Label("Scan computer", systemImage: "arrow.clockwise") }
                    .disabled(!model.permits("Inventory"))
                if let date = model.collectedAt { Text("Collected \(date.formatted())").font(.caption).foregroundStyle(.secondary) }
            }
            Section("Overview") {
                if model.inventory["Summary"].rows.isEmpty { ContentUnavailableView("No inventory yet", systemImage: "desktopcomputer", description: Text("Choose an allowed computer and run a scan.")) }
                ForEach(Array(model.inventory["Summary"].rows.enumerated()), id: \.offset) { _, row in
                    ValueRow(name: row["Item"].text, value: row["Value"].text)
                }
            }
            Section("Inventory details") {
                ForEach(sections, id: \.self) { section in
                    NavigationLink {
                        DataRowsView(title: section, rows: model.inventory[section].rows)
                    } label: { HStack { Text(section); Spacer(); Text("\(model.inventory[section].rows.count)").foregroundStyle(.secondary) } }
                }
            }
        }
    }
}
struct ValueRow: View {
    let name: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "Unavailable" : value).font(.body).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
    }
}
struct DataRowsView: View {
    let title: String
    let rows: [JSONValue]
    @State private var search = ""
    var filtered: [JSONValue] { search.isEmpty ? rows : rows.filter { $0.text.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        List {
            if rows.isEmpty { ContentUnavailableView("No results", systemImage: "tray", description: Text("Run a scan or check Scan notes for unavailable data.")) }
            ForEach(Array(filtered.enumerated()), id: \.offset) { _, row in
                NavigationLink { RecordView(row: row).navigationTitle(title) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(recordName(row)).font(.headline)
                        Text(recordSubtitle(row)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }.padding(.vertical, 5)
                }
            }
        }.navigationTitle(title).searchable(text: $search, prompt: "Filter results")
    }
}
func recordName(_ row: JSONValue) -> String {
    for key in ["Device", "DeviceName", "DisplayName", "Name", "Title", "Model", "Item", "Drive", "Id"] {
        if !row[key].text.isEmpty { return row[key].text }
    }
    return "Record"
}
func recordSubtitle(_ row: JSONValue) -> String {
    for key in ["UpdateStatus", "Value", "DriverVersion", "Version", "SamAccountName", "IP", "Description", "Status"] {
        if !row[key].text.isEmpty { return row[key].text }
    }
    return "View details"
}
struct RecordView: View {
    let row: JSONValue
    var body: some View {
        List { ForEach(row.fields, id: \.0) { key, value in ValueRow(name: key, value: value.text) } }
    }
}
struct DevicesView: View {
    @EnvironmentObject var model: AppModel
    @State private var filter = ""
    var rows: [JSONValue] { model.driverReport == .null ? model.inventory["Connected"].rows : model.driverReport["Devices"].rows }
    var body: some View {
        List {
            Section {
                TargetPicker()
                Button { Task { await model.run("DriverUpdates") } } label: { Label("Check driver updates", systemImage: "arrow.down.circle") }.disabled(!model.permits("DriverUpdates"))
                Text("Checks the Windows Update source configured on the selected PC. No offer does not guarantee the latest vendor release.").font(.caption).foregroundStyle(.secondary)
            }
            if model.driverReport != .null {
                Section("Update check") {
                    Text(model.driverReport["Note"].text).font(.callout)
                    NavigationLink("All offered updates (\(model.driverReport["Updates"].rows.count))") { DataRowsView(title: "Offered updates", rows: model.driverReport["Updates"].rows) }
                }
            }
            Section("Present hardware") {
                if rows.isEmpty { ContentUnavailableView("No devices loaded", systemImage: "cpu", description: Text("Scan a computer or check its driver updates.")) }
                ForEach(Array(rows.filter { filter.isEmpty || $0.text.localizedCaseInsensitiveContains(filter) }.enumerated()), id: \.offset) { _, row in
                    NavigationLink { DeviceDetail(row: row) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(recordName(row), systemImage: "cpu").font(.headline)
                            Text(row["DriverVersion"].text.isEmpty ? "Driver version unavailable" : "Installed: \(row["DriverVersion"].text)").font(.subheadline).foregroundStyle(.secondary)
                            Text(row["UpdateStatus"].text).font(.caption.weight(.medium)).foregroundStyle(row["UpdateStatus"].text == "Update offered" ? Color.blue : Color.secondary)
                        }.padding(.vertical, 5)
                    }
                }
            }
        }.searchable(text: $filter, prompt: "Find a device")
    }
}
struct DeviceDetail: View {
    let row: JSONValue
    let hosts: Set<String> = ["www.dell.com", "support.hp.com", "pcsupport.lenovo.com", "www.intel.com", "www.nvidia.com", "www.amd.com", "www.asus.com", "www.logitech.com"]
    func supportURL(_ key: String) -> URL? {
        guard let url = URL(string: row[key].text), url.scheme == "https", let host = url.host, hosts.contains(host), url.user == nil, url.password == nil else { return nil }; return url
    }
    var body: some View {
        List {
            Section("Official download sources") {
                if let url = supportURL("DeviceSupportURL") { Link("Device manufacturer support", destination: url) }
                if let url = supportURL("ComputerSupportURL") { Link("Computer manufacturer support", destination: url) }
                Text("Select the exact model and Windows version. These links open support pages; DeviceDesk does not install drivers.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Device details") { ForEach(row.fields, id: \.0) { key, value in ValueRow(name: key, value: value.text) } }
        }.navigationTitle("Device details")
    }
}
