# Download and install ElixirSSI

[Project guide](../README.md) → distribution

GitHub releases provide a prebuilt system image and a workstation environment.
The same image targets Raspberry Pi 5, CM5 and CM5 Lite and runs on the CM5
emulator. Physical-board boot qualification is still pending; release evidence
identifies emulation and static board checks separately.

## Command-node installation

The command-node package uses Elixir/OTP and Phoenix LiveView. Apple Silicon
macOS and ARM64 Linux need Docker; no local Elixir or Python installation is
required. Put the release assets and `SHA256SUMS` in one directory, then open
`install-elixirssi.command` on macOS, or run:

```console
sh install-elixirssi.command "$HOME/ElixirSSI"
```

The bootstrap verifies the assets and starts the packaged Elixir installer.
Installation is offline and refuses to overwrite an existing destination. It
loads the command application, emulator and development images and preserves
an installed source copy. Open `~/ElixirSSI/ElixirSSI.command` or run
`~/ElixirSSI/elixirssi` to enter the workspace. The default address is
`http://localhost:4000`; the launcher supplies a one-use sign-in ticket.

All ordinary work happens in that interface:

- **Cluster:** configure node count and memory, start/stop/restart emulated Pis,
  inspect member resources and services, and register physical Pi addresses.
- **Projects:** create and edit Mix projects, fetch dependencies, format, compile,
  test and evaluate. The built-in **Demos** project contains the running desktop
  examples; copy one to an editable project to build and run your version. Builds run in isolated containers with only the project
  mounted. Deployment sends runtime applications and resources to a selected,
  trusted node; shared user dependencies may require restarting managed apps.
- **Console:** verify SSH fingerprints, connect to nodes, inspect processes and
  logs, move services, and evaluate Elixir on an explicit target.
- **Desktop:** use the guest's windows, graphics and shell directly in the browser.
- **Files:** manage project files, upload/download, import/export project ZIPs,
  browse cluster and node-local files, and link host folders.
- **Operations:** follow results and failures, including interrupted operations
  after a command-node restart.

Stop/start keeps each virtual disk and the installation's cluster identity.
The command application stays available when the cluster is stopped. Local
management ports bind to loopback: HTTP is 8180+I, HTTPS 8480+I and SSH 2320+I.
The emulator SSH password is `elixir`; verify its fingerprint in Console before
trusting it. Each installation has a separate cluster secret. Virtual RAM
defaults to 4096 MiB per node; choose settings appropriate for the host.

## Graphical desktop

In Console, establish a trusted SSH connection first. In Desktop, select that
connection and the command-node address reachable from the guest. Docker Desktop
uses `host.docker.internal:4010`. The Elixir bridge authenticates the guest; the
browser uses its existing Phoenix session. No SDL installation or separate
window is needed. The cluster owns the compositor and application state, so
moving its desktop service restores the windows and shell history on another
member. Shell variable bindings are local to the old evaluator and are not
carried over.

Use a demo's **Open source** link, or open **Projects → Demos**, to see its guest version, source files and
content identities. **Copy to editable project** creates a separate Mix project
and keeps the original files under `priv/original`. Edit its `lib/*_app.ex` file,
save, then use **Compile** and **Test**. **Deploy and run desktop app** installs
the copy on every connected cluster node and opens its own window. Repeat that
deployment after adding a node. It leaves the built-in demo available.

The local launcher publishes the desktop bridge only on loopback. Physical Pis
need a private transport that can reach it; the bridge protocol itself is not
encrypted. Do not expose it as a public endpoint. Command-node remote access
likewise needs a configured authenticated transport such as an SSH tunnel or TLS.

## Files and linked folders

In **Projects**, selecting a file loads it into the editor; **Save file** writes
it to command-node storage. On the default workstation installation, projects
live under `~/ElixirSSI/state/command/projects`. **Manage project files, upload
and download** opens the same project's Files view.

Files has two panes, **Local** and **Remote**, each with its own location selector,
folder path, parent button and refresh control. Select a file and use **Copy to
remote →** or **← Copy to local** to preview its transfer into the opposite folder.
The toolbar applies to the active pane. Use **Edit**, **Rename**, **New…** or
**Upload…** as needed; folder menus offer rename and deletion of empty folders.
The panes stack on phones, with down/up transfer controls.

Locations include command projects, shared cluster files, node-local
files and linked host folders. Cluster and node locations appear after SSH trust
is established in Console. Select a file, then **Edit** or **Download file**.
Create files/folders, rename entries, or explicitly delete files and empty folders.
Uploads preserve existing files; copies preview their destination and require
approval before replacing anything. Files changed since preview or editing are
rejected instead of silently overwritten. Transfers are limited to 16 MiB per
file; project ZIPs and synchronized trees are limited to 64 MiB and 2,000 entries.

Under **Project ZIP…**, **Download project ZIP** exports source and resources without build output or
fetched dependencies. **Import project** creates a new project from a ZIP with
`mix.exs` at its root. It preserves binary resources and empty directories.

To work with an existing host folder, use **Link folder…** with its absolute
path and a display name. This path belongs to the command node's Docker host,
even if the browser is on a different computer. Select read-only or read/write
access explicitly. Links persist across restarts; unlinking preserves the folder.

To synchronize, open the desired folders in both panes, then use
**Synchronize… → Compare open folders**. Review the preview, resolve conflicts by
choosing which side to keep, then **Apply synchronization**. The first sync merges
unrelated files. Subsequent previews use a saved baseline to recognize edits and
deletions on either side. A folder conflict choice applies to the whole subtree;
rename a version before previewing if you want to preserve both. Previous folder
pairs can be compared again after reconnecting.

Synchronization excludes `.git`, `_build`, `deps`, `.tools` and deployment
bundles. It runs only when applied. A failed operation may leave earlier listed
changes completed; inspect its outcome and make a new preview. The baseline is
updated only after both folders agree. Local projects remain available while
cluster nodes are offline, and remote file failures appear in the workspace.

## Physical Raspberry Pi 5 and CM5

Download `elixirssi-pi5-cm5.img.gz` and `SHA256SUMS` from the same release.
Verify its SHA-256, decompress it, and flash the resulting image to each
board's SD card (Pi 5 or CM5 Lite) or CM5 eMMC using your usual image writer.
Flashing replaces the target device's contents. Use one image on N boards.
The image includes Pi 5, CM5 and CM5 Lite device trees and selects the board
through firmware. Ethernet is required for cluster networking.

Before boot, edit `ssi.conf` on the FAT partition: give every board in your
cluster the same fresh `secret` and `cluster` name; configure SSH credentials
or copy `authorized_keys`. The downloadable image uses the explicitly warned
insecure default secret, never the release builder's private cluster secret.
Connect Ethernet and power on each board. Register its HTTP address in the
Phoenix Cluster view, then verify its SSH fingerprint in Console. The guest
also serves its status page directly; the command workspace is the main
operator interface.

## Release verification

The release skill requires every asset through `literate.release.json`.
`make release-assets` packages accepted products and emits an exact-commit
manifest. The release gate checks source/image currency; installer qualification
runs the packaged environment without compiling. The completed command-node conversion
and its qualification are recorded in SSI-016 in the [work queue](../roadmap/active-work.md). Source archives accompany the
kernel and patched emulator. `SHA256SUMS` covers the public files; the release
publisher checks uploaded bytes against the qualified manifest.
