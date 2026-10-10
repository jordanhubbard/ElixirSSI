# Elixir command node

The command node is the user's workspace for ElixirSSI. It runs a Phoenix
LiveView application supervised by OTP, independently of the cluster it manages.
The same application runs on an ARM Linux command node or in Docker Desktop on
the workstation. Its durable data includes installation configuration, registered
nodes, projects, credentials and operation history. Cluster shutdown must not
stop the workspace or lose these records.

The implementation lives in `command/`. The browser renders LiveView templates;
Elixir owns configuration, validation, execution and progress. Thin bootstrap
scripts may start the packaged release. Docker and QEMU are infrastructure, not
alternative command applications. Installed configuration, provisioning and
orchestration belong to the Elixir release. Repository build and qualification
scripts are development infrastructure.

## One workspace

- Setup selects a local emulated cluster or registers physical Pi endpoints.
- Operations start, stop and restart emulated instances with persistent cards;
  physical nodes expose only operations supported by authenticated guest APIs.
- Cluster views show membership, machine resources, processes, services, logs,
  connectivity and operation outcomes. Empty and offline states offer real actions.
- Projects have a file navigator, editor, save/format, tests and an Elixir
  evaluation console. Work executes in supervised, bounded jobs, outside the
  LiveView process. Deployment transfers compiled application code to explicitly
  selected cluster targets and reports each target's result.
- Authentication protects the entire workspace, including LiveView reconnects.
  The command node is an execution authority, not a publicly accessible monitor.

## Sources and files

Demos is a built-in, read-only project in Projects. Desktop source links open the
chosen demo there; copying creates an ordinary editable project in the same list.
There is no separate source page. The guest-supplied snapshots include source
hashes, compiled module identities and guest version. Requests follow the desktop
service to its current owner. Copying a snapshot creates a namespaced Mix project
and preserves the originals under `priv/original`. The project can be edited,
compiled and tested in the workspace. Its explicit desktop deployment installs on
all currently connected members before opening or restarting its window, so
distributed callbacks are available wherever tasks run. Membership changes during
deployment are errors; adding a new member requires redeployment. A copied demo
does not replace the built-in application.
Deployment restarts changed applications and their installed dependents, retaining
unrelated applications. Existing module code stays callable until its replacement
is loaded, so desktop callbacks do not encounter a temporary missing-module gap.

Files uses two independently navigable panes, initially local command projects and
remote cluster files. Location selectors also expose node-local files and linked
host folders, and permit any explicit pair of locations. Selecting a file highlights
it; directional arrows preview copying it into the opposite pane's open folder.
Both panes refresh after a transfer while retaining their paths. A contextual
toolbar opens editing, rename, create, upload, project archives, folder linking or
synchronization. Folder rows open on activation and expose rename/delete in their
menu. On narrow screens the panes stack and transfer arrows point up/down. Browser saves persist in command-node storage;
binary uploads/downloads and project ZIP import/export use bounded transfers.
Copies preview the destination and reject changed source or destination contents.
Node-local access rejects symlinks and special devices. The guest transfer service
checks chunk offsets, length and SHA-256 before committing a write.

Host links refer to folders on the command node's Docker host, not the browser's
machine. They default to read-only. Short-lived Elixir helper containers mount only
the selected folder and a request/response directory, without network access,
management credentials or the Docker socket. Link metadata persists across
command-node restarts; unlinking does not delete files.

Folder synchronization is explicit and bidirectional. A preview compares both
trees with their last successful common baseline. First sync preserves unrelated
files; conflicting edits, deletion versus edits, and file/directory replacements
require a side selection. Resolved changes receive another review before apply.
Apply rechecks the preview, copies bounded verified content, checks individual
destination identities and saves a new baseline only when both final trees agree.
It is not an atomic transaction across machines: a failed operation reports that
earlier listed changes may have completed, retains the previous baseline and
requires a new preview. Build output, dependencies, Git metadata and workspace
tool files are excluded. Operations and baseline records survive reconnection.

## Boundaries

The local installation binds its published interface to loopback. Phoenix sessions,
CSRF protection and websocket origin checks protect browser access; command-node
authentication is distinct from guest pairing. Remote command-node access requires
an authenticated transport such as an SSH tunnel or configured TLS. Credentials
stay outside source trees and are never included in status or operation output.

Project paths stay within the selected workspace; symlink traversal is rejected.
Executing user Elixir is an explicit authenticated action. A project process must
not inherit host management credentials or the Docker socket. Deployment and node
control require explicit target selection and an authenticated guest connection.
Physical hardware qualification remains separate from tests against emulated Pis.

## Delivery and acceptance

SSI-016 in the active work queue owns delivery. Completion requires a packaged
Elixir command-node release, replacement of the installed management flow, real
browser interactions and end-to-end development/deployment on the emulated SSI.
The Phoenix shell alone does not satisfy this plan. Preserve existing cards,
cluster identity and user projects while migrating an installation.

## Browser desktop transport

The command application hosts an authenticated RemoteOS v2 bridge. The guest
remains the desktop compositor and cluster-service owner; Phoenix forwards its
bounded drawing frames to a canvas and routes authenticated browser input back
to that guest. No separate SDL window or Python desktop manager is required.
The bridge accepts a per-installation secret in the protocol handshake, supplied
to the guest through verified SSH. Browser sessions never receive that secret.
The local launcher publishes the bridge on loopback port 4010. Remote physical
nodes require a private authenticated transport to the command node, such as an
SSH tunnel. The bridge itself is not a public, encrypted transport.
