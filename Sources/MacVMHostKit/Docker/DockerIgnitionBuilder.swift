import Foundation

struct DockerIgnitionBuilder {
    static let rosettaVirtioFSTag = "rosetta"
    static let ignitionVersion = "3.5.0"

    let settings: DockerSidecarSettings
    let dockerAuthorizedKey: String
    let mountBrokerAuthorizedKey: String
    let linuxHostPrivateKey: String
    let linuxHostPublicKey: String
    let genericMachineIdentifierDigest: String

    func makeData() throws -> Data {
        let linuxAddress = Self.addressWithoutPrefix(settings.linuxAddress)
        let macOSAddress = Self.addressWithoutPrefix(settings.macOSAddress)
        let files = try makeFiles(linuxAddress: linuxAddress, macOSAddress: macOSAddress)
        let units = makeUnits(linuxAddress: linuxAddress, macOSAddress: macOSAddress)
        let document: [String: Any] = [
            "ignition": ["version": Self.ignitionVersion],
            "passwd": [
                "users": [
                    [
                        "name": "macvm-docker",
                        "system": true,
                        "noCreateHome": false,
                        "homeDir": "/var/lib/macvm-docker",
                        "shell": "/bin/bash",
                        "sshAuthorizedKeys": [
                            "restrict,port-forwarding,permitopen=\"127.0.0.1:2375\",permitlisten=\"127.0.0.1:2222\",command=\"/usr/bin/sleep infinity\" \(dockerAuthorizedKey)",
                        ],
                    ],
                    [
                        "name": "macvm-mount",
                        "system": true,
                        "noCreateHome": false,
                        "homeDir": "/var/lib/macvm-mount",
                        "shell": "/bin/bash",
                        "sshAuthorizedKeys": [
                            "restrict,port-forwarding,command=\"/usr/bin/sudo -n /usr/local/libexec/macvm-mount-broker\" \(mountBrokerAuthorizedKey)",
                        ],
                    ],
                ],
            ],
            "storage": [
                "filesystems": [[
                    "device": "/dev/disk/by-id/virtio-\(DockerSidecarBundle.dataDiskBlockIdentifier)",
                    "format": "ext4",
                    "label": "macvm-docker",
                    "path": "/var/lib/docker",
                    "wipeFilesystem": false,
                ]],
                "directories": [
                    ["path": "/var/lib/macvm", "mode": 448],
                ],
                "files": files,
            ],
            "systemd": ["units": units],
        ]
        return try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    }

    private func makeFiles(linuxAddress: String, macOSAddress: String) throws -> [[String: Any]] {
        let files: [[String: Any]] = [
            file(
                path: "/etc/ssh/ssh_host_ed25519_key",
                mode: 384,
                contents: linuxHostPrivateKey
            ),
            file(
                path: "/etc/ssh/ssh_host_ed25519_key.pub",
                mode: 420,
                contents: linuxHostPublicKey
            ),
            file(
                path: "/etc/NetworkManager/system-connections/macvm-private.nmconnection",
                mode: 384,
                contents: """
                [connection]
                id=macvm-private
                type=ethernet
                autoconnect=true

                [ethernet]
                mac-address=\(settings.linuxPrivateMACAddress)

                [ipv4]
                method=manual
                address1=\(settings.linuxAddress)
                never-default=true

                [ipv6]
                method=disabled
                """
            ),
            file(
                path: "/etc/NetworkManager/system-connections/macvm-nat.nmconnection",
                mode: 384,
                contents: """
                [connection]
                id=macvm-nat
                type=ethernet
                autoconnect=true

                [ethernet]
                mac-address=\(settings.linuxNATMACAddress)

                [ipv4]
                method=auto

                [ipv6]
                method=auto
                """
            ),
            file(
                path: "/etc/ssh/sshd_config.d/40-macvm-docker.conf",
                mode: 420,
                contents: """
                ListenAddress \(linuxAddress)
                PasswordAuthentication no
                KbdInteractiveAuthentication no
                PermitRootLogin no
                AllowUsers macvm-docker macvm-mount
                AllowAgentForwarding no
                X11Forwarding no
                PermitTunnel no
                GatewayPorts no
                Match User macvm-mount
                    # OpenSSH initializes the shared remote-forward permission
                    # table from AllowTcpForwarding. `no` also rejects remote
                    # StreamLocal listeners even when they are enabled below.
                    # GatewayPorts keeps any TCP listener on sidecar loopback.
                    AllowTcpForwarding remote
                    AllowStreamLocalForwarding remote
                    StreamLocalBindMask 0000
                    StreamLocalBindUnlink yes
                Match all
                """
            ),
            file(
                path: "/etc/docker/daemon.json",
                mode: 420,
                contents: """
                {
                  "data-root": "/var/lib/docker",
                  "hosts": ["unix:///run/docker.sock", "tcp://127.0.0.1:2375"]
                }
                """
            ),
            file(
                path: "/etc/containerd/config.toml",
                mode: 420,
                contents: """
                version = 2
                root = "/var/lib/docker/containerd"

                [plugins]
                  [plugins."io.containerd.grpc.v1.cri"]
                    [plugins."io.containerd.grpc.v1.cri".cni]
                      bin_dir = "/usr/libexec/cni/"
                      conf_dir = "/etc/cni/net.d"
                  [plugins."io.containerd.internal.v1.opt"]
                    path = "/var/lib/docker/containerd/opt"
                """
            ),
            file(
                path: "/etc/systemd/system/containerd.service.d/10-macvm-data.conf",
                mode: 420,
                contents: """
                [Unit]
                Requires=var-lib-docker.mount
                After=var-lib-docker.mount
                """
            ),
            file(
                path: "/etc/systemd/system/docker.service.d/10-macvm.conf",
                mode: 420,
                contents: """
                [Unit]
                Requires=var-lib-docker.mount
                After=var-lib-docker.mount macvm-clone-identity.service macvm-rosetta.service

                [Service]
                ExecStart=
                ExecStart=/usr/bin/dockerd
                """
            ),
            file(
                path: "/etc/sudoers.d/macvm-mount-broker",
                mode: 288,
                contents: "Defaults:macvm-mount env_keep += \"SSH_ORIGINAL_COMMAND\"\nmacvm-mount ALL=(root) NOPASSWD: /usr/local/libexec/macvm-mount-broker\n"
            ),
            file(
                path: "/usr/local/libexec/macvm-mount-broker",
                mode: 493,
                contents: mountBrokerScript(macOSAddress: macOSAddress, linuxAddress: linuxAddress)
            ),
            file(
                path: "/usr/local/libexec/macvm-clone-identity",
                mode: 493,
                contents: cloneIdentityScript()
            ),
            file(
                path: "/usr/local/libexec/macvm-rosetta-setup",
                mode: 493,
                contents: rosettaScript()
            ),
            file(
                path: "/etc/macvm-sidecar",
                mode: 420,
                contents: """
                FCOS_IMAGE=\(settings.imageVersion ?? "unknown")
                GENERIC_MACHINE_IDENTIFIER_SHA256=\(genericMachineIdentifierDigest)
                PRIVATE_MACOS_ADDRESS=\(macOSAddress)
                PRIVATE_LINUX_ADDRESS=\(linuxAddress)
                """
            ),
        ]
        return files
    }

    private func makeUnits(linuxAddress: String, macOSAddress: String) -> [[String: Any]] {
        var units: [[String: Any]] = [
            unit(name: "zincati.service", enabled: false, mask: true),
            unit(
                name: "sshd.service",
                enabled: true,
                dropins: [[
                    "name": "10-macvm-network.conf",
                    "contents": "[Unit]\nAfter=NetworkManager-wait-online.service\nWants=NetworkManager-wait-online.service\n",
                ]]
            ),
            unit(name: "docker.service", enabled: true),
            unit(
                name: "var-lib-docker.mount",
                enabled: true,
                contents: """
                [Unit]
                Description=Mount persistent Docker data
                Before=docker.service

                [Mount]
                What=/dev/disk/by-id/virtio-\(DockerSidecarBundle.dataDiskBlockIdentifier)
                Where=/var/lib/docker
                Type=ext4
                Options=defaults

                [Install]
                WantedBy=local-fs.target
                """
            ),
            unit(
                name: "macvm-clone-identity.service",
                enabled: true,
                contents: """
                [Unit]
                Description=Refresh Linux and standalone Moby identity after a macvm clone
                DefaultDependencies=no
                After=var-lib-docker.mount NetworkManager.service
                Wants=NetworkManager.service
                Before=docker.service

                [Service]
                Type=oneshot
                ExecStart=/usr/local/libexec/macvm-clone-identity
                RemainAfterExit=yes

                [Install]
                WantedBy=multi-user.target
                """
            ),
            unit(
                name: "macvm-filesystem-tools.service",
                enabled: true,
                contents: """
                [Unit]
                Description=Install generic macOS guest filesystem transport tools
                After=network-online.target
                Wants=network-online.target
                ConditionPathExists=!/usr/bin/sshfs
                Before=macvm-ready.service

                [Service]
                Type=oneshot
                ExecStart=/usr/bin/rpm-ostree install --idempotent --allow-inactive fuse-sshfs
                ExecStart=/usr/bin/touch /var/lib/macvm/filesystem-tools-layered
                ExecStart=/usr/bin/systemctl --no-block reboot

                [Install]
                WantedBy=multi-user.target
                """
            ),
            unit(
                name: "macvm-filesystem-key.service",
                enabled: true,
                contents: """
                [Unit]
                Description=Create the sidecar-only SSHFS identity
                Before=sshd.service macvm-ready.service

                [Service]
                Type=oneshot
                ExecStart=/usr/bin/env SSH_ORIGINAL_COMMAND=public-key /usr/local/libexec/macvm-mount-broker
                StandardOutput=journal+console
                StandardError=journal+console
                RemainAfterExit=yes

                [Install]
                WantedBy=multi-user.target
                """
            ),
            unit(
                name: "macvm-firewall.service",
                enabled: true,
                contents: """
                [Unit]
                Description=Restrict management SSH to the isolated macvm interface
                After=NetworkManager.service
                Wants=NetworkManager.service
                Before=sshd.service

                [Service]
                Type=oneshot
                ExecStart=/bin/bash -c 'iface=""; for i in $(seq 1 120); do iface=$(nmcli -g GENERAL.DEVICES connection show macvm-private 2>/dev/null || true); [[ -n "$iface" ]] && break; sleep 1; done; [[ -n "$iface" ]]; iptables=$(command -v iptables); "$iptables" --wait -N MACVM_MANAGEMENT_INPUT 2>/dev/null || true; "$iptables" --wait -F MACVM_MANAGEMENT_INPUT; "$iptables" --wait -A MACVM_MANAGEMENT_INPUT -s \(macOSAddress)/32 -p tcp --dport 22 -j ACCEPT; "$iptables" --wait -A MACVM_MANAGEMENT_INPUT -j DROP; "$iptables" --wait -C INPUT -i "$iface" -d \(linuxAddress)/32 -j MACVM_MANAGEMENT_INPUT 2>/dev/null || "$iptables" --wait -I INPUT 1 -i "$iface" -d \(linuxAddress)/32 -j MACVM_MANAGEMENT_INPUT'
                StandardOutput=journal+console
                StandardError=journal+console
                RemainAfterExit=yes

                [Install]
                WantedBy=multi-user.target
                """
            ),
            unit(
                name: "macvm-ready.service",
                enabled: true,
                contents: """
                [Unit]
                Description=Publish Docker sidecar readiness
                After=docker.service sshd.service macvm-filesystem-key.service macvm-filesystem-tools.service macvm-firewall.service macvm-rosetta.service
                Requires=docker.service sshd.service macvm-filesystem-key.service macvm-filesystem-tools.service macvm-firewall.service

                [Service]
                Type=oneshot
                ExecStart=/bin/sh -c 'for i in $(seq 1 120); do docker info >/dev/null 2>&1 && touch /run/macvm-docker-ready && printf "\\nMACVM_DOCKER_READY\\n" >/dev/hvc0 && exit 0; sleep 1; done; exit 1'
                RemainAfterExit=yes

                [Install]
                WantedBy=multi-user.target
                """
            ),
        ]
        units.append(unit(
            name: "macvm-rosetta.service",
            enabled: true,
            contents: """
            [Unit]
            Description=Mount Rosetta for Linux and register linux/amd64 binaries when the host share is attached
            Before=docker.service macvm-ready.service
            After=proc-sys-fs-binfmt_misc.automount
            ConditionPathExists=/usr/local/libexec/macvm-rosetta-setup

            [Service]
            Type=oneshot
            ExecStart=/usr/local/libexec/macvm-rosetta-setup
            RemainAfterExit=yes

            [Install]
            WantedBy=multi-user.target
            """
        ))
        return units
    }

    private func mountBrokerScript(macOSAddress: String, linuxAddress: String) -> String {
        """
        #!/bin/bash
        set -euo pipefail

        ensure_filesystem_key() {
          /usr/bin/install -d -m 0700 /var/lib/macvm
          if [[ ! -s /var/lib/macvm/macos_fs_ed25519 || ! -s /var/lib/macvm/macos_fs_ed25519.pub ]]; then
            temporary="$(/usr/bin/mktemp -d /tmp/macvm-filesystem-key.XXXXXX)"
            trap '/usr/bin/rm -rf "$temporary"' EXIT
            umask 077
            /usr/bin/ssh-keygen -q -t ed25519 -N "" -C macvm-filesystem -f "$temporary/macos_fs_ed25519"
            /usr/bin/install -m 0600 "$temporary/macos_fs_ed25519" /var/lib/macvm/macos_fs_ed25519
            /usr/bin/install -m 0644 "$temporary/macos_fs_ed25519.pub" /var/lib/macvm/macos_fs_ed25519.pub
            /usr/sbin/restorecon -F /var/lib/macvm/macos_fs_ed25519 /var/lib/macvm/macos_fs_ed25519.pub || true
            /usr/bin/rm -rf "$temporary"
            trap - EXIT
          fi
        }

        IFS=' ' read -r action filesystem_id _ <<<"${SSH_ORIGINAL_COMMAND:-}"
        argument="${SSH_ORIGINAL_COMMAND#* }"
        argument="${argument#* }"
        case "$action" in
          public-key)
            ensure_filesystem_key
            exec /usr/bin/cat /var/lib/macvm/macos_fs_ed25519.pub
            ;;
          mount-sshfs|mount-sshfs-file)
            [[ "$filesystem_id" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || exit 64
            remote_user="${argument%% *}"
            remote_path="${argument#* }"
            [[ "$remote_user" =~ ^[A-Za-z0-9._-]+$ ]] || exit 64
            [[ "$remote_path" == /* ]] || exit 64
            ensure_filesystem_key
            target="/run/macvm-macos/$filesystem_id"
            /usr/bin/mkdir -p "$target"
            follow=()
            [[ "$action" == "mount-sshfs-file" ]] && follow=(-o follow_symlinks)
            if ! /usr/bin/mountpoint -q "$target"; then
              exec /usr/bin/sshfs "$remote_user@127.0.0.1:$remote_path" "$target" -p 2222 -o IdentityFile=/var/lib/macvm/macos_fs_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/var/lib/macvm/macos_known_hosts -o reconnect -o allow_other "${follow[@]}"
            fi
            ;;
          unmount)
            [[ "$filesystem_id" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || exit 64
            target="/run/macvm-macos/$filesystem_id"
            /usr/bin/mountpoint -q "$target" && /usr/bin/umount --lazy "$target" || true
            /usr/bin/rmdir "$target" 2>/dev/null || true
            ;;
          prepare-socket|wait-socket|remove-socket)
            [[ "$filesystem_id" =~ ^socket-[A-Za-z0-9._-]{1,57}$ ]] || exit 64
            target="/run/macvm-macos/$filesystem_id"
            socket="$target/source"
            if [[ "$action" == "prepare-socket" ]]; then
              /usr/bin/install -d -o macvm-mount -g macvm-mount -m 0700 "$target"
              /usr/bin/rm -f "$socket"
            elif [[ "$action" == "wait-socket" ]]; then
              for _ in {1..100}; do
                [[ -S "$socket" ]] && exit 0
                /usr/bin/sleep 0.1
              done
              exit 75
            else
              /usr/bin/rm -f "$socket"
              /usr/bin/rmdir "$target" 2>/dev/null || true
            fi
            ;;
          reset-ports|publish-port|unpublish-port)
            interface="$(nmcli -g GENERAL.DEVICES connection show macvm-private)"
            [[ -n "$interface" ]] || exit 69
            iptables="$(command -v iptables)"
            "$iptables" --wait -t nat -N MACVM_DOCKER_NAT 2>/dev/null || true
            "$iptables" --wait -N MACVM_DOCKER_INPUT 2>/dev/null || true
            nat_jump=(-i "$interface" -s "\(macOSAddress)/32" -d "\(linuxAddress)/32" -j MACVM_DOCKER_NAT)
            input_jump=(-i "$interface" -s "\(macOSAddress)/32" -d 127.0.0.1/32 -j MACVM_DOCKER_INPUT)
            "$iptables" --wait -t nat -C PREROUTING "${nat_jump[@]}" 2>/dev/null || "$iptables" --wait -t nat -A PREROUTING "${nat_jump[@]}"
            "$iptables" --wait -C INPUT "${input_jump[@]}" 2>/dev/null || "$iptables" --wait -I INPUT 1 "${input_jump[@]}"
            if [[ "$action" == "reset-ports" ]]; then
              "$iptables" --wait -t nat -F MACVM_DOCKER_NAT
              "$iptables" --wait -F MACVM_DOCKER_INPUT
              exit 0
            fi
            protocol="$filesystem_id"
            port="$argument"
            [[ "$protocol" == "tcp" || "$protocol" == "udp" ]] || exit 64
            [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( port >= 1 && port <= 65535 )) || exit 64
            rule=(-p "$protocol" --dport "$port" -j DNAT --to-destination "127.0.0.1:$port")
            input_rule=(-p "$protocol" --dport "$port" -j ACCEPT)
            if [[ "$action" == "publish-port" ]]; then
              /usr/sbin/sysctl -q -w net.ipv4.conf.all.route_localnet=1
              /usr/sbin/sysctl -q -w "net.ipv4.conf.$interface.route_localnet=1"
              "$iptables" --wait -t nat -C MACVM_DOCKER_NAT "${rule[@]}" 2>/dev/null || "$iptables" --wait -t nat -A MACVM_DOCKER_NAT "${rule[@]}"
              "$iptables" --wait -C MACVM_DOCKER_INPUT "${input_rule[@]}" 2>/dev/null || "$iptables" --wait -A MACVM_DOCKER_INPUT "${input_rule[@]}"
            else
              while "$iptables" --wait -t nat -C MACVM_DOCKER_NAT "${rule[@]}" 2>/dev/null; do "$iptables" --wait -t nat -D MACVM_DOCKER_NAT "${rule[@]}"; done
              while "$iptables" --wait -C MACVM_DOCKER_INPUT "${input_rule[@]}" 2>/dev/null; do "$iptables" --wait -D MACVM_DOCKER_INPUT "${input_rule[@]}"; done
            fi
            ;;
          *) exit 64 ;;
        esac
        """
    }

    private func cloneIdentityScript() -> String {
        """
        #!/bin/bash
        set -euo pipefail
        install -d -m 0700 /var/lib/macvm
        current="$(cat /sys/class/dmi/id/product_uuid 2>/dev/null || sha256sum /etc/macvm-sidecar | cut -d' ' -f1)"
        previous="$(cat /var/lib/macvm/hardware-id 2>/dev/null || true)"
        if [[ -n "$previous" && "$previous" != "$current" ]]; then
          rm -f /etc/machine-id /var/lib/dbus/machine-id /var/lib/docker/engine-id
          touch /etc/machine-id
          systemd-machine-id-setup
          private_mac="\(settings.linuxPrivateMACAddress.lowercased())"
          for address_file in /sys/class/net/*/address; do
            interface="$(basename "$(dirname "$address_file")")"
            mac="$(tr '[:upper:]' '[:lower:]' < "$address_file")"
            [[ "$interface" == "lo" || "$mac" == "$private_mac" || "$mac" == "00:00:00:00:00:00" ]] && continue
            nmcli connection modify macvm-nat 802-3-ethernet.mac-address "$mac"
            nmcli connection up macvm-nat ifname "$interface" || true
            break
          done
        fi
        printf '%s\n' "$current" > /var/lib/macvm/hardware-id
        """
    }

    private func rosettaScript() -> String {
        """
        #!/bin/bash
        set -euo pipefail
        mkdir -p /run/macvm-rosetta
        if ! mountpoint -q /run/macvm-rosetta && ! mount -t virtiofs \(Self.rosettaVirtioFSTag) /run/macvm-rosetta; then
          exit 0
        fi
        mountpoint -q /proc/sys/fs/binfmt_misc || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
        if [[ ! -e /proc/sys/fs/binfmt_misc/rosetta ]]; then
          printf '%s\\n' ':rosetta:M::\\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\x3e\\x00:\\xff\\xff\\xff\\xff\\xff\\xfe\\xfe\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff:/run/macvm-rosetta/rosetta:OCF' > /proc/sys/fs/binfmt_misc/register
        fi
        """
    }

    private func file(path: String, mode: Int, contents: String) -> [String: Any] {
        [
            "path": path,
            "mode": mode,
            "overwrite": true,
            "contents": ["source": "data:text/plain;charset=utf-8;base64,\(Data(contents.utf8).base64EncodedString())"],
        ]
    }

    private func unit(
        name: String,
        enabled: Bool,
        mask: Bool? = nil,
        contents: String? = nil,
        dropins: [[String: Any]]? = nil
    ) -> [String: Any] {
        var value: [String: Any] = ["name": name, "enabled": enabled]
        if let mask { value["mask"] = mask }
        if let contents { value["contents"] = contents }
        if let dropins { value["dropins"] = dropins }
        return value
    }

    private static func addressWithoutPrefix(_ address: String) -> String {
        String(address.split(separator: "/", maxSplits: 1).first ?? Substring(address))
    }
}
