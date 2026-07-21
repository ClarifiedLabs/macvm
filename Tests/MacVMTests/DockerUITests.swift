import Foundation
import MacVMHostKit
import Testing
@testable import MacVM

@Test
func createCommandRendersDockerResourcesAndSetupImplication() {
    let defaults = VMCreationDraft(
        name: "",
        cpuCount: 6,
        memoryGiB: 8,
        diskGiB: 80,
        displayWidth: 1280,
        displayHeight: 720,
        restoreMode: .latestSupported,
        createBootstrapShare: true
    )
    var draft = defaults
    draft.name = "docker-dev"
    draft.dockerEnabled = true
    draft.dockerCPUCount = 4
    draft.dockerMemoryGiB = 8
    draft.dockerDiskGiB = 128
    draft.dockerAMD64Enabled = false

    #expect(
        CLIEquivalent.create(draft, defaults: defaults, setupAfter: true)
            == "macvm create --name docker-dev --setup --docker --docker-cpu 4 --docker-memory-gi-b 8 --docker-disk-gi-b 128 --no-docker-amd64"
    )
}

@Test
func dockerSidecarStatusIsCodableForCLIAndUIRefresh() throws {
    let value = DockerSidecarStatus(
        state: .degraded,
        fcosVersion: "44.20260621.3.1",
        cpuCount: 2,
        memorySizeBytes: 4 * 1024 * 1024 * 1024,
        dataDiskSizeBytes: 64 * 1024 * 1024 * 1024,
        amd64Requested: true,
        amd64Available: false,
        lastError: "test"
    )
    let decoded = try JSONDecoder().decode(DockerSidecarStatus.self, from: JSONEncoder().encode(value))
    #expect(decoded == value)
}

@Test
func dockerResourceFormSynchronizesWhenSidecarAppearsAfterSetup() {
    var values = DockerResourceFormValues(settings: nil)
    #expect(values.cpuCount == DockerSidecarSettings.defaultCPUCount)
    #expect(values.memoryGiB == DockerSidecarSettings.defaultMemoryGiB)
    #expect(values.diskGiB == DockerSidecarSettings.defaultDiskGiB)

    values.synchronize(with: DockerSidecarSettings(
        amd64Enabled: false,
        cpuCount: 6,
        memorySizeBytes: 12 * 1024 * 1024 * 1024,
        dataDiskSizeBytes: 96 * 1024 * 1024 * 1024,
        macOSMACAddress: "02:00:00:00:00:01",
        linuxPrivateMACAddress: "02:00:00:00:00:02",
        linuxNATMACAddress: "02:00:00:00:00:03"
    ))

    #expect(values.cpuCount == 6)
    #expect(values.memoryGiB == 12)
    #expect(values.diskGiB == 96)
    #expect(!values.amd64Enabled)
}
