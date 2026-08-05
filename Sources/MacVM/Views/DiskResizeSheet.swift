import MacVMHostKit
import SwiftUI

struct DiskResizeSheet: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        let vm = store.diskResizeSheetVMName.flatMap(store.vm(named:))

        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Grow Disk")
                    .font(.system(size: 20, weight: .semibold))
                Text(vm?.metadata.name ?? "Virtual machine")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Card {
                VStack(spacing: 0) {
                    InfoRow(
                        label: "Current capacity",
                        value: vm.map { VMText.gibLabel(for: $0.metadata.diskSizeBytes) } ?? "—"
                    )
                    Divider().overlay(Theme.hairline)
                    HStack(spacing: 12) {
                        Text("New capacity")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 120, alignment: .leading)
                        TextField(
                            "Capacity",
                            value: $store.diskResizeTargetGiB,
                            format: .number.grouping(.never)
                        )
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 92)
                        .accessibilityLabel("New disk capacity in GiB")
                        Text("GiB")
                            .font(.system(size: 12))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Enter a whole-GiB capacity larger than the current disk. Shrinking is not supported.")
                Text("The VM must remain stopped while MacVM relocates RecoveryOS and grows its APFS container. This operation cannot be cancelled after it starts.")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if !store.canSubmitDiskResize {
                Text("The new capacity must be a whole-GiB value larger than the current capacity and within the supported size.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemRed))
            }

            CLICommandStrip(command: store.diskResizeCommandPreview)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    store.diskResizeSheetVMName = nil
                }
                .keyboardShortcut(.cancelAction)

                Button("Grow Disk") {
                    store.submitDiskResize()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!store.canSubmitDiskResize)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
