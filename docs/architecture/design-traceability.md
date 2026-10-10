# Design traceability

<!-- literate-ai:authority-reviewed sha256:d2cf0277dcb831e0fd0334c24e97b98ab1a5d4c1a2cff80753873203c395d141 -->

[Project guide](../README.md) → design traceability

Behavior belongs in Component specifications; target variance belongs in Flavors;
conversion technique belongs in exact skills; execution order belongs in workflows;
model eligibility belongs in routing; validation and authorization remain framework
policy. The manifest selects the source-intelligence provider, while its local database
remains
derived evidence outside source authority. Changes should update the owning artifact,
its nearby explanation or diagram,
and an end-to-end test. Illustrations aid understanding; prose requirements and
acceptance scenarios remain normative. See the [project map](../user/project-layout.md).

The retained OS component (`components/elixirssi/component.md`) owns boot,
cluster semantics, guest services and image qualification (`os/`). The retained
command component (`components/elixirssi-command/component.md`) owns the
authenticated Phoenix workspace, installation policy and development operations
(`command/`). Their transport and execution boundaries are described in the
[command-node architecture](command-node.md). The command node remains available
when the guest cluster is stopped; it does not replace the guest's BEAM runtime.

SSI-018 extends that boundary to file transfer, explicit host-folder links,
conflict-aware synchronization and provenance-bound desktop examples. Guest source
snapshots and filesystem operations belong to the OS; browsing, editing, transfer
review and synchronization baselines belong to the command component. Pixel
surfaces belong to individual guest windows, so editable demo copies can coexist.
SSI-019 simplifies this workspace: Demos is a built-in project, and Files presents
two independent panes with directional transfers and contextual tools. Existing
provenance, bounded transfers and conflict checks remain command/guest contracts.

`make test` checks both applications and build boundaries. `make verify-update`
qualifies the image and CM5 emulation and binds the retained sources to its
receipt. `make release-assets-check` separately exercises the fresh packaged
installer, authenticated browser, project dependency deployment, restart
persistence and desktop input. Docker Desktop on macOS ARM is the installed
acceptance target; Windows/WSL2 build support and physical Pi qualification must
not be inferred from that result.
