import Darwin
import Foundation

public enum DockerCredentialDrop {
    public static func executeAsUser(
        username: String,
        executablePath: String,
        arguments: [String]
    ) throws -> Never {
        guard geteuid() == 0 else {
            throw DockerGuestCoreError("Credential dropping requires root.")
        }
        guard !username.isEmpty,
              username.utf8.count <= 256,
              !username.contains("\0"),
              let account = getpwnam(username) else {
            throw DockerGuestCoreError("The Docker setup account is invalid.")
        }
        let uid = account.pointee.pw_uid
        let gid = account.pointee.pw_gid
        guard initgroups(username, Int32(gid)) == 0,
              setgid(gid) == 0,
              setuid(uid) == 0,
              getuid() == uid,
              geteuid() == uid,
              getgid() == gid,
              getegid() == gid else {
            throw DockerGuestCoreError("Unable to drop Docker relay credentials.")
        }

        let values = [executablePath] + arguments
        let duplicated = values.map { strdup($0) }
        defer { duplicated.forEach { free($0) } }
        var argv = duplicated + [nil]
        execv(executablePath, &argv)
        throw DockerGuestCoreError("Unable to execute the credential-dropped Docker relay.")
    }
}
