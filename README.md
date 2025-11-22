# frsync - opinionated rsync-over-SSH wrapper

`frsync` is a small, opinionated Bash wrapper around
[`rsync`](https://man7.org/linux/man-pages/man1/rsync.1.html) over SSH.

It is designed for repeatable, fast file synchronization between local and remote hosts
(in either direction, depending on how you call `rsync`)
with sensible defaults, SSH tuning, and a few convenient toggles.

> In practical terms, it is `rsync` with a tuned default option set,
preconfigured SSH command, optional modern compression,
and an easy way to inspect and override behavior.

---

## Highlights

* **Tuned rsync defaults**

    * Archive-ish behavior, preserving most metadata.
    * Preserves hard links, ACLs, extended attributes, and numeric IDs.
    * Uses in-place partial transfers with a progress display.
    * Ready for day-to-day development, backup, and deployment scenarios.

* **Modern compression support**

    * `-c` enables compression.
    * Prefers `zstd` when supported by your `rsync`.
    * Falls back to classic zlib (`-z`) otherwise.

* **SSH optimization**

    * Uses a fast cipher by default (`chacha20-poly1305@openssh.com`).
    * Enables SSH connection multiplexing by default (`ControlMaster=auto`, `ControlPath=/tmp/frsync-%r@%h:%p`).
    * Optional custom private key with `-i <path>`.
    * Optional *unsafe* mode `-u` that relaxes host key checks for trusted  environments.

* **Good ergonomics**

    * `-n` (dry run) shows the final `rsync` command and does not modify data.
    * `-R` injects raw `rsync` options on top of the defaults.
    * `-B` discards the default `rsync` options for a single invocation (start from a blank slate).
    * `frsync -h` shows both usage and the **current effective `FRSYNC_*`  environment**.

* **Simple error model**

    * Dedicated error codes for invalid usage / missing binaries.
    * Underlying `rsync` exit codes are propagated as-is.

---

## Disclaimer

> [!IMPORTANT]
> `frsync` is a convenience wrapper around `rsync` and `ssh`. 
It is provided **as is**, without any warranty of correctness, performance, or fitness for a particular purpose.

Always:

> [!TIP]
> * Inspect what will happen with `-n` (dry run) before running real transfers.
> * Make sure you understand implications of options such as `--delete` and `--inplace`.
> * Keep separate backups when working with important or irreplaceable data.

---

## How it works (defaults)

By default, `frsync` builds an option list from the environment variable `FRSYNC_RSYNC_BASE_OPTS`. 
Out of the box (without overrides) it expands to something equivalent to the following `rsync` options:

```bash
--archive \
  --hard-links \
  --acls \
  --xattrs \
  --one-file-system \
  --recursive \
  --executability \
  --numeric-ids \
  --partial \
  --inplace \
  --human-readable \
  --info=progress2 \
  --verbose
```

On the SSH side, it builds a command like:

```bash
ssh -T \
  -c chacha20-poly1305@openssh.com \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile=$HOME/.ssh/known_hosts \
  -o ControlMaster=auto \
  -o ControlPath=/tmp/frsync-%r@%h:%p \
  -o ForwardX11=no
```

This SSH command is then passed to `rsync` via `--rsh`.

You can override most of this behavior per-invocation (via CLI flags) or per-environment (via `FRSYNC_*` variables).

---

## Prerequisites

* `bash` (the script uses Bash features and is not POSIX `sh`-compatible).
* `rsync` available in `PATH`.
* `ssh` client available in `PATH`.

Optional but recommended:

* `rsync` ≥ 3.2 with `zstd` support (for the best compression experience).
* SSH keys configured for passwordless authentication to your remote host(s).

---

## Installation

### 1. Place the script

Save the script somewhere under your home directory, for example:

### 2a. Use as a sourced shell function (recommended for interactive use)

Add this snippet to your `~/.bashrc`, `~/.bash_profile`, or similar startup file:

```bash
# ~/.bashrc or ~/.profile

if [[ -f "$HOME/frsync.sh" ]]; then
  # Source to make `frsync` function available in the current shell
  # (the script auto-detects whether it was sourced or executed).
  source "$HOME/frsync.sh"
fi
```

Reload your shell configuration:

```bash
source ~/.bashrc
```

After that, `frsync` will be available as a function in your interactive shell sessions.

### 2b. Use as a standalone CLI (script on PATH)

Alternatively, you can keep the script where it is and expose it via a symlink in a directory
that is already on your `PATH` (for example `~/.local/bin`):

```bash
chmod +x "$HOME/frsync.sh"
mkdir -p "$HOME/.local/bin"
ln -s "$HOME/frsync.sh" "$HOME/.local/bin/frsync"
```

Now you can call it as a regular command:

```bash
frsync [options] <local_path> ... <user@host:/remote/path>
```

> [!IMPORTANT]
> In this mode you do **not** need to source the script.

---

## Usage

### Synopsis

```bash
frsync [-h] [-c] [-w] [-n] [-B] [-R rsync_opt] \
  [-i private_key] [-m] [-d] [-u] \
  <local_path1> [<local_path2> ...] <user@host:/remote/path>
```

* All arguments except the last one are treated as **local paths** (one or more).
* The **last** argument must be an `rsync`-style remote specification: `user@host:/absolute/path`.

### Options

* `-h`
  Show help and exit. The help output includes a snapshot of the current effective `FRSYNC_*` environment.

* `-c`
  Enable `rsync` compression.

    * If `FRSYNC_COMPRESSION_CHOICE=auto` (default), `frsync` will:

        * Prefer `zstd` when supported by your `rsync` (using
          `--compress --compress-choice=zstd --compress-level=$FRSYNC_COMPRESSION_LEVEL`).
        * Fall back to classic zlib (`-z`) when `zstd` is not available.
    * You can force a specific algorithm via `FRSYNC_COMPRESSION_CHOICE`
      (see below).

* `-w`
  Use `--whole-file` to disable the rsync delta algorithm. This is often beneficial on high-bandwidth / low-latency links
  or when CPU, rather than bandwidth, is the bottleneck.

* `-n`
  Dry run. Adds `--dry-run` to `rsync` and prints the final command line it is going to execute.
  This is the safest way to verify what will happen before running a real transfer.

* `-B`
  Ignore `FRSYNC_RSYNC_BASE_OPTS` for this invocation.
  Starts from an empty `rsync` option set and then applies `-R` options and other flags.

* `-R rsync_opt`
  Append a raw `rsync` token (option or argument) to the command line.

    * Can be specified multiple times; each `-R` adds a **single** token.
    * These tokens are injected *after* `FRSYNC_RSYNC_BASE_OPTS` (unless `-B` is used)
       but *before* dynamic flags such as compression, delete, whole-file, dry-run, or trust-sender.
    * This makes `-R` suitable for overriding or extending the base options without clobbering explicit toggles.

* `-i private_key`
  Use a specific SSH private key for authentication (passed as `ssh -i private_key`).

* `-m`
  Disable SSH connection multiplexing. Skips `ControlMaster` and `ControlPath` configuration.

* `-d`
  Enable `--delete` on the receiving side so that the destination becomes a mirror of the source.
  Files that exist only on the destination will be deleted.

* `-u`
  Enable *unsafe* SSH/rsync options for **trusted networks only**:

    * `StrictHostKeyChecking=no`
    * `UserKnownHostsFile=/dev/null`
    * Adds `--trust-sender` to `rsync`.

> [!IMPORTANT]
> This is convenient for ephemeral lab environments or CI runners where host keys are not managed, 
   but it significantly reduces security and should not be used on untrusted networks.

---

## Environment variables

All behavior is tunable via `FRSYNC_*` variables. If you invoke `frsync -h`,
you will see a snapshot of the **current effective values**.

### `FRSYNC_RSYNC_BIN`

* **Description:** `rsync` binary to use.
* **Default:** `rsync`

### `FRSYNC_RSYNC_BASE_OPTS`

* **Description:**
  Base `rsync` options that form the initial option set before dynamic flags
  (compression, delete, whole-file, dry-run, trust-sender) are added.

* **Default (pretty-printed):**

  ```bash
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
  ```

* **Notes:**

    * Internally this is just a string that the shell splits into tokens.
    * You may set it to an empty string to start from a minimal base and build everything via `-R` and other knobs.

### `FRSYNC_SSH_BIN`

* **Description:** `ssh` binary to use.
* **Default:** `ssh`

### `FRSYNC_SSH_CIPHER`

* **Description:** Cipher string passed to SSH.
* **Default:** `chacha20-poly1305@openssh.com`

### `FRSYNC_SSH_CONTROL_MASTER`

* **Description:** Value for `ControlMaster` when multiplexing is enabled.
* **Default:** `auto`

### `FRSYNC_SSH_CONTROL_PATH`

* **Description:** `ControlPath` template for SSH multiplexing.
* **Default:** `/tmp/frsync-%r@%h:%p`

### `FRSYNC_SSH_STRICT_HOST_KEY_CHECKING`

* **Description:** Default `StrictHostKeyChecking` value when *not* using `-u`.
* **Default:** `yes`

### `FRSYNC_SSH_KNOWN_HOSTS_FILE`

* **Description:** Path used for `UserKnownHostsFile` when *not* using `-u`.
* **Default:** `$HOME/.ssh/known_hosts`

### `FRSYNC_SSH_FORWARD_X11`

* **Description:** `ForwardX11` setting.
* **Default:** `no`

### `FRSYNC_COMPRESSION_CHOICE`

* **Description:** Compression choice for `rsync` when `-c` is enabled.
* **Supported values:**

    * `auto` (default) - prefer `zstd` if supported, otherwise fall back to zlib (`-z`).
    * `none` or empty - disable compression even if `-c` is provided.
    * `zstd`, `zlib`, `lz4`, or any algorithm advertised by `rsync`.

If you request a custom algorithm that your local `rsync` does not support,
`frsync` falls back to the `auto` behavior.

### `FRSYNC_COMPRESSION_LEVEL`

* **Description:** Compression level for modern algorithms (zstd, lz4, etc.).
* **Default:** `6`

---

## Examples

### Example 1 - Basic deployment to a remote server

```bash
frsync ./dist user@10.0.0.10:/srv/www
```

Synchronizes the local `./dist` directory to `/srv/www` on the remote host,
using the default SSH key and no compression.

---

### Example 2 - Enable compression on a slower link

```bash
frsync -c ./src user@example.com:/backup/src
```

Enables compression. If local `rsync` supports `zstd`, it will be used.
Otherwise, `rsync` falls back to classic zlib compression.

---

### Example 3 - Mirror directory with delete

```bash
frsync -d ./data user@host:/ssd/backup
```

The remote directory `/ssd/backup` becomes a mirror of `./data`.
Files that exist only on the remote side will be deleted. Use this with care!

---

### Example 4 - Compression + delete + whole-file on a fast link

```bash
frsync -cwd ./data user@host:/ssd/backup
```

Useful on high-bandwidth / low-latency connections where CPU cost of the rsync delta algorithm 
outweighs its benefits.

---

### Example 5 - Use a custom SSH key

```bash
frsync -i "$HOME/.ssh/id_ed25519" ./data user@host:/data
```

Forces SSH to use the specified private key instead of the default.

---

### Example 6 - Unsafe mode in a trusted lab network

```bash
frsync -u ./logs user@10.0.0.50:/var/logs/archive
```

> [!IMPORTANT]
> Disables strict host key checking and does not store host keys in `~/.ssh/known_hosts`,
while also adding `--trust-sender` to `rsync`.
Convenient in short-lived test environments, not recommended on untrusted networks.

---

## Exit codes

`frsync` uses the following exit codes:

* `0` - success.
* `101` (`FRSYNC_ERR_INVALID_OPTIONS`) - invalid options or usage
  (missing arguments, unsupported flags, etc.).
* `102` (`FRSYNC_ERR_MISSING_RSYNC_BIN`) - `rsync` binary not found.
* `103` (`FRSYNC_ERR_MISSING_SSH_BIN`) - `ssh` binary not found.
* `104` (`FRSYNC_ERR_PATHS_NOT_SPECIFIED`) - local path(s) and/or remote
  path were not provided.
* Any other non-zero code - propagated `rsync` exit code
  (see `rsync(1)` for details).

This allows higher-level scripts to distinguish between user/configuration
errors and actual transfer or network failures.

---

## Debugging and diagnostics

* For invalid CLI usage or missing arguments, `frsync` prints an error message, shows help, and exits with code `101`.
* For SSH and network issues, `rsync` will report errors and `frsync` will propagate the exit code.
* With `-n` (dry run), `frsync` prints the exact `rsync` command that will be executed. 
   This is the recommended way to understand and validate what the wrapper is doing.
* For deeper SSH diagnostics, you can temporarily enable verbose SSH by modifying the script
   (for example, adding `-v` to the SSH options) if needed.

---

## Customization tips

You are encouraged to adjust the defaults to match your environment:

* Change the cipher suite if your SSH policies require different algorithms.
* Adjust `ControlPath` if `/tmp` is not suitable (e.g., shared or constrained filesystems).
* Override `FRSYNC_RSYNC_BASE_OPTS` in your shell profile to reflect your typical workflows
   (e.g., add common `--exclude` patterns or drop metadata you do not need).
* Use `-B` together with `-R` when you want a one-off invocation that
  completely ignores your base defaults.

> [!IMPORTANT]
> As always, test on non-critical data first!

---

## Status

This script is intentionally self-contained. 
It is not a full backup system, but a practical, debuggable layer on top of `rsync` and `ssh`.

Issues, ideas, and improvements are welcome via GitHub Issues and Pull Requests :innocent:
