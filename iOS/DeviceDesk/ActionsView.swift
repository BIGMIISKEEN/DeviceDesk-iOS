import SwiftUI

struct ActionsView: View {
    @EnvironmentObject var model: AppModel
    @State private var title = "IT Support"
    @State private var bodyText = ""
    @State private var send = false
    @State private var restart = false
    @State private var clean = false
    var preview: JSONValue { model.cleanupPreview }
    var body: some View {
        Form {
            Section { TargetPicker() }
            Section("Popup message") {
                TextField("Title", text: $title)
                TextField("Message to active signed-in users", text: $bodyText, axis: .vertical).lineLimit(3...8)
                Text("The popup appears on the selected Windows computer for up to 60 seconds. Submission does not confirm it was read.").font(.caption).foregroundStyle(.secondary)
                Button("Send popup message") { send = true }
                    .disabled(!model.permits("PopupMessage") || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 100 || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bodyText.count > 2000)
            }
            Section("Temporary files") {
                Button("Preview temp cleanup") { Task { await model.run("TempPreview") } }.disabled(!model.permits("TempPreview"))
                if preview != .null {
                    ValueRow(name: "Eligible files", value: preview["FileCount"].text)
                    ValueRow(name: "Total bytes", value: preview["Bytes"].text)
                    ValueRow(name: "Preview expiry (UTC)", value: preview["ExpiresUtc"].text)
                    Button("Delete previewed files", role: .destructive) { clean = true }.disabled(!model.permits("TempDelete") || preview["FileCount"].text == "0")
                    Button("Discard preview") { Task { await model.run("TempDiscard", payload: ["PreviewId": preview["PreviewId"], "Hash": preview["Hash"]]) } }.disabled(!model.permits("TempDiscard") || preview["FileCount"].text == "0")
                }
                Text("Windows Temp and the bridge execution account's Temp folder only; files older than seven days. Changed, locked or linked files are skipped.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Power") {
                Button("Restart computer", role: .destructive) { restart = true }.disabled(!model.permits("Restart"))
            }
            Section("Application memory") {
                NavigationLink("Select a scanned process to trim") { ProcessActionsView() }
                Text("Requires a current inventory scan. Trimming is temporary and does not increase installed RAM.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Send this message to \(model.target)?", isPresented: $send, titleVisibility: .visible) {
            Button("Send message") { let payload: [String: JSONValue] = ["Title": .string(title), "Message": .string(bodyText), "Seconds": .integer(60)]; Task { await model.run("PopupMessage", payload: payload, confirmed: true) } }
        } message: { Text(title + "\n" + bodyText) }
        .confirmationDialog("Restart \(model.target) now?", isPresented: $restart, titleVisibility: .visible) {
            Button("Restart computer", role: .destructive) { Task { await model.run("Restart", confirmed: true) } }
        } message: { Text("Save open work first. This will interrupt the user's session.") }
        .confirmationDialog("Delete \(preview["FileCount"].text) previewed temporary files on \(model.target)?", isPresented: $clean, titleVisibility: .visible) {
            Button("Delete previewed files", role: .destructive) { Task { await model.run("TempDelete", payload: ["PreviewId": preview["PreviewId"], "Hash": preview["Hash"]], confirmed: true) } }
        } message: { Text("Only unchanged files from this unexpired preview are eligible. This cannot be undone.") }
    }
}
struct ProcessActionsView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: JSONValue?
    var body: some View {
        List {
            Text("Computer: \(model.target)").font(.headline)
            if model.inventory["Processes"].rows.isEmpty { Text("Run an inventory scan first.").foregroundStyle(.secondary) }
            ForEach(Array(model.inventory["Processes"].rows.enumerated()), id: \.offset) { _, row in
                Button { selected = row } label: {
                    VStack(alignment: .leading) { Text(row["Name"].text); Text("PID \(row["Id"].text) · \(row["MemoryMB"].text) MB").font(.caption).foregroundStyle(.secondary) }
                }.disabled(!model.permits("Trim") || row["Session"].text == "0")
            }
        }.navigationTitle("Trim application RAM")
            .confirmationDialog("Trim \(selected?["Name"].text ?? "application") on \(model.target)?", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible) {
                Button("Trim working set") {
                    guard let row = selected else { return }
                    selected = nil
                    Task { await model.run("Trim", payload: ["Id": .string(row["Id"].text), "StartTicks": .string(row["StartTicks"].text)], confirmed: true) }
                }
            } message: { Text("This may temporarily slow the application. Memory can return as it is needed.") }
    }
}
