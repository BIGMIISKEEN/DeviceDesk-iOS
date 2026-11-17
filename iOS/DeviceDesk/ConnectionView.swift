import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject var model: AppModel
    @State private var address = ""
    @State private var token = ""
    var body: some View {
        Form {
            Section {
                Label("DeviceDesk for iPhone", systemImage: "iphone.gen3.radiowaves.left.and.right").font(.headline)
                Text("Connect to the Windows bridge on your company network or VPN. Windows administration runs on the bridge, not on the iPhone.").foregroundStyle(.secondary)
            }
            Section("Bridge connection") {
                TextField("https://devicedesk.company.example:9443", text: $address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("bridgeURL")
                SecureField("Access token (blank uses saved token)", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save & connect") { let supplied = token; token = ""; Task { await model.connect(address: address, enteredToken: supplied) } }
                    .disabled(model.busy || address.isEmpty)
                Text("Tokens are stored in this iPhone's Keychain. HTTPS certificate validation stays enabled. Ask your administrator for the bridge address and your access token.").font(.caption).foregroundStyle(.secondary)
            }
            if let cap = model.capabilities {
                Section("Connected operator") {
                    ValueRow(name: "Operator", value: cap.operator)
                    ValueRow(name: "Allowed computers", value: cap.targets.joined(separator: "\n"))
                    ValueRow(name: "Permitted actions", value: cap.actions.joined(separator: ", "))
                }
            }
            Section {
                Button("Disconnect") { model.disconnect() }.disabled(model.busy)
                Button("Forget saved access token", role: .destructive) { model.forgetToken() }.disabled(model.busy)
            }
            Section("Preview the interface") {
                Button("Open demo data") { model.loadDemo(); model.selectedPage = .overview }.disabled(model.busy || model.pending != nil)
                Text("Demo mode uses clearly marked sample data and cannot perform remote actions.").font(.caption).foregroundStyle(.secondary)
            }
        }.onAppear { address = model.endpoint }.onDisappear { token = "" }
    }
}
