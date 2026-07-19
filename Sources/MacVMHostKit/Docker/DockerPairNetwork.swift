import Darwin
import Foundation
import Virtualization

final class DockerPairNetwork: @unchecked Sendable {
    private let macOSFileHandle: FileHandle
    private let linuxFileHandle: FileHandle

    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &descriptors) == 0 else {
            throw MacVMError.message("Couldn't create the private Docker sidecar network: \(String(cString: strerror(errno)))")
        }
        do {
            try Self.configureSocket(descriptors[0])
            try Self.configureSocket(descriptors[1])
        } catch {
            close(descriptors[0])
            close(descriptors[1])
            throw error
        }
        macOSFileHandle = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        linuxFileHandle = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
    }

    func makeMacOSNetworkDevice(macAddress: String) throws -> VZVirtioNetworkDeviceConfiguration {
        try makeNetworkDevice(fileHandle: macOSFileHandle, macAddress: macAddress)
    }

    func makeLinuxNetworkDevice(macAddress: String) throws -> VZVirtioNetworkDeviceConfiguration {
        try makeNetworkDevice(fileHandle: linuxFileHandle, macAddress: macAddress)
    }

    private func makeNetworkDevice(
        fileHandle: FileHandle,
        macAddress: String
    ) throws -> VZVirtioNetworkDeviceConfiguration {
        guard let parsedAddress = VZMACAddress(string: macAddress) else {
            throw MacVMError.message("Invalid Docker private network MAC address: \(macAddress)")
        }
        let device = VZVirtioNetworkDeviceConfiguration()
        let attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: fileHandle)
        attachment.maximumTransmissionUnit = 1500
        device.attachment = attachment
        device.macAddress = parsedAddress
        return device
    }

    private static func configureSocket(_ descriptor: Int32) throws {
        var sendBuffer = Int32(4 * 1024 * 1024)
        var receiveBuffer = Int32(16 * 1024 * 1024)
        guard setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout.size(ofValue: sendBuffer))) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout.size(ofValue: receiveBuffer))) == 0 else {
            throw MacVMError.message("Couldn't configure the private Docker sidecar network: \(String(cString: strerror(errno)))")
        }
    }
}
