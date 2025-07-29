# aws

Additional workarounds, ad-hoc scripts, and various tools to compensate for my inadequacy as an AWS admin.

## Contents

### `aws-regions`

Supporting script used by the EBS scripts below. Returns the list of currently available AWS regions.

---

### `aws-ebs-list`

Lists EBS Volumes and Snapshots in:

- CSV format (for automation)
- Human-readable format (for interactive review)

Supports single region or all regions.

---

### `aws-ebs-delete`

Deletes orphaned (unused) EBS Volumes or Snapshots.

Usage:
- Delete by specific Volume or Snapshot ID
- Delete all in a specific region
- Delete all across all available regions

Safe checks included to prevent deleting in-use volumes or incomplete snapshots.

---

### `aws-generate-mfa-token`

Personal workaround for generating temporary AWS credentials using MFA.

- Reads `~/.aws/config` to find the MFA serial device
- Uses `aws sts get-session-token`
- Creates a new `*-mfa` profile in `~/.aws/credentials`
- Optional autocomplete support for ZSH

---

### `aws-generate-mfa-token.zsh_completion`

ZSH tab-completion script for use with `aws-generate-mfa-token`.

- Pulls profile names from `~/.aws/config`
- Auto-completes `aws-generate-mfa-token <profile>`

Place it in your `$fpath` or source it in `.zshrc`.

---

### `dummy_app_read_write-install.sh`

Creates two dummy `systemd` services that continuously write to separate filesystems.

Useful for testing:

- EC2 EBS volumes
- Filesystem behavior
- Any use case where you need persistent write activity from a running process

The services simulate continuous file writes without interruption.

---

## Requirements

- Bash 4+
- `awscli` v2+
- `jq`

Ensure your environment includes a properly configured `~/.aws/config` and `~/.aws/credentials`.

---

## Disclaimer

These tools are created for personal or internal use only. Use at your own risk. No warranties.

