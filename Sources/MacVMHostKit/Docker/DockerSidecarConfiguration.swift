import Foundation
import Virtualization

struct DockerSidecarConfiguration {
    let bundle: DockerSidecarBundle
    let settings: DockerSidecarSettings
    let pairNetwork: DockerPairNetwork
    let serialLogHandle: FileHandle

    func makeConfiguration() throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = try bundle.loadGenericMachineIdentifier()
        configuration.platform = platform

        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = bundle.loadEFIVariableStore()
        configuration.bootLoader = bootLoader
        configuration.cpuCount = settings.cpuCount
        configuration.memorySize = settings.memorySizeBytes
        configuration.storageDevices = try makeStorageDevices()
        configuration.networkDevices = try makeNetworkDevices()
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        configuration.serialPorts = [makeSerialPort()]

        if settings.amd64Enabled, VZLinuxRosettaDirectoryShare.availability == .installed {
            let fileSystem = VZVirtioFileSystemDeviceConfiguration(tag: DockerIgnitionBuilder.rosettaVirtioFSTag)
            fileSystem.share = try VZLinuxRosettaDirectoryShare()
            configuration.directorySharingDevices = [fileSystem]
        }

        try configuration.validate()
        return configuration
    }

    private func makeStorageDevices() throws -> [VZStorageDeviceConfiguration] {
        let systemAttachment = try VZDiskImageStorageDeviceAttachment(url: bundle.systemDiskURL, readOnly: false)
        let system = VZVirtioBlockDeviceConfiguration(attachment: systemAttachment)
        system.blockDeviceIdentifier = "macvm-fcos-system"

        let dataAttachment = try VZDiskImageStorageDeviceAttachment(url: bundle.dataDiskURL, readOnly: false)
        let data = VZVirtioBlockDeviceConfiguration(attachment: dataAttachment)
        data.blockDeviceIdentifier = DockerSidecarBundle.dataDiskBlockIdentifier
        return [system, data]
    }

    private func makeNetworkDevices() throws -> [VZNetworkDeviceConfiguration] {
        let privateDevice = try pairNetwork.makeLinuxNetworkDevice(macAddress: settings.linuxPrivateMACAddress)
        guard let natAddress = VZMACAddress(string: settings.linuxNATMACAddress) else {
            throw MacVMError.message("Invalid Docker sidecar NAT MAC address: \(settings.linuxNATMACAddress)")
        }
        let natDevice = VZVirtioNetworkDeviceConfiguration()
        natDevice.attachment = VZNATNetworkDeviceAttachment()
        natDevice.macAddress = natAddress
        return [privateDevice, natDevice]
    }

    private func makeSerialPort() -> VZSerialPortConfiguration {
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: nil,
            fileHandleForWriting: serialLogHandle
        )
        return serial
    }
}
