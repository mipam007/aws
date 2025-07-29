#!/usr/bin/env bash
# aws-ebs-manager.sh
#
# Description:
#   Unified script to list or delete AWS EBS volumes and snapshots across regions.
#   Filters unused resources safely, supports CSV and human-readable output.
#
# Usage:
#   List volumes:
#     ./aws-ebs-manager.sh list volumes human all
#     ./aws-ebs-manager.sh list volumes csv eu-west-1
#
#   List snapshots:
#     ./aws-ebs-manager.sh list snapshots human all
#     ./aws-ebs-manager.sh list snapshots csv eu-central-1
#
#   Delete unused volumes:
#     ./aws-ebs-manager.sh delete volumes all
#     ./aws-ebs-manager.sh delete volumes eu-west-1
#
#   Delete a specific volume:
#     ./aws-ebs-manager.sh delete volumes eu-west-1 vol-0123abcd
#
#   Delete completed snapshots:
#     ./aws-ebs-manager.sh delete snapshots all
#     ./aws-ebs-manager.sh delete snapshots eu-central-1
#
#   Delete a specific snapshot:
#     ./aws-ebs-manager.sh delete snapshots eu-central-1 snap-0abc1234
#
#   Help:
#     ./aws-ebs-manager.sh help
#
# Notes:
#   - Will NOT delete in-use volumes or pending/incomplete snapshots.
#   - Always test with `list` before using `delete`.
#   - Tags are included in CSV output as `Key=Value;...`


# exit with error in case of command failure or undefine variable, sorry for strict-mode bash abuse
set -euo pipefail

# safer field separator with newline and tabs (no spaces)
IFS=$'\n\t'

# log file
LOGFILE="ebs-manager-$(date +%F).log"

# redirecting all stdout/err output to terminal and append to logfile also
exec > >(tee -a "$LOGFILE") 2>&1


## functions
# jq tests
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not found. Install it." >&2
  exit 1
fi

# Sorry for the bash fascism
if [ -z "$BASH_VERSION" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  else
    echo "This script requires bash, but it's not installed." >&2
    exit 1
  fi
fi

# based on previous issues with aws cli version, heres the test
function check_cli_version() {
  if ! aws --version &>/dev/null; then
    echo "AWS CLI not found. Please install awscli." >&2
    exit 1
  fi

  CLI_VERSION=$(aws --version 2>&1 | grep -oE 'aws-cli/[0-9.]+' | cut -d/ -f2)
  CLI_MAJOR=$(echo "$CLI_VERSION" | cut -d. -f1)

  if (( CLI_MAJOR < 2 )); then
    NO_PAGER=""
  else
    NO_PAGER="--no-cli-pager"
  fi

  if ! aws sts get-caller-identity $NO_PAGER &>/dev/null; then
    echo "AWS credentials not valid or expired." >&2
    exit 1
  fi
}


function usage() {
cat <<'EOF'
aws-ebs-manager.sh

Description:
  Unified script to list or delete AWS EBS volumes and snapshots across regions.
  Filters unused resources safely, supports CSV and human-readable output.

Usage:
  List volumes:
    ./aws-ebs-manager.sh list volumes human all
    ./aws-ebs-manager.sh list volumes csv eu-west-1

  List snapshots:
    ./aws-ebs-manager.sh list snapshots human all
    ./aws-ebs-manager.sh list snapshots csv eu-central-1

  Delete unused volumes:
    ./aws-ebs-manager.sh delete volumes all
    ./aws-ebs-manager.sh delete volumes eu-west-1

  Delete a specific volume:
    ./aws-ebs-manager.sh delete volumes eu-west-1 vol-0123abcd

  Delete completed snapshots:
    ./aws-ebs-manager.sh delete snapshots all
    ./aws-ebs-manager.sh delete snapshots eu-central-1

  Delete a specific snapshot:
    ./aws-ebs-manager.sh delete snapshots eu-central-1 snap-0abc1234

Help:
  ./aws-ebs-manager.sh help

Notes:
  - Will NOT delete in-use volumes or pending/incomplete snapshots.
  - Always test with `list` before using `delete`.
  - Tags are included in CSV output as `Key=Value;...`
EOF
}


function list_volumes() {
  local format="$1"
  local region="$2"

  volumes=$(aws ec2 describe-volumes --region "$region" $NO_PAGER \
    --query 'Volumes[*].[VolumeId,State,Attachments[0].InstanceId,Size,AvailabilityZone,Tags]' \
    --output json)

  if [[ "$format" == "csv" ]]; then
    echo "Region,VolumeId,State,InstanceId,Size,AZ,Tags"
    echo "$volumes" | jq -r \
      --arg region "$region" '
      .[] |
      [
        $region,
        .[0],
        .[1],
        (.[2] // "-"),
        (.[3] | tostring),
        .[4],
        (.[5] // [] | map("\(.Key)=\(.Value)") | join(";"))
      ] | @csv'
  elif [[ "$format" == "human" ]]; then
    echo "$volumes" | jq -c '.[]' | while read -r vol; do
      volume_id=$(echo "$vol" | jq -r '.[0]')
      state=$(echo "$vol" | jq -r '.[1]')
      instance_id=$(echo "$vol" | jq -r '.[2] // "-"')
      size=$(echo "$vol" | jq -r '.[3]')
      tags=$(echo "$vol" | jq -r '.[5] // []')
      name=$(echo "$tags" | jq -r '.[] | select(.Key=="Name") | .Value' 2>/dev/null || echo "-")
      in_use="no"
      [[ "$state" == "in-use" ]] && in_use="yes"

      echo "region:        $region"
      echo "volume ID:     $volume_id"
      echo "name:          $name"
      echo "in use:        $in_use"
      echo "instance ID:   $instance_id"
      echo "size:          $size"
      echo "tags:"
      echo "$tags" | jq -r '.[] | "               \(.Key): \(.Value)"' 2>/dev/null || echo "               -"
      echo
    done
  else
    echo "$volumes" | jq
  fi
}

function list_snapshots() {
  local format="$1"
  local region="$2"

  snapshots=$(aws ec2 describe-snapshots --owner-ids self --region "$region" $NO_PAGER \
    --query 'Snapshots[*].[SnapshotId,VolumeId,State,StartTime,Description,Tags]' \
    --output json)

  if [[ "$format" == "csv" ]]; then
    echo "Region,SnapshotId,VolumeId,State,StartTime,Tags"
    echo "$snapshots" | jq -r \
      --arg region "$region" '
      .[] |
      [
        $region,
        .[0],
        .[1],
        .[2],
        .[3],
        (.[5] // [] | map("\(.Key)=\(.Value)") | join(";"))
--query "Snapshots[      ] | @csv'
  elif [[ "$format" == "human" ]]; then
    echo "$snapshots" | jq -c '.[]' | while read -r snap; do
      snapshot_id=$(echo "$snap" | jq -r '.[0]')
      volume_id=$(echo "$snap" | jq -r '.[1]')
      state=$(echo "$snap" | jq -r '.[2]')
      start_time=$(echo "$snap" | jq -r '.[3]')
      tags=$(echo "$snap" | jq -r '.[5] // []')
      name=$(echo "$tags" | jq -r '.[] | select(.Key=="Name") | .Value' 2>/dev/null || echo "-")

      echo "region:        $region"
      echo "snapshot ID:   $snapshot_id"
      echo "volume ID:     $volume_id"
      echo "name:          $name"
      echo "state:         $state"
      echo "start time:    $start_time"
      echo "tags:"
      echo "$tags" | jq -r '.[] | "               \(.Key): \(.Value)"' 2>/dev/null || echo "               -"
      echo
    done
  else
    echo "$snapshots" | jq
  fi
}


function delete_unused_volumes() {
  local region="$1"

  volumes=$(aws ec2 describe-volumes --region "$region" $NO_PAGER \
    --query "Volumes[?State=='available'].[VolumeId]" --output text)

  for vol in $volumes; do
    echo "Deleting volume: $vol"
    aws ec2 delete-volume --region "$region" --volume-id "$vol" $NO_PAGER
  done
}

function delete_volume() {
  local region="$1"
  local volume_id="$2"

  echo "Deleting volume: $volume_id (region: $region)"
  aws ec2 delete-volume --region "$region" --volume-id "$volume_id" $NO_PAGER
}

function delete_unused_snapshots() {
  local region="$1"

  snapshots=$(aws ec2 describe-snapshots --owner-ids self --region "$region" $NO_PAGER \
    --query "Snapshots[?State=='completed'].[SnapshotId]" --output text)

  for snap in $snapshots; do
    echo "Deleting snapshot: $snap"
    aws ec2 delete-snapshot --region "$region" --snapshot-id "$snap" $NO_PAGER
  done
}

function delete_snapshot() {
  local region="$1"
  local snapshot_id="$2"

  echo "Deleting snapshot: $snapshot_id (region: $region)"
  aws ec2 delete-snapshot --region "$region" --snapshot-id "$snapshot_id" $NO_PAGER
}

# --- MAIN ---

check_cli_version

cmd=${1:-}
target=${2:-}
mode=${3:-}
region=${4:-}

# if 1st param is help, write usage and exit
if [[ "$cmd" == "help" || "$cmd" == "-h" || "$cmd" == "--help" ]]; then
  usage
  exit 0
fi

# list validation
if [[ "$cmd" == "list" ]]; then
  if [[ -z "$target" || -z "$mode" || -z "$region" ]]; then
    echo "Missing parameters. Example: ./aws-ebs-manager.sh list volumes csv all" >&2
    echo "Try './aws-ebs-manager.sh help' for usage." >&2
    exit 1
  fi
fi

# delete validation
if [[ "$cmd" == "delete" ]]; then
  if [[ -z "$target" ]]; then
    echo "Missing parameters. Example: ./aws-ebs-manager.sh delete volumes all" >&2
    echo "Try './aws-ebs-manager.sh help' for usage." >&2
    exit 1
  fi
fi

# unexpected command usafe fallback
if [[ -z "$cmd" ]]; then
  echo "Missing parameters. Example: ./aws-ebs-manager.sh list volumes csv all" >&2
  echo "Try './aws-ebs-manager.sh help' for usage." >&2
  exit 1
fi

function loop_regions() {
  local action="$1"
  local format="$2"
  local printed_header=false

  # get all existing regions
  readarray -t ALL_REGIONS < <(aws --region eu-central-1 ec2 describe-regions \
    --query 'Regions[*].RegionName' --output text --no-cli-pager | tr -s '[:space:]' '\n')

  for reg in "${ALL_REGIONS[@]}"; do
    if ! aws ec2 describe-availability-zones --region "$reg" $NO_PAGER &>/dev/null; then
      echo "Skipping region $reg due to access/auth error." >&2
      continue
    fi

    if [[ "$format" == "csv" && "$printed_header" == true ]]; then
      # Suppress CSV header
      case "$action" in
        list_volumes)
          aws ec2 describe-volumes --region "$reg" $NO_PAGER \
            --query 'Volumes[*].[VolumeId,State,Attachments[0].InstanceId,Size,AvailabilityZone,Tags]' \
            --output json |
          jq -r --arg region "$reg" '
            .[] |
            [
              $region,
              .[0],
              .[1],
              (.[2] // "-"),
              (.[3] | tostring),
              .[4],
              (.[5] // [] | map("\(.Key)=\(.Value)") | join(";"))
            ] | @csv'
          ;;
        list_snapshots)
          aws ec2 describe-snapshots --owner-ids self --region "$reg" $NO_PAGER \
            --query 'Snapshots[*].[SnapshotId,VolumeId,State,StartTime,Description,Tags]' \
            --output json |
          jq -r --arg region "$reg" '
            .[] |
            [
              $region,
              .[0],
              .[1],
              .[2],
              .[3],
              (.[5] // [] | map("\(.Key)=\(.Value)") | join(";"))
            ] | @csv'
          ;;
      esac
    else
      printed_header=true
      case "$action" in
        list_volumes)
          list_volumes "$format" "$reg"
          ;;
        list_snapshots)
          list_snapshots "$format" "$reg"
          ;;
        delete_volumes)
          delete_unused_volumes "$reg"
          ;;
        delete_snapshots)
          delete_unused_snapshots "$reg"
          ;;
      esac
    fi
  done
}


case "$cmd" in
  list)
    if [[ "$target" == "volumes" ]]; then
      if [[ "$region" == "all" ]]; then
        loop_regions "list_volumes" "$mode"
      else
        list_volumes "$mode" "$region"
      fi
    elif [[ "$target" == "snapshots" ]]; then
      if [[ "$region" == "all" ]]; then
        loop_regions "list_snapshots" "$mode"
      else
        list_snapshots "$mode" "$region"
      fi
    else
      echo "Invalid target for list: $target" >&2
      usage
    fi
    ;;

  delete)
    if [[ "$target" == "volumes" ]]; then
      if [[ "$mode" == "all" ]]; then
        loop_regions "delete_volumes" ""
      elif [[ -n "${region:-}" && -n "${4:-}" ]]; then
        delete_volume "$region" "$4"
      else
        delete_unused_volumes "$region"
      fi

    elif [[ "$target" == "snapshots" ]]; then
      if [[ "$mode" == "all" ]]; then
        loop_regions "delete_snapshots" ""
      elif [[ -n "${region:-}" && -n "${4:-}" ]]; then
        delete_snapshot "$region" "$4"
      else
        delete_unused_snapshots "$region"
      fi

    else
      echo "Invalid target for delete: $target" >&2
      usage
    fi
    ;;

  help|-h|--help)
    usage
    ;;

  *)
    echo "Unknown command: $cmd" >&2
    usage
    ;;
esac

