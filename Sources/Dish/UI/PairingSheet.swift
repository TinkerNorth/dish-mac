import SwiftUI

/// PIN-entry sheet shown when the server requires (re-)pairing. Mirrors
/// `dialog_pairing.xml` on Android. The empty PIN is accepted by the server
/// for previously-paired devices — we pad it to `0000` in that case to match
/// the Android default.
struct PairingSheet: View {

    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let server: DiscoveredServer

    @State private var pin: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pair with \(server.name.isEmpty ? server.ip : server.name)")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(DishTheme.onSurface)
            Text("Enter the PIN shown on the Satellite server.")
                .font(.system(size: 12))
                .foregroundColor(DishTheme.muted)

            TextField("PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14, design: .monospaced))

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(DishOutlinedButtonStyle())
                Button("Connect") {
                    let effective = pin.isEmpty ? "0000" : pin
                    model.pairWithPin(server, pin: effective)
                    dismiss()
                }
                .buttonStyle(DishOutlinedButtonStyle())
            }
        }
        .padding(20)
        .frame(minWidth: 340)
        .background(DishTheme.background)
    }
}
