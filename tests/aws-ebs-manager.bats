#!/usr/bin/env bats

@test "Show help" {
  run ./aws-ebs-manager.sh help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "Missing parameters should return error" {
  run ./aws-ebs-manager.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"Missing parameters"* ]]
}

