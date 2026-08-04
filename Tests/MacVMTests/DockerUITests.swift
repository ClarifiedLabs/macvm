import Foundation
import MacVMHostKit
import Testing
@testable import MacVM

@Test
func createCommandRendersCustomDockerResourcesAndSetupImplication() {
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
    draft.dockerCPUCount = 3
    draft.dockerMemoryGiB = 5
    draft.dockerDiskGiB = 70
    draft.dockerAMD64Enabled = false

    #expect(
        CLIEquivalent.create(draft, defaults: defaults, setupAfter: true)
            == "macvm create --name docker-dev --setup --docker --docker-cpu 3 --docker-memory-gi-b 5 --docker-disk-gi-b 70 --no-docker-amd64"
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
func resourceEditFormLoadsGuestAndDockerValuesAndCanBeDiscarded() throws {
    let sidecar = DockerSidecarSettings(
        amd64Enabled: false,
        cpuCount: 6,
        memorySizeBytes: 12 * 1024 * 1024 * 1024,
        dataDiskSizeBytes: 96 * 1024 * 1024 * 1024,
        macOSMACAddress: "02:00:00:00:00:01",
        linuxPrivateMACAddress: "02:00:00:00:00:02",
        linuxNATMACAddress: "02:00:00:00:00:03"
    )
    let metadata = VMMetadata(
        name: "docker-dev",
        cpuCount: 8,
        memorySizeBytes: 16 * 1024 * 1024 * 1024,
        diskSizeBytes: 80 * 1024 * 1024 * 1024,
        displayWidth: 1280,
        displayHeight: 720,
        bootstrapShareEnabled: true,
        dockerSidecar: sidecar
    )

    let original = VMResourceFormValues(metadata: metadata)
    #expect(original.cpuCount == 8)
    #expect(original.memoryGiB == 16)
    let docker = try #require(original.docker)
    #expect(docker.cpuCount == 6)
    #expect(docker.memoryGiB == 12)
    #expect(docker.diskGiB == 96)
    #expect(!docker.amd64Enabled)

    var edited = original
    edited.cpuCount = 10
    edited.memoryGiB = 20
    edited.docker?.diskGiB = 128
    #expect(edited != original)

    let afterCancel = VMResourceFormValues(metadata: metadata)
    #expect(afterCancel == original)
}

@Test
func resourceEditFormRoundsPartialGiBValuesUp() throws {
    let oneGiB: UInt64 = 1024 * 1024 * 1024
    let guestMemory = 4 * oneGiB + 1
    let guestDisk = 80 * oneGiB
    let dockerMemory = 2 * oneGiB + 1
    let dockerDisk = 20 * oneGiB + 1
    let dockerSettings = DockerSidecarSettings(
        memorySizeBytes: dockerMemory,
        dataDiskSizeBytes: dockerDisk,
        macOSMACAddress: "02:00:00:00:00:01",
        linuxPrivateMACAddress: "02:00:00:00:00:02",
        linuxNATMACAddress: "02:00:00:00:00:03"
    )
    let metadata = VMMetadata(
        name: "partial-resources",
        cpuCount: 4,
        memorySizeBytes: guestMemory,
        diskSizeBytes: guestDisk,
        displayWidth: 1280,
        displayHeight: 720,
        bootstrapShareEnabled: false,
        dockerSidecar: dockerSettings
    )

    let values = VMResourceFormValues(metadata: metadata)
    let docker = try #require(values.docker)
    #expect(values.memoryGiB == 5)
    #expect(docker.memoryGiB == 3)
    #expect(docker.diskGiB == 21)
}
