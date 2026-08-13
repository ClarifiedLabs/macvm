import Foundation
import Testing
@testable import MacVMDockerGuestCore
@testable import MacVMHostKit

private func proxyHeaders(_ values: [(String, String)]) -> [DockerHTTPHeaderField] {
    values.map { DockerHTTPHeaderField(name: $0.0, value: $0.1) }
}

@Test
func dockerRawProxyRejectsAmbiguousAndMalformedFraming() {
    #expect(DockerRawProxyPolicy.framing(
        isRequest: true,
        headers: proxyHeaders([
            ("Transfer-Encoding", "chunked"),
            ("Content-Length", "4"),
        ])
    ) == .rejected("Transfer-Encoding and Content-Length cannot be combined."))
    #expect(DockerRawProxyPolicy.framing(
        isRequest: true,
        headers: proxyHeaders([("Content-Length", "+4")])
    ) == .rejected("Invalid or conflicting Content-Length headers."))
    #expect(DockerRawProxyPolicy.framing(
        isRequest: true,
        headers: proxyHeaders([("Transfer-Encoding", "chunked, gzip")])
    ) == .rejected("Unsupported request Transfer-Encoding framing."))
    #expect(DockerRawProxyPolicy.framing(
        isRequest: true,
        headers: proxyHeaders([("Content-Length", "4, 4")])
    ) == .accepted(.fixed(4)))
}

@Test
func dockerRawProxyRequiresSymmetricValidatedHijackUpgrade() {
    let request = proxyHeaders([
        ("Connection", "keep-alive, Upgrade"),
        ("Upgrade", "tcp"),
    ])
    #expect(DockerRawProxyPolicy.requestUpgrade(method: "POST", uri: "/containers/id/attach", headers: request) == .requested("tcp"))
    #expect(DockerRawProxyPolicy.requestUpgrade(
        method: "POST",
        uri: "/containers/id/attach",
        headers: proxyHeaders([("Upgrade", "tcp")])
    ) == .rejected("Docker hijack requests require matching Connection: Upgrade and one valid Upgrade protocol."))

    #expect(DockerRawProxyPolicy.tunnelDecision(
        requestMethod: "POST",
        requestURI: "/containers/id/attach",
        requestedUpgrade: "tcp",
        responseStatus: 200,
        responseHeaders: []
    ) == .http)
    #expect(DockerRawProxyPolicy.tunnelDecision(
        requestMethod: "POST",
        requestURI: "/containers/id/attach",
        requestedUpgrade: "tcp",
        responseStatus: 101,
        responseHeaders: proxyHeaders([
            ("Connection", "Upgrade"),
            ("Upgrade", "websocket"),
        ])
    ) == .reject)
    #expect(DockerRawProxyPolicy.tunnelDecision(
        requestMethod: "POST",
        requestURI: "/containers/id/attach",
        requestedUpgrade: "tcp",
        responseStatus: 101,
        responseHeaders: proxyHeaders([
            ("Connection", "Upgrade"),
            ("Upgrade", "TCP"),
        ])
    ) == .tunnel)
    #expect(DockerRawProxyPolicy.tunnelDecision(
        requestMethod: "GET",
        requestURI: "/containers/id/json",
        requestedUpgrade: nil,
        responseStatus: 101,
        responseHeaders: []
    ) == .reject)
}

@Test
func dockerRawProxyBackpressureAndParserLimitsAreBounded() {
    #expect(DockerRawProxyPolicy.inspectHead(Data("GET / HTTP/1.1\r\n".utf8)) == .incomplete)
    #expect(DockerRawProxyPolicy.inspectHead(Data("GET / HTTP/1.1\r\n\r\n".utf8)) == .complete(18))
    #expect(DockerRawProxyPolicy.inspectHead(
        Data(repeating: 0x41, count: DockerRawProxyPolicy.maximumHeadBytes)
    ) == .rejected("HTTP headers exceed 64 KiB."))
    #expect(DockerRawProxyPolicy.maximumHeadBytes > 0)
    #expect(DockerRawProxyPolicy.maximumChunkLineBytes < DockerRawProxyPolicy.maximumHeadBytes)
    #expect(DockerRawProxyPolicy.maximumTrailerBytes == DockerRawProxyPolicy.maximumHeadBytes)
    #expect(DockerRawProxyPolicy.writeBufferLowWaterMark < DockerRawProxyPolicy.writeBufferHighWaterMark)
    #expect(DockerRawProxyPolicy.maximumPendingBackendBytes == DockerRawProxyPolicy.writeBufferHighWaterMark)
    #expect(DockerRawProxyPolicy.maximumInFlightRequests == 128)
}

@Test
func dockerRawProxyChunkSizeLimitUsesRelativeDataIndices() {
    var input = Data(repeating: 0x41, count: DockerRawProxyPolicy.maximumChunkLineBytes + 1)
    input.append(Data("2000\r\n".utf8))
    input.removeFirst(DockerRawProxyPolicy.maximumChunkLineBytes + 1)

    #expect(input.startIndex > DockerRawProxyPolicy.maximumChunkLineBytes)
    #expect(DockerRawProxyPolicy.inspectChunkSizeLine(input) == .complete(size: 0x2000, encodedLength: 6))
}

@Test
func dockerIgnitionPolicyAcceptsOnlyCoreOSAppleHVRequest() throws {
    let valid = Data(
        "GET / HTTP/1.1\r\nHost: d\r\nAccept: application/json\r\n\r\n".utf8
    )
    #expect(DockerIgnitionRequestPolicy.evaluate(valid) == .serve)
    #expect(DockerIgnitionRequestPolicy.evaluate(Data(
        "GET /other HTTP/1.1\r\nHost: d\r\n\r\n".utf8
    )) == .badRequest)
    #expect(DockerIgnitionRequestPolicy.evaluate(Data(
        "POST / HTTP/1.1\r\nHost: d\r\nContent-Length: 0\r\n\r\n".utf8
    )) == .badRequest)
    #expect(DockerIgnitionRequestPolicy.evaluate(
        Data(repeating: 0x41, count: DockerIgnitionRequestPolicy.maximumRequestBytes + 1)
    ) == .requestTooLarge)

    let server = try DockerIgnitionServer(ignitionData: Data("{}".utf8))
    #expect(!server.isSealed)
    #expect(DockerIgnitionServer.maximumConcurrentConnections == 4)
    server.seal()
    server.seal()
    #expect(server.isSealed)
    #expect(throws: (any Error).self) {
        _ = try DockerIgnitionServer(
            ignitionData: Data(
                repeating: 0,
                count: DockerIgnitionRequestPolicy.maximumIgnitionBytes + 1
            )
        )
    }
}

private struct DockerExportTransactionTestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@Test
func dockerExportInstallTransactionRestoresOldCapabilityAndReportsRollbackFailure() throws {
    var descriptor = "old descriptor"
    var authorization = "old authorization"
    #expect(throws: DockerExportTransactionTestError.self) {
        try DockerExportInstallTransaction.perform(
            installDescriptor: { descriptor = "new descriptor" },
            installAuthorization: {
                authorization = "new authorization"
                throw DockerExportTransactionTestError(message: "authorization failed")
            },
            restoreAuthorization: { authorization = "old authorization" },
            restoreDescriptor: { descriptor = "old descriptor" }
        )
    }
    #expect(descriptor == "old descriptor")
    #expect(authorization == "old authorization")

    do {
        try DockerExportInstallTransaction.perform(
            installDescriptor: {},
            installAuthorization: {
                throw DockerExportTransactionTestError(message: "install failed")
            },
            restoreAuthorization: {
                throw DockerExportTransactionTestError(message: "authorization rollback failed")
            },
            restoreDescriptor: {
                throw DockerExportTransactionTestError(message: "descriptor rollback failed")
            }
        )
        Issue.record("Expected combined export installation failure")
    } catch {
        #expect(error.localizedDescription.contains("install failed"))
        #expect(error.localizedDescription.contains("authorization rollback failed"))
        #expect(error.localizedDescription.contains("descriptor rollback failed"))
    }
}

@Test
func dockerSwarmServicePublicationsValidateAndTriggerReconciliation() throws {
    let body = Data("""
    {
      "EndpointSpec":{"Ports":[
        {"Protocol":"tcp","TargetPort":80,"PublishedPort":8080,"PublishMode":"ingress"},
        {"Protocol":"udp","TargetPort":53,"PublishedPort":5353,"PublishMode":"host"}
      ]},
      "TaskTemplate":{"ContainerSpec":{"Mounts":[
        {"Type":"bind","Source":"/Users/dev/swarm","Target":"/src"}
      ]}}
    }
    """.utf8)
    let rewritten = try DockerAPIPathRewriter.rewriteRequestBody(
        body,
        method: "POST",
        uri: "/v1.51/services/create"
    ) { _ in "/run/macvm-macos/swarm" }
    let object = try #require(try JSONSerialization.jsonObject(with: rewritten) as? [String: Any])
    let task = try #require(object["TaskTemplate"] as? [String: Any])
    let container = try #require(task["ContainerSpec"] as? [String: Any])
    let mounts = try #require(container["Mounts"] as? [[String: Any]])
    #expect(mounts[0]["Source"] as? String == "/run/macvm-macos/swarm")

    #expect(DockerAPIPathRewriter.affectsPublishedPorts(
        method: "POST",
        uri: "/services/create",
        status: 201
    ))
    #expect(DockerAPIPathRewriter.affectsPublishedPorts(
        method: "POST",
        uri: "/v1.51/services/id/update?version=7",
        status: 200
    ))
    #expect(DockerAPIPathRewriter.affectsPublishedPorts(
        method: "DELETE",
        uri: "/services/id",
        status: 200
    ))
}

@Test
func dockerSwarmServiceRejectsUnsupportedPublicationProtocol() {
    let body = Data("""
    {"EndpointSpec":{"Ports":[
      {"Protocol":"sctp","TargetPort":80,"PublishedPort":8080}
    ]}}
    """.utf8)
    #expect(throws: (any Error).self) {
        _ = try DockerAPIPathRewriter.rewriteRequestBody(
            body,
            method: "POST",
            uri: "/services/create"
        ) { $0 }
    }
}

@Test
func dockerSwarmServiceReconciliationDecodesRuntimePublications() throws {
    let data = Data("""
    [{
      "Spec":{"EndpointSpec":{"Ports":[
        {"Protocol":"tcp","TargetPort":81,"PublishedPort":8081}
      ]}},
      "Endpoint":{"Ports":[
        {"Protocol":"tcp","TargetPort":80,"PublishedPort":8080,"PublishMode":"ingress"},
        {"Protocol":"udp","TargetPort":53,"PublishedPort":5353,"PublishMode":"host"}
      ]}
    }]
    """.utf8)
    let bindings = try DockerPublishedPortPolicy.serviceBindings(from: data)
    #expect(bindings == [
        DockerPublishedPortBinding(hostIP: "0.0.0.0", hostPort: 8080, guestPort: 80, kind: .tcp),
        DockerPublishedPortBinding(hostIP: "0.0.0.0", hostPort: 5353, guestPort: 53, kind: .udp),
    ])
    let conflicting = bindings + [
        DockerPublishedPortBinding(hostIP: "", hostPort: 8080, guestPort: 9999, kind: .tcp),
    ]
    #expect(Set(conflicting).count == 3)
    #expect(throws: (any Error).self) {
        try DockerPublishedPortPolicy.validateRuntimeBindings(conflicting)
    }
    #expect(throws: (any Error).self) {
        try DockerPublishedPortPolicy.validateRuntimeBindings(Array(conflicting.reversed()))
    }
    #expect(try DockerPublishedPortPolicy.swarmManagerIsActive(in: Data(
        #"{"Swarm":{"LocalNodeState":"active","ControlAvailable":true}}"#.utf8
    )))
    #expect(try !DockerPublishedPortPolicy.swarmManagerIsActive(in: Data(
        #"{"Swarm":{"LocalNodeState":"inactive","ControlAvailable":false}}"#.utf8
    )))
}
