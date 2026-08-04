import SwiftUI
import Virtualization

struct CloneVMSheet: View {
    private static let bytesPerGiB: UInt64 = 1024 * 1024 * 1024

    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        let sourceName = store.cloneSheetSourceName ?? ""
        let sourceMetadata = store.vm(named: sourceName)?.metadata
        let sourceCPUCount = sourceMetadata?.cpuCount ?? Self.minimumCPUCount
        let sourceMemoryGiB = sourceMetadata.map {
            max(1, Int(($0.memorySizeBytes + Self.bytesPerGiB - 1) / Self.bytesPerGiB))
        } ?? Self.minimumMemoryGiB

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
                GridRow {
                    Text("CPU:")
                        .foregroundStyle(.secondary)
                    ResourceValueField(
                        label: "CPU count",
                        value: cpuCountBinding(sourceCPUCount: sourceCPUCount),
                        unit: "cores"
                    )
                }
                GridRow {
                    Text("Memory:")
                        .foregroundStyle(.secondary)
                    ResourceValueField(
                        label: "Memory",
                        value: memoryGiBBinding(sourceMemoryGiB: sourceMemoryGiB),
                        unit: "GiB"
                    )
                }
            }

            Text("CPU and memory inherit the source values unless changed above. Disk capacity, display, shared files, accounts, tools, and guest identity are inherited. The clone receives a new macvm identity and MAC address, and launch on boot remains disabled.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("The source must remain stopped. Apple Account services may require reauthentication when both copies are used.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            CLICommandStrip(command: store.cloneCommandPreview)

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

    private static var minimumCPUCount: Int {
        Int(VZVirtualMachineConfiguration.minimumAllowedCPUCount)
    }

    private static var minimumMemoryGiB: Int {
        let minimumBytes = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        return max(1, Int((minimumBytes + bytesPerGiB - 1) / bytesPerGiB))
    }

    private func cpuCountBinding(sourceCPUCount: Int) -> Binding<Int> {
        Binding(
            get: { store.cloneCPUCountOverride ?? sourceCPUCount },
            set: { value in
                store.cloneCPUCountOverride = value == sourceCPUCount ? nil : value
            }
        )
    }

    private func memoryGiBBinding(sourceMemoryGiB: Int) -> Binding<Int> {
        Binding(
            get: { store.cloneMemoryGiBOverride ?? sourceMemoryGiB },
            set: { value in
                store.cloneMemoryGiBOverride = value == sourceMemoryGiB ? nil : value
            }
        )
    }
}
