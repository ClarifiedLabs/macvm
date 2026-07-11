import SwiftUI

struct CloneVMSheet: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        let sourceName = store.cloneSheetSourceName ?? ""

        VStack(alignment: .leading, spacing: 16) {
            Text("Clone Virtual Machine")
                .font(.system(size: 15, weight: .semibold))

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 12) {
                GridRow {
                    Text("Source:")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(sourceName)
                }
                GridRow {
                    Text("Name:")
                        .foregroundStyle(.secondary)
                    TextField("dev-copy", text: $store.cloneName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Text("CPU, memory, disk capacity, display, shared files, accounts, tools, and guest identity are inherited. The clone receives a new macvm identity and MAC address, and launch on boot remains disabled.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("The source must remain stopped. Apple Account services may require reauthentication when both copies are used.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("$ \(store.cloneCommandPreview)")
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.cliBarBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))

            HStack {
                Spacer()
                Button("Cancel") {
                    store.cloneSheetSourceName = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Clone") {
                    store.submitClone()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(store.cloneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}
