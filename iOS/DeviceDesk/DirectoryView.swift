import SwiftUI

struct DirectoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var kind = "Users"
    var body: some View {
        List {
            Section("Search your directory") {
                ValueRow(name: "Domain controller", value: model.capabilities?.directoryServer ?? "Not connected")
                Picker("Search for", selection: $kind) { Text("Users").tag("Users"); Text("Computers").tag("Computers") }.pickerStyle(.segmented)
                    .onChange(of: kind) { _, _ in model.directoryRows = [] }
                TextField("Name, account or computer", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Search Active Directory") { Task { await model.run("DirectorySearch", payload: ["Kind": .string(kind), "Query": .string(query)]) } }
                    .disabled(!model.permits("DirectorySearch") || query.trimmingCharacters(in: .whitespaces).count < 2 || query.count > 128)
            }
            Section("Results") {
                if model.directoryRows.isEmpty { Text("Search to load up to 200 matching accounts or computers.").foregroundStyle(.secondary) }
                ForEach(Array(model.directoryRows.enumerated()), id: \.offset) { _, row in
                    NavigationLink { DirectoryDetail(row: row) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(recordName(row), systemImage: row["Kind"].text == "User" ? "person.crop.circle" : "desktopcomputer").font(.headline)
                            Text(row["SamAccountName"].text).font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 5)
                    }
                }
            }
        }.disabled(model.busy)
    }
}
func directoryIdentity(_ row: JSONValue) -> [String: JSONValue] {
    ["ObjectGUID": row["ObjectGUID"], "DistinguishedName": row["DistinguishedName"], "SamAccountName": row["SamAccountName"]]
}
struct DirectoryDetail: View {
    @EnvironmentObject var model: AppModel
    let row: JSONValue
    @State private var unlock = false
    @State private var reset = false
    var body: some View {
        List {
            if row["Kind"].text == "User" {
                Section("Account actions") {
                    Button("Unlock user") { unlock = true }.disabled(!model.permits("DirectoryUnlock"))
                    Button("Reset password") { reset = true }.disabled(!model.permits("DirectoryResetPassword"))
                    Text("Changes use the bridge's delegated Windows identity. The account is rechecked before modification.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Directory record") { ForEach(row.fields, id: \.0) { key, value in ValueRow(name: key, value: value.text) } }
        }
        .navigationTitle(row["SamAccountName"].text)
        .confirmationDialog("Unlock \(row["SamAccountName"].text)?", isPresented: $unlock, titleVisibility: .visible) {
            Button("Unlock this user") { Task { await model.run("DirectoryUnlock", payload: directoryIdentity(row), confirmed: true) } }
        } message: { Text(row["DistinguishedName"].text) }
        .sheet(isPresented: $reset) { PasswordResetView(row: row) }
    }
}
struct PasswordResetView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let row: JSONValue
    @State private var password = ""
    @State private var confirm = ""
    @State private var mustChange = true
    @State private var showConfirmation = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Selected account") {
                    ValueRow(name: "Account", value: row["SamAccountName"].text)
                    ValueRow(name: "Domain controller", value: model.capabilities?.directoryServer ?? "")
                }
                Section("New password") {
                    SecureField("New password", text: $password).textContentType(.newPassword)
                    SecureField("Confirm password", text: $confirm).textContentType(.newPassword)
                    Toggle("Require change at next sign-in", isOn: $mustChange)
                }
                Button("Reset password", role: .destructive) { showConfirmation = true }
                    .disabled(password.isEmpty || password != confirm || password.count > 256 || !model.permits("DirectoryResetPassword"))
            }.navigationTitle("Reset password")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .confirmationDialog("Reset the password for \(row["SamAccountName"].text)?", isPresented: $showConfirmation, titleVisibility: .visible) {
                    Button("Reset this user's password", role: .destructive) {
                        var payload = directoryIdentity(row)
                        payload["Password"] = .string(password); payload["ChangeAtLogon"] = .bool(mustChange)
                        password = ""; confirm = ""; dismiss()
                        Task { await model.run("DirectoryResetPassword", payload: payload, confirmed: true) }
                    }
                }
        }.onDisappear { password = ""; confirm = "" }
    }
}
