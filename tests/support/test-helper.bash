# shellcheck shell=bash
# shellcheck disable=SC2034 # The tests read the paths and the folders of the sandbox.

# Give each test of frsync a scratch home, stand-ins for the programs it runs,
# frsync.sh with the defaults of its settings, and assertions on a run.
#
# Every test file sources it under a `# shellcheck source=` line, rather than with `load`,
# so that ShellCheck follows it into frsync.sh and sees what the tests read.

# region Paths

REPOSITORY_ROOT="$(readlink -f -- "${BASH_SOURCE[0]%/*}/../..")"
readonly REPOSITORY_ROOT
readonly SUPPORT_DIRECTORY="${REPOSITORY_ROOT}/tests/support"
readonly PROGRAM="${REPOSITORY_ROOT}/frsync.sh"

# endregion Paths

# region Sandbox

#######################################
# Give the test a home, the folders of XDG, a TMPDIR and a folder of stand-ins
# of its own, so that no test reaches the files of the user,
# such as the ~/.ssh/known_hosts that frsync names to ssh.
#
# Globals:
#   FAKE_HOME: Set to the scratch home, which HOME names too.
#   FAKE_BIN: Set to an empty folder for stand-ins, which comes first on PATH.
#   HOME, XDG_CONFIG_HOME, XDG_CACHE_HOME, XDG_DATA_HOME, XDG_STATE_HOME,
#   XDG_RUNTIME_DIR, TMPDIR, PATH: Exported for the scratch home.
#   GIT_CONFIG_GLOBAL, GIT_CONFIG_NOSYSTEM: Exported, so that git reads no config.
#######################################
function sandbox_setup() {
  FAKE_HOME="${BATS_TEST_TMPDIR}/home"
  FAKE_BIN="${BATS_TEST_TMPDIR}/bin"
  export HOME="${FAKE_HOME}"
  # A program that reads a folder of XDG from the environment stays in the home too.
  export XDG_CONFIG_HOME="${FAKE_HOME}/.config"
  export XDG_CACHE_HOME="${FAKE_HOME}/.cache"
  export XDG_DATA_HOME="${FAKE_HOME}/.local/share"
  export XDG_STATE_HOME="${FAKE_HOME}/.local/state"
  # The runtime folder lies outside the home, as /run/user/UID does.
  export XDG_RUNTIME_DIR="${BATS_TEST_TMPDIR}/run"
  export TMPDIR="${BATS_TEST_TMPDIR}"
  export PATH="${FAKE_BIN}:${PATH}"
  # GIT_CONFIG_GLOBAL wins over HOME, where the environment of the user sets it.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

  mkdir -p -- "${FAKE_HOME}" "${FAKE_BIN}"
  # A session has its runtime folder from the start, and only its user may enter it.
  mkdir -m 0700 -- "${XDG_RUNTIME_DIR}"
}

#######################################
# Put a stand-in of support/bin at a path, under the name of the program it stands in for.
#
# Arguments:
#   1: The stand-in, such as print-arguments.
#   2: Its path, such as ${FAKE_BIN}/rsync.
#######################################
function put_fake() {
  local -r fake="$1"
  local -r path="$2"

  mkdir -p -- "${path%/*}"
  cp -- "${SUPPORT_DIRECTORY}/bin/${fake}" "${path}"
}

# endregion Sandbox

# region Program under test

#######################################
# Source frsync.sh for its function and constants, with the defaults of its settings,
# then turn on the options of its guard, so that frsync runs as it does for real.
#
# Globals:
#   FRSYNC_*: Unset before the source, since a setting that the shell
#     of the user exports would take the place of a default.
#######################################
function source_frsync() {
  unset "${!FRSYNC_@}"

  # shellcheck source=../../frsync.sh
  source "${PROGRAM}"
  set -o nounset -o pipefail
}

# endregion Program under test

# region Assertions

#######################################
# Assert that the last run succeeded.
#
# Globals:
#   status: The status of the last run.
#######################################
function assert_success() {
  if ((status != 0)); then
    fail_with_report "expected success, got status ${status}"
  fi
}

#######################################
# Assert that the last run failed with a given status.
#
# Arguments:
#   1: The status, such as ${FRSYNC_ERR_INVALID_OPTIONS}.
#
# Globals:
#   status: The status of the last run.
#######################################
function assert_failure() {
  local -ir expected="$1"

  if ((status != expected)); then
    fail_with_report "expected status ${expected}, got ${status}"
  fi
}

#######################################
# Assert that the output of the last run contains a fragment.
#
# Arguments:
#   1: The fragment, which may span lines.
#
# Globals:
#   output: The output of the last run, its stderr included.
#######################################
function assert_output_contains() {
  local -r fragment="$1"

  if [[ "${output}" != *"${fragment}"* ]]; then
    fail_with_report "output lacks: ${fragment}"
  fi
}

#######################################
# Report a failed assertion with the whole run, and fail the test.
#
# Arguments:
#   1: What went wrong.
#
# Globals:
#   status, output: The status and the output of the last run.
#
# Outputs:
#   The report to stderr, which bats shows for a failed test.
#
# Returns:
#   1, always.
#######################################
function fail_with_report() {
  local -r message="$1"

  {
    printf -- '-- %s --\n' "${message}"
    printf 'status: %s\n' "${status}"
    printf 'output:\n%s\n' "${output}"
    printf -- '--\n'
  } >&2

  return 1
}

# endregion Assertions

### End
