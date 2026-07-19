import Foundation
import Testing
@testable import MacVMHostKit

private func dockerJSONObject(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test
func dockerCreateRewriterMapsOnlyBindSchemaFields() throws {
    let body = Data("""
    {
      "Image":"example:latest",
      "Labels":{"description":"/Users/dev/project must remain literal"},
      "HostConfig":{
        "Binds":["/Users/dev/project:/work:ro","named-volume:/data"],
        "Mounts":[
          {"Type":"bind","Source":"/private/tmp","Target":"/tmp"},
          {"Type":"volume","Source":"/Users/dev/not-a-path","Target":"/volume"},
          {"Type":"volume","Source":"nested","Target":"/nested","VolumeOptions":{"DriverConfig":{"Name":"local","Options":{"type":"none","o":"rbind,rw","device":"/Users/dev/nested"}}}}
        ]
      }
    }
    """.utf8)
    var mapped: [String] = []
    let rewritten = try DockerAPIPathRewriter.rewriteRequestBody(
        body,
        method: "POST",
        uri: "/v1.51/containers/create?name=test"
    ) { source in
        mapped.append(source)
        return "/run/macvm-macos/fs-test" + source
    }
    let root = try dockerJSONObject(rewritten)
    let hostConfig = try #require(root["HostConfig"] as? [String: Any])
    let binds = try #require(hostConfig["Binds"] as? [String])
    let mounts = try #require(hostConfig["Mounts"] as? [[String: Any]])
    let labels = try #require(root["Labels"] as? [String: String])

    #expect(binds == [
        "/run/macvm-macos/fs-test/Users/dev/project:/work:ro",
        "named-volume:/data",
    ])
    #expect(mounts[0]["Source"] as? String == "/run/macvm-macos/fs-test/private/tmp")
    #expect(mounts[1]["Source"] as? String == "/Users/dev/not-a-path")
    let volumeOptions = try #require(mounts[2]["VolumeOptions"] as? [String: Any])
    let driverConfig = try #require(volumeOptions["DriverConfig"] as? [String: Any])
    let driverOptions = try #require(driverConfig["Options"] as? [String: Any])
    #expect(driverOptions["device"] as? String == "/run/macvm-macos/fs-test/Users/dev/nested")
    #expect(labels["description"] == "/Users/dev/project must remain literal")
    #expect(mapped == ["/Users/dev/project", "/private/tmp", "/Users/dev/nested"])
}

@Test
func dockerServiceAndLocalVolumeBindFieldsAreMapped() throws {
    let serviceBody = Data("""
    {"TaskTemplate":{"ContainerSpec":{"Mounts":[
      {"Type":"bind","Source":"/Volumes/My Shared Files/code","Target":"/src"}
    ]}}}
    """.utf8)
    let service = try DockerAPIPathRewriter.rewriteRequestBody(
        serviceBody,
        method: "POST",
        uri: "/services/create"
    ) { _ in "/run/macvm-macos/fs-volume/code" }
    let serviceObject = try dockerJSONObject(service)
    let task = try #require(serviceObject["TaskTemplate"] as? [String: Any])
    let container = try #require(task["ContainerSpec"] as? [String: Any])
    let mounts = try #require(container["Mounts"] as? [[String: Any]])
    #expect(mounts[0]["Source"] as? String == "/run/macvm-macos/fs-volume/code")

    let volumeBody = Data("""
    {"Name":"project","Driver":"local","DriverOpts":{"type":"none","o":"bind,ro","device":"/Users/Shared/project"}}
    """.utf8)
    let volume = try DockerAPIPathRewriter.rewriteRequestBody(
        volumeBody,
        method: "POST",
        uri: "/v1.51/volumes/create"
    ) { _ in "/run/macvm-macos/fs-root/Users/Shared/project" }
    let options = try #require(try dockerJSONObject(volume)["DriverOpts"] as? [String: Any])
    #expect(options["device"] as? String == "/run/macvm-macos/fs-root/Users/Shared/project")
}

@Test
func dockerInspectRewriterRestoresMacOSGuestPaths() throws {
    let body = Data("""
    {"Id":"abc","Mounts":[
      {"Type":"bind","Source":"/run/macvm-macos/fs-root/Users/dev/project","Destination":"/work"},
      {"Type":"volume","Source":"/var/lib/docker/volumes/v/_data","Destination":"/data"}
    ]}
    """.utf8)
    let rewritten = try DockerAPIPathRewriter.rewriteResponseBody(
        body,
        method: "GET",
        uri: "/v1.51/containers/abc/json",
        status: 200
    ) { source in
        source.replacingOccurrences(of: "/run/macvm-macos/fs-root", with: "")
    }
    let mounts = try #require(try dockerJSONObject(rewritten)["Mounts"] as? [[String: Any]])
    #expect(mounts[0]["Source"] as? String == "/Users/dev/project")
    #expect(mounts[1]["Source"] as? String == "/var/lib/docker/volumes/v/_data")
}

@Test
func unknownDockerEndpointsRemainUntouchedBySchemaRewriter() throws {
    let body = Data("{\"Arbitrary\":\"/Users/dev/project\"}".utf8)
    var transformed = false
    let request = try DockerAPIPathRewriter.rewriteRequestBody(
        body,
        method: "POST",
        uri: "/v1.51/plugins/pull"
    ) { value in
        transformed = true
        return value
    }
    let response = try DockerAPIPathRewriter.rewriteResponseBody(
        body,
        method: "GET",
        uri: "/v1.51/info",
        status: 200
    ) { value in
        transformed = true
        return value
    }
    #expect(request == body)
    #expect(response == body)
    #expect(!transformed)
}

@Test
func dockerCreateRejectsIPv6PublishedPorts() {
    let body = Data("""
    {"HostConfig":{"PortBindings":{"8080/tcp":[{"HostIp":"::1","HostPort":"28183"}]}}}
    """.utf8)

    do {
        _ = try DockerAPIPathRewriter.rewriteRequestBody(
            body,
            method: "POST",
            uri: "/containers/create"
        ) { $0 }
        Issue.record("Expected IPv6 publication to be rejected.")
    } catch {
        #expect(error.localizedDescription.contains("IPv6 Docker publication"))
    }
}

@Test
func dockerCreateRejectsAmbiguousPublishedPortAddresses() {
    let body = Data("""
    {"HostConfig":{"PortBindings":{
      "8080/tcp":[{"HostIp":"127.0.0.1","HostPort":"28184"}],
      "8081/tcp":[{"HostIp":"0.0.0.0","HostPort":"28184"}]
    }}}
    """.utf8)

    do {
        _ = try DockerAPIPathRewriter.rewriteRequestBody(
            body,
            method: "POST",
            uri: "/v1.51/containers/create"
        ) { $0 }
        Issue.record("Expected ambiguous publication to be rejected.")
    } catch {
        #expect(error.localizedDescription.contains("cannot use multiple host addresses"))
    }
}
