import Foundation

enum DockerGuestToolInstaller {
    static let homebrewExecutablePath = "/opt/homebrew/bin/brew"
    static let dockerExecutablePath = "/opt/homebrew/bin/docker"
    static let pluginDirectory = "/opt/homebrew/lib/docker/cli-plugins"

    static let packageInstallScript = #"""
    set -euo pipefail
    /opt/homebrew/bin/brew install docker docker-buildx docker-compose
    """#

    static let configurationScript = #"""
    set -euo pipefail
    docker_dir="$HOME/.docker"
    config="$docker_dir/config.json"
    plugin_dir=/opt/homebrew/lib/docker/cli-plugins
    install -d -m 0700 "$docker_dir"

    if [[ ! -e "$config" ]]; then
      temporary="$(mktemp "$docker_dir/.config.json.XXXXXX")"
      trap 'rm -f "$temporary"' EXIT
      printf '%s\n' '{"cliPluginsExtraDirs":["/opt/homebrew/lib/docker/cli-plugins"]}' > "$temporary"
      chmod 0600 "$temporary"
      mv -f "$temporary" "$config"
      trap - EXIT
      exit 0
    fi

    temporary="$(mktemp "$docker_dir/.config.json.XXXXXX")"
    trap 'rm -f "$temporary"' EXIT
    cp "$config" "$temporary"
    /usr/bin/plutil -convert binary1 "$temporary"
    key_type="$(/usr/bin/plutil -type cliPluginsExtraDirs "$temporary" 2>/dev/null || true)"
    if [[ -n "$key_type" && "$key_type" != array ]]; then
      printf '%s\n' 'Docker config cliPluginsExtraDirs must be an array.' >&2
      exit 1
    fi

    if [[ -z "$key_type" ]]; then
      /usr/bin/plutil -insert cliPluginsExtraDirs -json '["/opt/homebrew/lib/docker/cli-plugins"]' "$temporary"
    else
      count="$(/usr/bin/plutil -extract cliPluginsExtraDirs raw -o - "$temporary")"
      found=0
      for (( index=0; index<count; index++ )); do
        value="$(/usr/bin/plutil -extract "cliPluginsExtraDirs.$index" raw -o - "$temporary")"
        if [[ "$value" == "$plugin_dir" ]]; then
          found=1
          break
        fi
      done
      if [[ "$found" != 1 ]]; then
        /usr/bin/plutil -insert "cliPluginsExtraDirs.$count" -string "$plugin_dir" "$temporary"
      fi
    fi

    /usr/bin/plutil -convert json "$temporary"
    chmod 0600 "$temporary"
    mv -f "$temporary" "$config"
    trap - EXIT
    """#

    static let installScript = packageInstallScript + "\n" + configurationScript
}
