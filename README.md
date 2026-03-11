# Clipboard File Transfer

Transfer directories between machines using the clipboard — designed for environments where direct network access isn't available (e.g. Citrix sessions).

Files are tarred, xz-compressed (maximum), base64-encoded, and placed on the clipboard. A SHA-256 checksum of the tar archive is provided for verification on the receiving end.

## Scripts

| Script | Platform | Purpose |
|---|---|---|
| `clip-pack-mac.sh` | macOS | Pack current directory → clipboard |
| `clip-pack-wsl.sh` | WSL2 | Pack current directory → clipboard |
| `clip-unpack-mac.sh` | macOS | Clipboard → replace current directory |
| `clip-unpack-wsl.sh` | WSL2 | Clipboard → replace current directory |

## Setup

```bash
chmod +x clip-pack-*.sh clip-unpack-*.sh
```

Optionally, copy them somewhere on your `$PATH` (e.g. `~/bin/` or `/usr/local/bin/`).

### WSL2 prerequisites

PowerShell must be on your PATH for the unpack script to read the clipboard. Add this to your `~/.bashrc` if it isn't already:

```bash
export PATH=$PATH:/mnt/c/Windows/System32/WindowsPowerShell/v1.0
```

## Usage

### Mac → WSL2

On the Mac, `cd` into the directory you want to transfer:

```bash
cd /path/to/project
clip-pack-mac.sh
```

Note the checksum displayed. Paste is handled by the clipboard — just switch to the Citrix session.

On WSL2, `cd` into the target directory (create it first if needed):

```bash
mkdir -p /path/to/project && cd /path/to/project
clip-unpack-wsl.sh
```

Verify the checksum matches, then confirm extraction.

### WSL2 → Mac

Same process in reverse using `clip-pack-wsl.sh` and `clip-unpack-mac.sh`.

## Size limit

The scripts warn if the base64-encoded payload exceeds 60 MB. Citrix clipboard limits vary by configuration — the default is typically 512 KB, but admins may have raised it. If transfers fail silently or produce checksum mismatches, the payload is likely being truncated.

For large transfers, consider:

- Excluding build artefacts and dependencies (e.g. `node_modules/`, `.git/`, `__pycache__/`) by packing a subset instead of `.`
- Splitting the payload manually with `split` and reassembling with `cat`

## Safety guards

- **Checksum verification** — the unpack scripts display the SHA-256 of the received tar and prompt you to confirm it matches before extracting.
- **Directory protection** — unpack refuses to run in `$HOME` or `/`.
- **Confirmation prompt** — unpack warns that it will replace the current directory contents and requires explicit confirmation.

## Troubleshooting

### `base64: invalid input` on WSL2

Usually caused by `\r\n` line endings from PowerShell. The unpack script strips these with `tr -d '\r\n'`. If you still hit issues, dump the raw clipboard to a file and inspect:

```bash
powershell.exe -Command "[Console]::Out.Write((Get-Clipboard -Raw))" > raw.txt
xxd raw.txt | head -20
```

### Checksum mismatch

The clipboard payload was truncated — you've hit the Citrix size limit. Try reducing the payload size or ask your admin about the `MaximumClipboardTransferSizeLimitInKB` policy.

### `powershell.exe: command not found`

See the WSL2 prerequisites section above.
