# Design traceability

<!-- literate-ai:authority-reviewed sha256:a931ffe1eb357f40c3a5eaa52353da2095cca6173004d5fcee57084c540ec6ba -->

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

`make test` checks both applications and build boundaries. `make verify-update`
qualifies the image and CM5 emulation and binds the retained sources to its
receipt. `make release-assets-check` separately exercises the fresh packaged
installer, authenticated browser, project dependency deployment, restart
persistence and desktop input. Docker Desktop on macOS ARM is the installed
acceptance target; Windows/WSL2 build support and physical Pi qualification must
not be inferred from that result.
