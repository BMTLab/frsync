#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

setup() {
  source ./.frsync.sh
}

@test 'Display help message with -h option' {
  ## Act
  run frsync -h

  ## Assert
  assert_success
  assert_output --partial 'Usage: frsync'
}

@test 'Error with invalid option' {
  ## Act
  run frsync -z

  ## Assert
  assert_failure
  assert_output --partial 'Error: Invalid option'
}

@test 'Error when mandatory arguments are not provided' {
  ## Act
  run frsync

  ## Assert
  assert_failure
  assert_output --partial 'Local and remote host must be specified'
}

@test 'Enable compression with -c option' {
  ## Arrange
  # Mocking `rsync` command to prevent actual execution
  # shellcheck disable=SC2317
  function rsync() {
    echo "rsync called with args: $*"
  }

  export -f rsync

  ## Act
  run frsync -c 'source' 'target'

  ## Assert
  assert_success
  assert_output --partial '-z'
}

@test 'Specify private key with -i option' {
  ## Arrange
  # Mocking `rsync` command to prevent actual execution
  # shellcheck disable=SC2317
  function rsync() {
    echo "rsync called with args: $*"
  }

  export -f rsync

  ## Act
  run frsync -i '/path/to/key' 'source' 'target'

  ## Assert
  assert_success
  assert_output --partial '-i /path/to/key'
}

teardown() {
  unset -f rsync
}
