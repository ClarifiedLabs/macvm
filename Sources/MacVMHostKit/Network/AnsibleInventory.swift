import Foundation

/// Renders an Ansible inventory line for a guest VM.
///
/// Emits a single host entry with connection variables so a play can target the
/// guest directly after writing the line to an inventory file.
enum AnsibleInventory {
    static func render(name: String, host: String, user: String, identityFile: URL?) -> String {
        var fields = [
            "ansible_host=\(host)",
            "ansible_user=\(user)",
        ]
        if let identityFile {
            fields.append("ansible_ssh_private_key_file=\(identityFile.path)")
        }
        fields.append("ansible_ssh_use_tty=false")
        fields.append(
            "ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null'"
        )
        return "\(name) \(fields.joined(separator: " "))"
    }
}
