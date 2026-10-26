#!/usr/bin/env bats
# shellcheck shell=bash

# Test frsync.sh: its usage, its failures and the command of rsync that it builds.
#
# Stand-ins take the place of rsync and ssh, so no test copies a file.
# Run the tests with `bats tests`.

bats_require_minimum_version 1.11.0

# shellcheck source=support/test-helper.bash
source "${BATS_TEST_DIRNAME}/support/test-helper.bash"

# region Setup

#######################################
# Source frsync.sh into a scratch home,
# with an rsync and an ssh that print their arguments.
#######################################
function setup() {
  sandbox_setup
  put_fake print-arguments "${FAKE_BIN}/rsync"
  put_fake print-arguments "${FAKE_BIN}/ssh"
  source_frsync
}

# endregion Setup

# region Usage and failures

@test "-h prints the usage and succeeds" {
  # Arrange: setup sources frsync.sh, which is all that -h needs.

  # Act
  run frsync -h

  # Assert
  assert_success
  assert_output_contains $'Usage:\n  frsync [-h]'
}

@test "an unknown option fails with FRSYNC_ERR_INVALID_OPTIONS and names the option" {
  # Arrange: frsync has no option -z.

  # Act
  run frsync -z

  # Assert
  assert_failure "${FRSYNC_ERR_INVALID_OPTIONS}"
  assert_output_contains 'Error: Invalid option: -z.'
}

@test "a call without a source and a destination fails with FRSYNC_ERR_PATHS_NOT_SPECIFIED" {
  # Arrange: the call names no path.

  # Act
  run frsync

  # Assert
  assert_failure "${FRSYNC_ERR_PATHS_NOT_SPECIFIED}"
  assert_output_contains 'Error: Source path(s) and destination must be specified.'
}

# endregion Usage and failures

# region The command of rsync

@test "-c compresses with -z where rsync names no zstd" {
  # Arrange: the rsync of setup prints only --version when frsync asks for its version.

  # Act
  run frsync -c 'source' 'target'

  # Assert
  assert_success
  assert_output_contains $'\n-z\n'
}

@test "-i hands the private key to ssh" {
  # Arrange: the rsync of setup prints its arguments, the command of ssh among them.

  # Act
  run frsync -i '/path/to/key' 'source' 'target'

  # Assert
  assert_success
  assert_output_contains ' -i /path/to/key '
}

# endregion The command of rsync

### End
