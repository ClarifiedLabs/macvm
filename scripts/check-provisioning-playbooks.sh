#!/bin/bash

set -euo pipefail

if ! command -v ansible-playbook >/dev/null 2>&1; then
    echo "ansible-playbook is required; install it with: brew install ansible" >&2
    exit 1
fi

roots=(
    "Sources/MacVMHostKit/Resources/Provisioning/Profiles"
    "docs/examples/profiles"
    "Tests/ProvisioningProfiles"
)

checked=0
for root in "${roots[@]}"; do
    while IFS= read -r -d '' manifest; do
        directory="$(dirname "$manifest")"
        playbook="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["playbook"])' "$manifest")"
        echo "Checking ${directory}/${playbook}"
        ansible-playbook --syntax-check -i macvm, "${directory}/${playbook}"
        checked=$((checked + 1))
    done < <(find "$root" -name profile.json -type f -print0 | sort -z)
done

echo "Checked ${checked} provisioning playbooks."
