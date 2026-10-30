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

@test "a call in a pipe leaves the progress line of rsync out" {
  # Arrange: run hands frsync a pipe as its stdout, where a redrawn line is noise.

  # Act
  run frsync 'source' 'target'

  # Assert
  assert_success
  assert_output_lacks '--info=progress2'
}

@test "a call on a terminal hands the progress line on to rsync" {
  # Arrange: the script of util-linux gives frsync a terminal as its stdout.
  local script_version=''
  # Without script, the call fails, and the test skips below.
  script_version="$(script --version 2>/dev/null)" || true

  if [[ "${script_version}" != *'util-linux'* ]]; then
    skip 'needs the script of util-linux'
  fi

  # Act
  run script -qec "bash ${PROGRAM@Q} source target" /dev/null

  # Assert
  assert_success
  assert_output_contains '--info=progress2'
}

@test "-R --info=progress2 keeps the progress line in a pipe" {
  # Arrange: the option asks for the line, as for a log that a person reads in a terminal.

  # Act
  run frsync -R '--info=progress2' 'source' 'target'

  # Assert
  assert_success
  assert_output_contains $'\n--info=progress2\n'
}

# endregion The command of rsync

### End
