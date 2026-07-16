import AppKit
import MacVMHostKit
import SwiftUI

struct MacVMSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var rootPath = MacVMSettings.shared.effectiveVMRootDirectory.path
    @State private var savedPath = MacVMSettings.shared.effectiveVMRootDirectory.path

    var body: some View {
        Form {
            Section("Virtual Machines") {
                TextField("VM root", text: $rootPath)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Choose…") {
                        chooseDirectory()
                    }
                    Button("Use Default") {
                        rootPath = MacVMSettings.defaultVMRootDirectory.path
                        MacVMSettings.shared.setVMRootDirectory(nil)
                        savedPath = MacVMSettings.shared.effectiveVMRootDirectory.path
                    }
                    Spacer()
                    Button("Save") {
                        save()
                    }
                    .buttonStyle(.borderedProminent)
                }

                Text("The app and bundled CLI use this directory unless a command passes --root.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if savedPath != store.service.rootDirectory.path {
                    Text("Quit and reopen MacVM to use this directory in the Manager.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = MacVMSettings.directoryURL(forPath: rootPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        rootPath = url.path
        save()
    }

    private func save() {
        let url = MacVMSettings.directoryURL(forPath: rootPath)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            MacVMSettings.shared.setVMRootDirectory(url)
            rootPath = url.path
            savedPath = url.path
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}
