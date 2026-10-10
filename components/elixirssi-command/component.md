---
namespace: elixirssi-command
version: 0.1.0
display_name: ElixirSSI command node and development workspace
profiles: []
sample: false
provides: []
requires: []
authoring_inputs:
  - kind: specification-to-source-skill
    uri: skills/specification-to-source/elixir-beam-system/SKILL.md
workflow_definition: workflows/production/staging/dev/workflow.md
routing_policy: routing/production/staging/dev/routing.json
flavor_slots: []
entrypoints: []
acceptance_contracts: []
source_dependencies: []
---
# ElixirSSI command node

The command node MUST run an Elixir/OTP application with Phoenix LiveView,
providing one browser workspace for operating and developing for ElixirSSI.
Application policy and orchestration MUST be Elixir. Docker, QEMU, Linux and
minimal bootstrap scripts are platform dependencies, not separate management
applications. The retained implementation is `command/`.

The workspace MUST remain available while managed nodes are stopped or
unreachable. It MUST persist settings, project source and operation outcomes.
Supervised operations MUST report progress and terminal success or failure;
restarting the command node MUST mark unfinished work interrupted instead of
claiming success. Browser reconnects MUST recover current state.

## Operations

- Authenticate before viewing or changing command-node state, and on LiveView
  reconnect. Protect browser sessions, mutation requests and websocket origins.
- Configure, start, stop and restart local emulated instances; preserve their
  disks and cluster identity. Surface Docker and boot failures in the workspace.
- Register physical Pi endpoints alongside emulated nodes. Clearly distinguish
  offline, booting, responding and healthy cluster membership. Do not offer
  local Docker operations for physical hardware.
- Expose member resources, processes, services, logs and authenticated Elixir
  console operations. Node control and service moves MUST name explicit targets.
- Offer cluster desktop access from the same workspace.

## Development

Offer project creation, file navigation, editing, saving, formatting, compilation,
tests and evaluation with visible results. Source paths MUST stay within the
project, reject symlink escape and bound reads/writes. Execute project code
outside the command application with resource limits and no inherited management
credentials or Docker socket.

Deployment MUST target explicitly selected nodes over authenticated connections,
validate artifacts and report each target's outcome. Merely compiling locally
does not count as deployment. Remote host identities require explicit trust;
do not silently accept unknown or changed SSH keys.

Deployment MUST include the project's runtime OTP dependencies and `priv`
resources, except libraries provided by the OS release. Build and export execute
in the isolated project environment. Transfers MUST be bounded and checked for
completeness and content identity before activation. Prepare dependency code
paths before starting applications; failed activation MUST attempt restoration
of the previously installed application set and report any restoration failure.
Only changed applications and their installed dependents are restarted; unrelated
applications and desktop windows MUST remain running. Replacement code MUST be
loaded without an intervening interval in which hosted desktop callbacks are absent.

Guest SSH exec requests MUST evaluate Elixir under the same authenticated
operator authority as the interactive SSH shell. Bound command size and evaluation
time; return syntax/runtime errors as failed operations. This is privileged system
evaluation, not an untrusted-code sandbox. Local project evaluation remains isolated.

## Source and files workspace

The desktop view MUST identify each built-in demo's exact running source version,
open that source, and copy it into an editable project with build, deploy and run
actions. Packaged source provenance MUST correspond to the guest build, not the
command node's checkout or latest upstream branch. Demos MUST appear as a built-in
project within Projects, sharing the workspace navigation rather than a separate
source page. Desktop source links MUST open that project and the chosen demo.

The authenticated browser MUST support file and folder creation, source editing,
rename, deletion, binary upload/download, and project import/export. A unified
Files view MUST distinguish command workspace, shared cluster files and node-local
files and support explicit copies between them. Files MUST present two independently
navigable panes, defaulting to local command files and remote cluster files, with
directional copy controls using the selected file and opposite folder. Both panes
MUST retain their locations and refresh after transfers. Editing, uploads, folder
links and optional synchronization MUST be contextual tools rather than separate
primary objects or permanently expanded forms. Browser saves MUST persist on the
command node. Remote operations MUST use verified node identities and report
offline, permission and transfer failures without claiming completion.

Operators MUST be able to link selected host directories into the workspace.
The installed Docker configuration MUST expose only selected additional folders;
paths are host paths, not browser-machine paths. File operations MUST remain within
the selected root, reject symlink traversal, bound transfers and archive expansion,
and require explicit confirmation before destructive operations or overwrites.

Linked folders MUST support explicit synchronization with a selected cluster
directory. Preview MUST show additions, changes, deletions and conflicts with
direction and destination. Applying a plan MUST reject changed inputs, require
explicit conflict resolution and preserve unrelated files. Synchronization metadata
MUST survive command-node restarts; no background synchronization is implied.

Qualification MUST exercise these flows in a real browser against the packaged
application and emulated cluster, including edited demo deployment and launch,
binary round trips, persisted host-folder links, conflict resolution, stale-plan
rejection and node-offline errors.

## Distribution and qualification

Provide the command-node application and Elixir runtime as installed artifacts.
The default user entrypoint MUST open the unified workspace; users MUST NOT need
to switch between a Python CLI and a disconnected browser monitor. Migrate
existing installations without discarding cards, project files or cluster secrets.

Qualification MUST include authenticated browser lifecycle and development
interactions, boundary tests and a packaged three-node emulated cluster on macOS
ARM Docker Desktop. Physical-board execution remains a separately stated gate.
Successful deployment MUST flush application files and metadata to persistent
storage before acknowledgement. Invalid deployment metadata or missing user
artifacts MUST NOT prevent the operating system from booting. Image upgrades
MUST preserve each existing node's data partition and identity.

The [architecture](../../docs/architecture/command-node.md) and SSI-016 queue item
define the delivery scope; an incomplete UI shell is not release acceptance.
