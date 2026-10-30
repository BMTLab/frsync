#!/bin/bash
# bashsupport disable=BP5006

# Name: frsync.sh
# Author: Nikita Neverov (BMTLab)
# Version: 3.2.0
# Date: 2025-11-22
# License: MIT
#
# Description:
#   Convenience wrapper around rsync over SSH for fast,
#   tuned file sync from local to remote
#   (or vice versa, depending on how you call rsync).
#
#   The goal is to provide a sensible, batteries-included rsync/SSH setup
#   with good defaults for day-to-day development and backup workflows,
#   while still allowing you to override behavior via CLI flags
#   and FRSYNC_* environment variables.
#
#   Features:
#     - Sensible, feature-rich default rsync option set
#       (archive, hard-links, ACLs, xattrs, numeric-ids, human-readable,
#        progress display on a terminal, etc.).
#     - Optional rsync compression (zstd / lz4 / zlib, auto-detected).
#     - Custom SSH private key selection.
#     - SSH connection multiplexing (ControlMaster/ControlPath) by default.
#     - Optional --delete to mirror source -> destination.
#     - Optional --whole-file for high-bandwidth / low-latency links.
#     - Optional --dry-run for safe preview of changes.
#     - Optional "unsafe" SSH options for trusted networks:
#         * disables strict SSH host key checking;
#         * adds rsync --trust-sender (trust remote sender’s metadata).
#     - Raw passthrough of rsync options via -R (can override base options).
#     - CLI override -B to ignore FRSYNC_RSYNC_BASE_OPTS for a single run.
#     - Behavior tunable via FRSYNC_* environment variables.
#
# Disclaimer:
#   This script is provided "as is", without any warranty or guarantee of
#   correctness, performance, or fitness for a particular purpose.
#   Always verify dry-run output (-n) and test on non-critical data
#   before using it in production or for important backups.

# Usage:
#   frsync [-h] [-c] [-w] [-n] [-B] [-R rsync_opt] \
#          [-i private_key] [-m] [-d] [-u] \
#          <source_path1> [<source_path2> ...] <destination_path>
#
#   Examples:
#     frsync ./dist user@10.0.0.10:/srv/www
#     frsync -cd ./src user@example.com:/backup/src
#     frsync -cw ./data user@host:/ssd/backup
#     frsync -i ~/.ssh/id_ed25519 ./data user@host:/data
#     frsync -R '--exclude=*.log' ./data user@host:/data
#     frsync -B -R '-a' -R '--delete' ./src user@host:/srv/src
#     # Download example (reverse sync):
#     frsync user@host:/remote/data ./local_dir
#
# Options:
#   -h      Show help and exit.
#   -c      Enable rsync compression (zstd/lz4/zlib depending on support).
#   -w      Use --whole-file (no delta algorithm, good on fast links).
#   -n      Dry-run: add --dry-run and print the final rsync command
#           without actually transferring or modifying files.
#   -B      Ignore FRSYNC_RSYNC_BASE_OPTS for this run (start with an
#           empty rsync option set and build from -R / flags).
#   -R OPT  Pass a raw rsync option/token through to rsync.
#           May be specified multiple times. Each -R adds one token
#           (no further splitting), appended after base options
#           (unless -B is used) but before script-controlled flags
#           (compression/delete/whole-file/dry-run/trust-sender),
#           so they can override base options but not explicit flags.
#   -i KEY  Use the given SSH private key for authentication.
#   -m      Disable SSH multiplexing (ControlMaster / ControlPath).
#   -d      Pass --delete to rsync (destination mirrors source).
#   -u      Enable unsafe mode:
#             * SSH: skip host key checks (StrictHostKeyChecking=no,
#               UserKnownHostsFile=/dev/null).
#             * rsync: add --trust-sender.
#
# Environment (defaults can be overridden via export before calling frsync):
#   FRSYNC_RSYNC_BIN
#     rsync binary to use. Default: "rsync".
#
#   FRSYNC_RSYNC_BASE_OPTS
#     Base rsync options that form the initial option set before dynamic flags
#     (compression, delete, whole-file, dry-run, trust-sender) are added.
#     This string is tokenized by the shell (word-splitting),
#     so it may contain multiple options separated by spaces/newlines.
#     frsync leaves --info=progress2 out when stdout is not a terminal,
#     since rsync redraws that line with \r; -R --info=progress2 keeps it.
#     Other progress options of your own, such as --progress or -P, stay.
#
#     Default (pretty-printed here, but stored as a single string):
#       --archive
#       --hard-links
#       --acls
#       --xattrs
#       --one-file-system
#       --recursive
#       --executability
#       --numeric-ids
#       --partial
#       --inplace
#       --human-readable
#       --info=progress2
#       --verbose
#
#     Set to an empty string to start from a minimal base and build up
#     everything via other knobs. You can also use -B to ignore this value
#     for a single invocation.
#
#   FRSYNC_SSH_BIN
#     ssh binary to use. Default: "ssh".
#
#   FRSYNC_SSH_CIPHER
#     SSH cipher string. Default: "chacha20-poly1305@openssh.com".
#
#   FRSYNC_SSH_CONTROL_MASTER
#     Value for ControlMaster when multiplexing is enabled.
#     Default: "auto".
#
#   FRSYNC_SSH_CONTROL_PATH
#     ControlPath template for SSH multiplexing.
#     Default: "/tmp/frsync-%r@%h:%p".
#
#   FRSYNC_SSH_STRICT_HOST_KEY_CHECKING
#     Default StrictHostKeyChecking value when *not* using -u.
#     Default: "yes".
#
#   FRSYNC_SSH_KNOWN_HOSTS_FILE
#     Default UserKnownHostsFile path when *not* using -u.
#     Default: "$HOME/.ssh/known_hosts".
#
#   FRSYNC_SSH_FORWARD_X11
#     Default ForwardX11 setting.
#     Default: "no".
#
#   FRSYNC_COMPRESSION_CHOICE
#     Compression choice for rsync when -c is enabled.
#     Supported values:
#       "auto" (default) – prefer zstd if supported, else zlib (-z).
#       "none" or ""     – disable compression even if -c is given.
#       "zstd", "zlib", "lz4", or any algorithm that rsync advertises.
#     If you specify a custom value and rsync does not support it,
#     the script falls back to the "auto" behavior.
#
#   FRSYNC_COMPRESSION_LEVEL
#     Compression level for modern algorithms (zstd, lz4, etc.).
#     Used with --compress-level=<level>. Default: "6".
#
# Exit Codes:
#   0:   Success (rsync completed with exit code 0).
#   101: FRSYNC_ERR_INVALID_OPTIONS
#        Invalid CLI arguments/options or missing required arguments.
#   102: FRSYNC_ERR_MISSING_RSYNC_BIN
#        rsync binary not found or not executable.
#   103: FRSYNC_ERR_MISSING_SSH_BIN
#        ssh binary not found or not executable.
#   104: FRSYNC_ERR_PATHS_NOT_SPECIFIED
#        Source path(s) and/or destination path were not provided.
#   Other non-zero: rsync exit code on transfer failure.

# Detect whether script is sourced or executed
# bashsupport disable=BP5001
if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
  if [[ ${FRSYNC_SCRIPT_SOURCED-} != true ]]; then
    readonly FRSYNC_SCRIPT_SOURCED=true
  fi
else
  readonly FRSYNC_SCRIPT_SOURCED=false
  set -o errexit -o nounset -o pipefail
fi

# Error codes (readonly; safe for repeated sourcing)
if [[ -z ${FRSYNC_ERR_INVALID_OPTIONS+x} ]]; then
  readonly FRSYNC_ERR_INVALID_OPTIONS=101
fi
if [[ -z ${FRSYNC_ERR_MISSING_RSYNC_BIN+x} ]]; then
  readonly FRSYNC_ERR_MISSING_RSYNC_BIN=102
fi
if [[ -z ${FRSYNC_ERR_MISSING_SSH_BIN+x} ]]; then
  readonly FRSYNC_ERR_MISSING_SSH_BIN=103
fi
if [[ -z ${FRSYNC_ERR_PATHS_NOT_SPECIFIED+x} ]]; then
  readonly FRSYNC_ERR_PATHS_NOT_SPECIFIED=104
fi

# Environment defaults (can be overridden by exporting FRSYNC_* before call)
: "${FRSYNC_RSYNC_BIN:=rsync}"
: "${FRSYNC_RSYNC_BASE_OPTS:="
--archive
--hard-links
--acls
--xattrs
--one-file-system
--recursive
--executability
--numeric-ids
--partial
--inplace
--human-readable
--info=progress2
--verbose
"}"
: "${FRSYNC_SSH_BIN:=ssh}"
: "${FRSYNC_SSH_CIPHER:=chacha20-poly1305@openssh.com}"
: "${FRSYNC_SSH_CONTROL_MASTER:=auto}"
: "${FRSYNC_SSH_CONTROL_PATH:=/tmp/frsync-%r@%h:%p}"
: "${FRSYNC_SSH_STRICT_HOST_KEY_CHECKING:=yes}"
: "${FRSYNC_SSH_KNOWN_HOSTS_FILE:=${HOME}/.ssh/known_hosts}"
: "${FRSYNC_SSH_FORWARD_X11:=no}"
: "${FRSYNC_COMPRESSION_CHOICE:=auto}"
: "${FRSYNC_COMPRESSION_LEVEL:=6}"

#######################################
# Print help/usage text.
#
# Outputs:
#   Usage and options description to stdout,
#   followed by the current effective FRSYNC_* environment snapshot.
#######################################
function __frsync_usage() {
  cat << 'EOF'
frsync - opinionated rsync-over-SSH convenience wrapper

Description:
  frsync wraps rsync + ssh with tuned defaults for fast, reasonably safe
  file synchronization between local and remote hosts. It aims to be:
    - convenient for day-to-day development and backup workflows;
    - explicit about what it does via verbose flags and dry-run mode;
    - configurable via a small set of environment variables.

Usage:
  frsync [-h] [-c] [-w] [-n] [-B] [-R rsync_opt] [-i private_key] [-m] [-d] [-u] \
    <source_path1> [<source_path2> ...] <destination_path>

Options:
  -h  Show this help message (including current FRSYNC_* environment) and exit.
  -c  Enable rsync compression (algorithm tunable via FRSYNC_COMPRESSION_CHOICE).
  -w  Use --whole-file (no delta algorithm, better on fast links).
  -n  Dry-run: add --dry-run and print the final rsync command.
  -B  Ignore FRSYNC_RSYNC_BASE_OPTS for this run
      (start from empty rsync option set, then apply -R / flags).
  -R  Pass a raw rsync option/token (can be used multiple times).
  -i  Path to SSH private key for authentication.
  -m  Disable SSH multiplexing (ControlMaster / ControlPath).
  -d  Enable rsync --delete on the receiving side.
  -u  Enable "unsafe" SSH/rsync options
      (skip host key checks, add rsync --trust-sender; trusted networks only).

Environment:
  See "FRSYNC_*" variables documented in the script header
  for fine-grained control of rsync/SSH defaults.

Disclaimer:
  This tool is provided “as is”, without warranty of any kind.
  Always use -n (dry run) first and verify the printed command before
  running frsync on important or irreplaceable data.

Current effective FRSYNC_* environment:
EOF

  # Compute a readable, single-line view of FRSYNC_RSYNC_BASE_OPTS
  # without printf '%q' escapes. We normalize newlines/tabs to spaces.
  local base_opts_display="${FRSYNC_RSYNC_BASE_OPTS-}"
  base_opts_display=${base_opts_display//$'\n'/ }
  base_opts_display=${base_opts_display//$'\t'/ }
  base_opts_display=${base_opts_display## }
  base_opts_display=${base_opts_display%% }

  printf '  FRSYNC_RSYNC_BIN=%q\n' "${FRSYNC_RSYNC_BIN-}"
  printf '  FRSYNC_RSYNC_BASE_OPTS=%s\n' "${base_opts_display}"
  printf '\n'
  printf '  FRSYNC_SSH_BIN=%q\n' "${FRSYNC_SSH_BIN-}"
  printf '  FRSYNC_SSH_CIPHER=%q\n' "${FRSYNC_SSH_CIPHER-}"
  printf '  FRSYNC_SSH_CONTROL_MASTER=%q\n' "${FRSYNC_SSH_CONTROL_MASTER-}"
  printf '  FRSYNC_SSH_CONTROL_PATH=%q\n' "${FRSYNC_SSH_CONTROL_PATH-}"
  printf '  FRSYNC_SSH_STRICT_HOST_KEY_CHECKING=%q\n' \
    "${FRSYNC_SSH_STRICT_HOST_KEY_CHECKING-}"
  printf '  FRSYNC_SSH_KNOWN_HOSTS_FILE=%q\n' "${FRSYNC_SSH_KNOWN_HOSTS_FILE-}"
  printf '  FRSYNC_SSH_FORWARD_X11=%q\n' "${FRSYNC_SSH_FORWARD_X11-}"
  printf '\n'
  printf '  FRSYNC_COMPRESSION_CHOICE=%q\n' "${FRSYNC_COMPRESSION_CHOICE-}"
  printf '  FRSYNC_COMPRESSION_LEVEL=%q\n' "${FRSYNC_COMPRESSION_LEVEL-}"
}

#######################################
# Print error message, usage and return an error code.
#
# Arguments:
#   1: Error message (string).
#   2: Error code to return.
#
# Outputs:
#   Error text and usage to stderr/stdout.
#
# Returns:
#   Error code passed in $2.
#######################################
function __frsync_error() {
  local -r message="$1"
  local -ir code="$2"

  printf 'Error: %s.\n\n' "$message" >&2
  __frsync_usage

  return "$code"
}

#######################################
# Ensure that a required external binary is available.
#
# Arguments:
#   1: Binary name or path (e.g. "$FRSYNC_RSYNC_BIN").
#   2: Error code to use if binary is missing.
#   3: Human-readable label ("rsync" | "ssh" | etc.).
#
# Returns:
#   0: Binary found in PATH.
#   <code>: Provided error code if not found.
#######################################
function __frsync_ensure_binary() {
  local -r binary_path="$1"
  local -ir error_code="$2"
  local -r binary_label="$3"

  if ! command -v "$binary_path" > /dev/null 2>&1; then
    __frsync_error \
      "$binary_label binary not found or not executable: '$binary_path'" \
      "$error_code" \
      || return "$?"
  fi

  return 0
}

#######################################
# Check whether the configured rsync supports a given compression algorithm.
#
# Implementation details:
#   - Verifies that "$FRSYNC_RSYNC_BIN" is available in PATH.
#   - Greps `$FRSYNC_RSYNC_BIN --version` output for the requested token
#     (e.g. "zstd", "lz4").
#
# Globals:
#   FRSYNC_RSYNC_BIN
#
# Arguments:
#   1: Algorithm name (e.g. 'zstd', 'lz4').
#
# Returns:
#   0: Algorithm appears to be supported.
#   1: Algorithm not supported or rsync not available.
#######################################
function __frsync_rsync_supports_compression_algo() {
  local -r algorithm_name="$1"

  if ! command -v "$FRSYNC_RSYNC_BIN" > /dev/null 2>&1; then
    return 1
  fi

  if [[ -z $algorithm_name || $algorithm_name == 'none' ]]; then
    return 1
  fi

  if "$FRSYNC_RSYNC_BIN" --version 2> /dev/null \
    | grep -qi "$algorithm_name"; then
    return 0
  fi

  return 1
}

#######################################
# Build rsync options array according to flags and environment.
#
# This function initializes and fills the target array (via nameref)
# with:
#   - Base options from FRSYNC_RSYNC_BASE_OPTS (tokenized by shell),
#     unless disabled via -B.
#   - Raw user-provided rsync options from -R (array).
#   - --delete when enabled.
#   - Compression options (controlled by -c and FRSYNC_COMPRESSION_CHOICE/LEVEL).
#   - --whole-file when enabled.
#   - --dry-run when enabled.
#   - --trust-sender when unsafe options are enabled (-u).
#
# Globals:
#   FRSYNC_RSYNC_BASE_OPTS
#   FRSYNC_COMPRESSION_CHOICE
#   FRSYNC_COMPRESSION_LEVEL
#   FRSYNC_RSYNC_BIN
#
# Arguments:
#   1: Name of output array variable (nameref).
#   2: Name of array with raw rsync options (-R) (nameref).
#   3: should_disable_base_opts (true|false).
#   4: should_enable_compression (true|false).
#   5: should_enable_whole_file (true|false).
#   6: should_enable_delete (true|false).
#   7: should_enable_dry_run (true|false).
#   8: should_enable_trust_sender (true|false).
#######################################
function __frsync_build_rsync_options() {
  local -n _final_rsync_options="$1"
  local -n _user_raw_rsync_options="$2"
  local -r should_disable_base_opts="$3"
  local -r should_enable_compression="$4"
  local -r should_enable_whole_file="$5"
  local -r should_enable_delete="$6"
  local -r should_enable_dry_run="$7"
  local -r should_enable_trust_sender="$8"

  _final_rsync_options=()

  # Base options from environment (may contain multiple tokens),
  # unless explicitly disabled via -B.
  # If user sets FRSYNC_RSYNC_BASE_OPTS to empty string, we start from empty.
  if [[ $should_disable_base_opts != true && -n ${FRSYNC_RSYNC_BASE_OPTS:-} ]]; then
    # Using default IFS to split base options (expected behavior)
    # shellcheck disable=SC2206
    local -a _frsync_base_tokens=($FRSYNC_RSYNC_BASE_OPTS)
    local base_token

    for base_token in "${_frsync_base_tokens[@]}"; do
      # rsync redraws its progress line with \r, which only a terminal
      # shows as one line: a pipe or a log would get every redraw.
      # -R --info=progress2 still asks for the line anywhere.
      if [[ "${base_token}" == '--info=progress2' && ! -t 1 ]]; then
        continue
      fi

      _final_rsync_options+=("${base_token}")
    done
  fi

  # Raw rsync options provided via -R (each element is passed as-is).
  # Note: each -R corresponds to a single token; there is no further splitting.
  if [[ ${#_user_raw_rsync_options[@]} -gt 0 ]]; then
    _final_rsync_options+=("${_user_raw_rsync_options[@]}")
  fi

  if [[ $should_enable_delete == true ]]; then
    _final_rsync_options+=('--delete')
  fi

  # Compression handling: controlled by -c plus FRSYNC_COMPRESSION_CHOICE
  if [[ $should_enable_compression == true ]]; then
    case "${FRSYNC_COMPRESSION_CHOICE:-auto}" in
      auto)
        if __frsync_rsync_supports_compression_algo 'zstd'; then
          _final_rsync_options+=(
            '--compress'
            '--compress-choice=zstd'
            "--compress-level=${FRSYNC_COMPRESSION_LEVEL}"
          )
        else
          _final_rsync_options+=('-z')
        fi
        ;;
      none | '')
        # User explicitly disabled compression
        ;;
      zlib)
        _final_rsync_options+=('-z')
        ;;
      *)
        # Custom choice (e.g. "lz4", "zstd", or any algorithm rsync knows)
        if __frsync_rsync_supports_compression_algo \
          "$FRSYNC_COMPRESSION_CHOICE"; then
          _final_rsync_options+=(
            '--compress'
            "--compress-choice=${FRSYNC_COMPRESSION_CHOICE}"
            "--compress-level=${FRSYNC_COMPRESSION_LEVEL}"
          )
        else
          # Fallback to "auto" behavior if custom choice is unsupported
          if __frsync_rsync_supports_compression_algo 'zstd'; then
            _final_rsync_options+=(
              '--compress'
              '--compress-choice=zstd'
              "--compress-level=${FRSYNC_COMPRESSION_LEVEL}"
            )
          else
            _final_rsync_options+=('-z')
          fi
        fi
        ;;
    esac
  fi

  if [[ $should_enable_whole_file == true ]]; then
    # Disable delta algorithm, send/receive whole files.
    # Good for high-bandwidth / low-latency links or when CPU is the bottleneck.
    _final_rsync_options+=('--whole-file')
  fi

  if [[ $should_enable_dry_run == true ]]; then
    # Do not actually modify anything; useful for inspection.
    _final_rsync_options+=('--dry-run')
  fi

  if [[ $should_enable_trust_sender == true ]]; then
    # Trust sender's metadata (owner, group, etc.): unsafe on untrusted hosts
    _final_rsync_options+=('--trust-sender')
  fi
}

#######################################
# Build SSH options array according to flags and environment.
#
# This function initializes and fills the target array (via nameref)
# with SSH baseline options plus:
#   - cipher from FRSYNC_SSH_CIPHER;
#   - StrictHostKeyChecking/UserKnownHostsFile defaults;
#   - identity file (-i) when provided;
#   - ControlMaster/ControlPath when multiplexing is enabled;
#   - overridden host key options when -u (unsafe) is enabled;
#   - ForwardX11 from FRSYNC_SSH_FORWARD_X11;
#   - optional '-v' for ssh when dry-run is enabled (for diagnostics).
#
# Globals:
#   FRSYNC_SSH_CIPHER
#   FRSYNC_SSH_CONTROL_MASTER
#   FRSYNC_SSH_CONTROL_PATH
#   FRSYNC_SSH_STRICT_HOST_KEY_CHECKING
#   FRSYNC_SSH_KNOWN_HOSTS_FILE
#   FRSYNC_SSH_FORWARD_X11
#
# Arguments:
#   1: Name of output array variable (nameref).
#   2: should_disable_multiplexing (true|false).
#   3: should_enable_unsafe (true|false).
#   4: is_ssh_key_provided (true|false).
#   5: ssh_key_path (string; path to key).
#   6: should_enable_dry_run (true|false).
#
# Outputs:
#   Populates the referenced array with SSH options.
#######################################
function __frsync_build_ssh_options() {
  # Name reference to the caller-provided array.
  # ShellCheck cannot infer that this is an array,
  # so SC2178 is a false positive.
  # shellcheck disable=SC2178
  local -n _final_ssh_options="$1"
  local -r should_disable_multiplexing="$2"
  local -r should_enable_unsafe="$3"
  local -r is_ssh_key_provided="$4"
  local -r ssh_key_path="$5"
  local -r should_enable_dry_run="$6"

  _final_ssh_options=(
    '-T'
    '-c' "$FRSYNC_SSH_CIPHER"
    '-o' "StrictHostKeyChecking=${FRSYNC_SSH_STRICT_HOST_KEY_CHECKING}"
    '-o' "UserKnownHostsFile=${FRSYNC_SSH_KNOWN_HOSTS_FILE}"
  )

  if [[ $is_ssh_key_provided == true ]]; then
    _final_ssh_options+=('-i' "$ssh_key_path")
  fi

  if [[ $should_disable_multiplexing == false ]]; then
    _final_ssh_options+=(
      '-o' "ControlMaster=${FRSYNC_SSH_CONTROL_MASTER}"
      '-o' "ControlPath=${FRSYNC_SSH_CONTROL_PATH}"
    )
  fi

  if [[ $should_enable_unsafe == true ]]; then
    # Override host key checking for trusted environments.
    # Last wins, so these settings take precedence.
    _final_ssh_options+=(
      '-o' 'StrictHostKeyChecking=no'
      '-o' 'UserKnownHostsFile=/dev/null'
    )
  fi

  _final_ssh_options+=('-o' "ForwardX11=${FRSYNC_SSH_FORWARD_X11}")

  # For dry-run, make SSH verbose as well, so connection details are visible
  # while rsync is in --dry-run mode. This is useful for debugging.
  if [[ $should_enable_dry_run == true ]]; then
    _final_ssh_options+=('-v')
  fi
}

#######################################
# Optimizes the file synchronization process from source(s) to destination
# using rsync over SSH.
#
# It parses CLI options, validates environment/binaries,
# builds rsync and SSH argument arrays,
# and then invokes the configured rsync binary.
#
# Globals:
#   FRSYNC_ERR_INVALID_OPTIONS
#   FRSYNC_ERR_MISSING_RSYNC_BIN
#   FRSYNC_ERR_MISSING_SSH_BIN
#   FRSYNC_ERR_PATHS_NOT_SPECIFIED
#   All FRSYNC_* environment-backed variables.
#
# Arguments (CLI):
#   -h: Displays help message and exits.
#   -c: Enables rsync compression (choice controlled by FRSYNC_COMPRESSION_CHOICE).
#   -w: Enables --whole-file (disable delta algorithm; better on fast links).
#   -n: Enables --dry-run and prints final rsync command.
#   -B: Disables use of FRSYNC_RSYNC_BASE_OPTS for this invocation.
#   -R: Adds a raw rsync option/token (can be used multiple times).
#   -i <private_key>: Specifies a path to the SSH private key.
#   -m: Disables SSH connection multiplexing.
#   -d: Enables the --delete option in rsync.
#   -u: Enables unsafe mode (relaxed SSH host key checks + --trust-sender).
#   <source_paths...> <destination_path>:
#       Specifies source(s) and destination for rsync.
#
# Returns:
#   0: On success (rsync exit code 0).
#   101: Invalid options or missing required arguments.
#   102: rsync binary missing.
#   103: ssh binary missing.
#   104: Paths not specified.
#   Other non-zero: rsync exit code on failure.
#######################################
function frsync() {
  local custom_ssh_key_path=''
  local has_custom_ssh_key=false
  local enable_compression=false
  local disable_multiplexing=false
  local enable_rsync_delete=false
  local enable_unsafe=false
  local enable_whole_file=false
  local enable_dry_run=false
  local disable_base_opts=false

  # Raw rsync options passed via -R (each element is one token)
  local -a user_raw_rsync_opts=()

  ## Parse script's arguments
  # Ensure getopts starts from first arg on every call
  local OPTIND=1
  local current_option

  while getopts ':hcwnBR:i:mdu' current_option; do
    case "$current_option" in
      h)
        __frsync_usage

        return 0
        ;;
      c)
        enable_compression=true
        ;;
      w)
        enable_whole_file=true
        ;;
      n)
        enable_dry_run=true
        ;;
      B)
        disable_base_opts=true
        ;;
      R)
        if [[ -z $OPTARG ]]; then
          __frsync_error 'Option -R requires an argument' \
            "$FRSYNC_ERR_INVALID_OPTIONS" \
            || return $?
        fi
        user_raw_rsync_opts+=("$OPTARG")
        ;;
      i)
        if [[ -z $OPTARG ]]; then
          __frsync_error 'Option -i requires an argument' \
            "$FRSYNC_ERR_INVALID_OPTIONS" \
            || return $?
        fi
        custom_ssh_key_path="$OPTARG"
        has_custom_ssh_key=true
        ;;
      m)
        disable_multiplexing=true
        ;;
      d)
        enable_rsync_delete=true
        ;;
      u)
        enable_unsafe=true
        ;;
      \?)
        __frsync_error "Invalid option: -${OPTARG}" \
          "$FRSYNC_ERR_INVALID_OPTIONS" \
          || return $?
        ;;
      :)
        __frsync_error "Option -${OPTARG} requires an argument" \
          "$FRSYNC_ERR_INVALID_OPTIONS" \
          || return $?
        ;;
    esac
  done

  ## Calculate sources and destination paths:
  # Strip processed options, leaving only path arguments
  shift $((OPTIND - 1))

  # Verify that at least two arguments remain (source(s) and destination)
  if [[ $# -lt 2 ]]; then
    __frsync_error 'Source path(s) and destination must be specified' \
      "$FRSYNC_ERR_PATHS_NOT_SPECIFIED" \
      || return $?
  fi

  # Last argument is destination path
  local -r destination_path="${!#}"

  # All arguments except the last one are source paths
  local -ar source_paths_list=("${@:1:$#-1}")

  ## Ensure required binaries are available
  __frsync_ensure_binary \
    "$FRSYNC_RSYNC_BIN" \
    "$FRSYNC_ERR_MISSING_RSYNC_BIN" \
    'rsync' \
    || return $?

  __frsync_ensure_binary \
    "$FRSYNC_SSH_BIN" \
    "$FRSYNC_ERR_MISSING_SSH_BIN" \
    'ssh' \
    || return $?

  ## Build rsync options
  local -a final_rsync_opts=()
  __frsync_build_rsync_options \
    final_rsync_opts \
    user_raw_rsync_opts \
    "$disable_base_opts" \
    "$enable_compression" \
    "$enable_whole_file" \
    "$enable_rsync_delete" \
    "$enable_dry_run" \
    "$enable_unsafe"

  ## Build SSH options
  local -a final_ssh_opts=()
  __frsync_build_ssh_options \
    final_ssh_opts \
    "$disable_multiplexing" \
    "$enable_unsafe" \
    "$has_custom_ssh_key" \
    "$custom_ssh_key_path" \
    "$enable_dry_run"

  # Build the ssh command string with all options pre-quoted so that rsync can
  # pass it intact via --rsh to the remote shell.
  local -r \
    ssh_wrapper_cmd="$FRSYNC_SSH_BIN $(printf '%q ' "${final_ssh_opts[@]}")"

  # If dry-run is enabled, print the final rsync command for inspection
  if [[ $enable_dry_run == true ]]; then
    printf 'DRY-RUN: final rsync command:\n  %q ' "$FRSYNC_RSYNC_BIN"
    printf '%q ' "${final_rsync_opts[@]}"
    printf '%s ' '--rsh'
    printf '%q ' "$ssh_wrapper_cmd"
    printf '%q ' "${source_paths_list[@]}" "$destination_path"
    printf '\n'
  fi

  ## Execute rsync with the preconfigured options.
  ## rsync exit code is propagated to the caller.
  "$FRSYNC_RSYNC_BIN" "${final_rsync_opts[@]}" \
    --rsh "$ssh_wrapper_cmd" \
    "${source_paths_list[@]}" \
    "$destination_path"
}

# Execution Guard:
# If the script is executed directly (not sourced), run the main function.
# If sourced, do nothing (just load the function).
if [[ $FRSYNC_SCRIPT_SOURCED == false ]]; then
  frsync "$@"
  exit_code=$?

  exit "$exit_code"
fi
### End
