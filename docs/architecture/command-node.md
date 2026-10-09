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
