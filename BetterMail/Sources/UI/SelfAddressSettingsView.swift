import SwiftUI

struct SelfAddressSettingsView: View {
    @ObservedObject var store: SelfAddressStore
    @State private var newAddress: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ignored Addresses")
                .font(.title2.weight(.semibold))
            Text("BetterMail ignores these addresses when checking participant overlap, so newsletters or BCC fragments that only match you won't merge unintentionally.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Add email address", text: $newAddress)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addAddress)
                Button("Add") { addAddress() }
                    .disabled(newAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            List {
                if store.addresses.isEmpty {
                    Text("No addresses added yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.addresses, id: \.self) { address in
                        HStack {
                            Text(address)
                            Spacer()
                            Button(role: .destructive) {
                                store.removeAddress(address)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 360)
    }

    private func addAddress() {
        store.addAddress(newAddress)
        newAddress = ""
    }
}

#if DEBUG
struct SelfAddressSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        let defaults = UserDefaults(suiteName: "SelfAddressSettingsViewPreview")!
        defaults.removePersistentDomain(forName: "SelfAddressSettingsViewPreview")
        let store = SelfAddressStore(defaults: defaults)
        store.updateAddresses(["me@example.com", "another@example.com"])
        return SelfAddressSettingsView(store: store)
    }
}
#endif
