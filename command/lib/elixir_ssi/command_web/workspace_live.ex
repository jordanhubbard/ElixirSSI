defmodule ElixirSSI.CommandWeb.WorkspaceLive do
  use Phoenix.LiveView

  alias ElixirSSI.Command.{
    Store,
    Cluster,
    Instances,
    Operations,
    Projects,
    Remote,
    Nodes,
    Desktop
  }

  @impl true
  def mount(_, _, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(ElixirSSI.Command.PubSub, "command")
    if connected?(socket), do: Phoenix.PubSub.subscribe(ElixirSSI.Command.PubSub, "desktop")

    {:ok,
     assign(socket,
       ready: connected?(socket),
       config: Store.get(),
       cluster: Cluster.snapshot(),
       section: "cluster",
       projects: Projects.list(),
       project: nil,
       files: [],
       file: "",
       source: "",
       ssh_probe: nil,
       targets: Remote.targets(),
       message: nil
     )}
  end

  @impl true
  def handle_event("navigate", %{"section" => section}, socket)
      when section in ~w(cluster projects console operations desktop) do
    {:noreply, assign(socket, :section, section)}
  end

  def handle_event("desktop-ready", _, socket),
    do: {:noreply, push_event(socket, "desktop-frame", Desktop.frame() || %{})}

  def handle_event("desktop-input", event, socket) do
    Desktop.input(event)
    {:noreply, socket}
  end

  def handle_event("desktop-connect", %{"target" => target, "endpoint" => endpoint}, socket) do
    result =
      Operations.submit("Connect cluster desktop through #{target}", fn ->
        Desktop.enable(target, endpoint)
      end)

    message =
      case result do
        {:ok, _} -> "Desktop connection requested. Its frame will appear below."
        {:error, why} -> why
      end

    {:noreply, assign(socket, message: message, config: Store.get())}
  end

  def handle_event("probe-ssh", %{"host" => host, "port" => text}, socket) do
    with {port, ""} <- Integer.parse(text),
         true <- port in 1..65535,
         {:ok, fingerprint} <- Remote.probe(host, port) do
      {:noreply,
       assign(socket,
         ssh_probe: %{host: host, port: port, fingerprint: fingerprint},
         message: nil
       )}
    else
      _ ->
        {:noreply,
         assign(socket, :message, "Could not inspect SSH identity. Check the host and port.")}
    end
  end

  def handle_event(
        "trust-ssh",
        %{"password" => password},
        %{assigns: %{ssh_probe: probe}} = socket
      )
      when not is_nil(probe) do
    case Remote.trust(probe.host, probe.port, probe.fingerprint, password) do
      {:ok, message} ->
        {:noreply, assign(socket, message: message, ssh_probe: nil, targets: Remote.targets())}

      {:error, message} ->
        {:noreply, assign(socket, :message, message)}
    end
  end

  def handle_event("remote-evaluate", %{"target" => target, "source" => source}, socket) do
    message =
      case Operations.submit("Elixir on #{target}", fn -> Remote.evaluate(target, source) end) do
        {:ok, _} -> "Remote evaluation started. Results appear below."
        {:error, reason} -> reason
      end

    {:noreply, assign(socket, message: message, config: Store.get())}
  end

  def handle_event("inspect-node", %{"target" => target, "action" => action}, socket)
      when action in ~w(processes logs services) do
    result =
      Operations.submit("#{action} on #{target}", fn -> Nodes.inspect_node(target, action) end)

    message =
      case result do
        {:ok, _} -> "Reading #{action}. Results appear below."
        {:error, why} -> why
      end

    {:noreply, assign(socket, message: message, config: Store.get())}
  end

  def handle_event(
        "move-service",
        %{"target" => target, "service" => service, "destination" => destination},
        socket
      ) do
    result =
      Operations.submit("Move #{service} to #{destination} via #{target}", fn ->
        Nodes.move_service(target, service, destination)
      end)

    message =
      case result do
        {:ok, _} -> "Requesting service migration. Check its location in Cluster."
        {:error, why} -> why
      end

    {:noreply, assign(socket, message: message, config: Store.get())}
  end

  def handle_event("deploy", %{"target" => target}, socket) do
    project = socket.assigns.project

    message =
      case Operations.submit("Deploy #{project} to #{target}", fn ->
             Projects.deploy(project, target)
           end) do
        {:ok, _} -> "Deployment started. Its target and result will appear in Operations."
        {:error, reason} -> reason
      end

    {:noreply, assign(socket, message: message, config: Store.get())}
  end

  def handle_event("create-project", %{"name" => name}, socket) do
    case Projects.create(name) do
      {:ok, message} ->
        {:noreply,
         socket |> assign(projects: Projects.list(), message: message) |> select_project(name)}

      {:error, message} ->
        {:noreply, assign(socket, :message, message)}
    end
  end

  def handle_event("select-project", %{"project" => project}, socket),
    do: {:noreply, select_project(socket, project)}

  def handle_event("open-file", %{"file" => file}, socket) do
    case Projects.read(socket.assigns.project, file) do
      {:ok, source} -> {:noreply, assign(socket, file: file, source: source)}
      {:error, message} -> {:noreply, assign(socket, :message, message)}
    end
  end

  def handle_event("save-file", %{"file" => file, "source" => source}, socket) do
    case Projects.save(socket.assigns.project, file, source) do
      {:ok, message} ->
        {:ok, files} = Projects.files(socket.assigns.project)
        {:noreply, assign(socket, files: files, file: file, source: source, message: message)}

      {:error, message} ->
        {:noreply, assign(socket, :message, message)}
    end
  end

  def handle_event("project-action", %{"action" => action} = params, socket)
      when action in ~w(test format compile evaluate dependencies) do
    project = socket.assigns.project

    operation =
      %{
        "test" => :test,
        "format" => :format,
        "compile" => :compile,
        "evaluate" => :evaluate,
        "dependencies" => :dependencies
      }[
        action
      ]

    message =
      case Operations.submit("#{project}: #{action}", fn ->
             Projects.run(project, operation, params["expression"] || "")
           end) do
        {:ok, _} ->
          "#{String.capitalize(action)} started. Results appear below and in Operations."

        {:error, reason} ->
          reason
      end

    {:noreply, assign(socket, message: message, config: Store.get())}
  end

  def handle_event("instance", %{"action" => action}, socket)
      when action in ~w(start stop restart logs) do
    fun =
      case action do
        "start" -> &Instances.start/0
        "stop" -> &Instances.stop/0
        "restart" -> &Instances.restart/0
        "logs" -> &Instances.logs/0
      end

    message =
      case Operations.submit("Instances: " <> action, fun) do
        {:ok, _} -> "Operation started. Follow its progress in Operations."
        {:error, reason} -> reason
      end

    {:noreply, assign(socket, message: message, config: Store.get())}
  end

  def handle_event("register", %{"endpoint" => endpoint}, socket) do
    message =
      case Cluster.register(endpoint) do
        :ok -> "Physical node registered. Checking its status…"
        {:error, reason} -> reason
      end

    {:noreply, assign(socket, message: message, config: Store.get())}
  end

  def handle_event("forget-node", %{"endpoint" => endpoint}, socket) do
    :ok = Cluster.forget(endpoint)

    {:noreply,
     assign(socket, config: Store.get(), message: "Physical node removed from this workspace.")}
  end

  def handle_event("configure", params, socket) do
    with {nodes, ""} <- Integer.parse(params["nodes"] || ""),
         {memory, ""} <- Integer.parse(params["memory"] || ""),
         true <- nodes in 1..64 and memory in 512..65536 do
      :ok = Store.update(&Map.merge(&1, %{"nodes" => nodes, "memory" => memory}))
      {:noreply, assign(socket, config: Store.get(), message: "Instance settings saved.")}
    else
      _ -> {:noreply, assign(socket, :message, "Choose 1–64 nodes and 512–65536 MiB per node.")}
    end
  end

  defp select_project(socket, project) do
    case Projects.files(project) do
      {:ok, files} -> assign(socket, project: project, files: files, file: "", source: "")
      {:error, message} -> assign(socket, :message, message)
    end
  end

  @impl true
  def handle_info(:changed, socket), do: {:noreply, assign(socket, :config, Store.get())}

  def handle_info(:desktop_frame, socket) do
    if socket.assigns.section == "desktop",
      do: {:noreply, push_event(socket, "desktop-frame", Desktop.frame() || %{})},
      else: {:noreply, socket}
  end

  def handle_info(:cluster_changed, socket),
    do: {:noreply, assign(socket, :cluster, Cluster.snapshot())}

  defp instance_detail({:ok, status}), do: status["detail"]
  defp instance_detail({:error, reason}), do: reason

  defp unavailable?("logs", _), do: false
  defp unavailable?("start", {:ok, %{"state" => state}}), do: state == "running"
  defp unavailable?(_, {:ok, %{"state" => state}}), do: state != "running"
  defp unavailable?(_, _), do: true

  defp observer(snapshot),
    do: Enum.find(snapshot["members"] || [], %{}, &(&1["node"] == snapshot["observer"]["node"]))

  defp health(snapshot) do
    quorum = get_in(snapshot, ["system", "quorum"]) || %{}

    cond do
      quorum["quorum"] == false -> "No quorum"
      quorum["absent"] not in [nil, []] -> "Degraded"
      quorum["quorum"] == true -> "Healthy"
      true -> "Responding"
    end
  end

  defp memory(bytes) when is_number(bytes), do: "#{Float.round(bytes / 1_073_741_824, 1)} GiB"
  defp memory(_), do: "Unknown"

  defp utilization(value) when is_number(value), do: "#{round(value * 100)}%"
  defp utilization(_), do: "Unknown"

  @impl true
  def render(assigns) do
    ~H"""
    <p class="connection-notice" role="status">Connecting to the command node…</p>
    <div class="workspace" inert={not @ready}>
      <aside>
        <a class="brand" href="/">λ ElixirSSI<span>COMMAND NODE</span></a>
        <nav aria-label="Workspace">
          <button
            :for={
              {id, label} <- [
                {"cluster", "Cluster"},
                {"projects", "Projects"},
                {"console", "Console"},
                {"desktop", "Desktop"},
                {"operations", "Operations"}
              ]
            }
            phx-click="navigate"
            phx-value-section={id}
            aria-current={if @section == id, do: "page", else: "false"}
          >
            {label}
          </button>
        </nav>
        <p class="aside-note">Elixir, across every node.</p>
        <form method="post" action="/session">
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <input type="hidden" name="_method" value="delete" /><button class="quiet">Sign out</button>
        </form>
      </aside>
      <main>
        <header>
          <div>
            <p class="eyebrow">YOUR SINGLE SYSTEM IMAGE</p>
            <h1>{String.capitalize(@section)}</h1>
          </div>
          <span class="pill">Command node online</span>
        </header>
        <p :if={@message} class="notice" role="status">{@message}</p>
        <section :if={@section == "desktop"} class="panel">
          <h2>Cluster desktop</h2>
          <p>
            The cluster owns these applications and windows. Click the desktop to use its keyboard and mouse.
          </p>
          <p :if={@targets == []}>Connect a node in Console first.</p>
          <form :if={@targets != []} id="desktop-connect" phx-submit="desktop-connect">
            <label>
              Connect through<select name="target"><option :for={target <- @targets} value={target}>{String.replace(target, "|", ":")}</option></select>
            </label>
            <label>
              Command node address reachable from the Pi<input
                name="endpoint"
                value="host.docker.internal:4010"
                required
              />
            </label>
            <button>Connect desktop</button>
          </form>
          <div id="desktop-view" phx-hook="Desktop" phx-update="ignore">
            <p class="desktop-status" role="status">Waiting for the cluster desktop…</p>
            <canvas width="1280" height="800" tabindex="0" aria-label="Interactive ElixirSSI desktop">
            </canvas>
          </div>
        </section>
        <section :if={@section == "cluster"} class="panel">
          <h2>Local instances</h2>
          <p>Configure emulated Raspberry Pis. Each node keeps its own persistent disk.</p>
          <p role="status">{instance_detail(@cluster.instance)}</p>
          <div class="actions">
            <button
              :for={action <- ~w(start stop restart logs)}
              phx-click="instance"
              phx-value-action={action}
              disabled={
                unavailable?(action, @cluster.instance) or
                  Enum.any?(@config["operations"], &(&1["status"] == "running"))
              }
              data-confirm={
                if action in ["stop", "restart"],
                  do:
                    "#{String.capitalize(action)} the local cluster? Running work will be interrupted.",
                  else: nil
              }
            >
              {String.capitalize(action)}
            </button>
          </div>
          <form phx-submit="configure" id="instance-settings">
            <div class="fields">
              <label>
                Nodes<input
                  name="nodes"
                  type="number"
                  min="1"
                  max="64"
                  value={@config["nodes"]}
                  required
                />
              </label>
              <label>
                Memory per node (MiB)<input
                  name="memory"
                  type="number"
                  min="512"
                  max="65536"
                  value={@config["memory"]}
                  required
                />
              </label>
            </div>
            <button>Save settings</button>
          </form>
        </section>
        <section :if={@section == "cluster"} class="panel">
          <h2>Physical Raspberry Pis</h2>
          <p>Connect a Pi running ElixirSSI. Its lifecycle is independent of local emulation.</p>
          <form phx-submit="register" id="physical-node">
            <label>
              Node address<input
                name="endpoint"
                type="url"
                placeholder="http://192.168.1.20"
                required
              />
            </label>
            <button>Connect Pi</button>
          </form>
        </section>
        <section :if={@section == "cluster"} class="panel">
          <h2>Members</h2>
          <div class="member-grid">
            <article :for={member <- @cluster.members} class="member">
              <p class="eyebrow">{member.kind}</p>
              <%= case member.result do %>
                <% {:ok, snapshot} -> %>
                  <h3>{snapshot["observer"]["hostname"] || member.endpoint}</h3>
                  <span class="pill">{health(snapshot)}</span>
                  <p>
                    Sees {snapshot["system"]["members"]} members · {observer(snapshot)["cores"]} local cores
                  </p>
                  <dl class="metrics">
                    <dt>Memory</dt>
                    <dd>{memory(observer(snapshot)["memory"])}</dd>
                    <dt>CPU utilization</dt>
                    <dd>{utilization(get_in(observer(snapshot), ["load", "util"]))}</dd>
                    <dt>Processes</dt>
                    <dd>{get_in(observer(snapshot), ["load", "processes"])}</dd>
                  </dl>
                  <h4>Cluster services</h4>
                  <p :if={(snapshot["services"] || []) == []}>No registered services.</p>
                  <ul class="service-list">
                    <li :for={service <- snapshot["services"] || []}>
                      <strong>{service["name"]}</strong>
                      <span>
                        {if service["running"], do: "Running", else: "Stopped"} · {service["hostname"] ||
                          "Unassigned"}
                      </span>
                    </li>
                  </ul>
                  <details>
                    <summary>Technical details</summary>
                    <pre>{Jason.encode!(snapshot, pretty: true)}</pre>
                  </details>
                <% {:error, reason} -> %>
                  <h3>{member.endpoint}</h3>
                  <p>{reason}</p>
              <% end %>
              <button
                :if={member.kind == "Physical Pi"}
                class="quiet"
                phx-click="forget-node"
                phx-value-endpoint={member.endpoint}
                data-confirm="Remove this Pi from the workspace? The Pi will keep running."
              >
                Remove Pi
              </button>
            </article>
          </div>
        </section>
        <section :if={@section == "projects"} class="panel">
          <h2>Elixir projects</h2>
          <p>Develop for your cluster. Tests and evaluation run in an isolated Elixir environment.</p>
          <form phx-submit="create-project" id="create-project" class="actions">
            <label>
              New project<input
                name="name"
                placeholder="my_cluster_app"
                pattern="[a-z][a-z0-9_]*"
                required
              />
            </label>
            <button>Create project</button>
          </form>
          <div class="actions">
            <button
              :for={project <- @projects}
              phx-click="select-project"
              phx-value-project={project}
              class="quiet"
            >
              {project}
            </button>
          </div>
          <div :if={@project} class="editor-workspace">
            <h2>{@project}</h2>
            <div class="actions">
              <button
                :for={action <- ~w(test format compile dependencies)}
                phx-click="project-action"
                phx-value-action={action}
                disabled={Enum.any?(@config["operations"], &(&1["status"] == "running"))}
              >
                {String.capitalize(action)}
              </button>
            </div>
            <div class="editor-grid">
              <nav aria-label="Project files">
                <button
                  :for={file <- @files}
                  phx-click="open-file"
                  phx-value-file={file}
                  class="quiet"
                >
                  {file}
                </button>
              </nav>
              <form id="source-editor" phx-submit="save-file">
                <label>
                  File path<input name="file" value={@file} placeholder="lib/my_module.ex" required />
                </label>
                <label>
                  Elixir source<textarea name="source" rows="18" spellcheck="false">{@source}</textarea>
                </label>
                <button>Save file</button>
              </form>
            </div>
            <h2>Elixir evaluation</h2>
            <form phx-submit="project-action" id="evaluate">
              <input type="hidden" name="action" value="evaluate" />
              <label>
                Expression<textarea
                  name="expression"
                  rows="3"
                  placeholder="IO.inspect(Enum.sum(1..100))"
                  required
                ></textarea>
              </label>
              <button>Evaluate in project</button>
            </form>
            <h2>Deploy to the SSI</h2>
            <p :if={@targets == []}>Connect and trust a node in Console to enable deployment.</p>
            <form :if={@targets != []} phx-submit="deploy" id="deploy">
              <label>
                Deploy and start on<select name="target"><option
                    :for={target <- @targets}
                    value={target}
                  >{String.replace(target, "|", ":")}</option></select>
              </label>
              <button data-confirm="Compile and deploy this application to the selected node?">
                Deploy application
              </button>
            </form>
            <article :for={op <- Enum.take(@config["operations"], 3)} class="operation">
              <h3>{op["label"]} · {op["status"]}</h3>
              <pre>{op["result"]}</pre>
            </article>
          </div>
        </section>
        <section :if={@section == "console"} class="panel">
          <h2>Connect to a node</h2>
          <p>
            Verify the SSH fingerprint before trusting a Pi. Local emulators use ports 2321, 2322 and 2323; physical Pis normally use port 22.
          </p>
          <form phx-submit="probe-ssh" id="probe-ssh">
            <div class="fields">
              <label>SSH host<input name="host" required placeholder="host.docker.internal" /></label>
              <label>
                SSH port<input name="port" type="number" value="2321" min="1" max="65535" required />
              </label>
            </div>
            <button>Inspect identity</button>
          </form>
          <form :if={@ssh_probe} phx-submit="trust-ssh" id="trust-ssh">
            <h3>{@ssh_probe.host}:{@ssh_probe.port}</h3>
            <p>Compare this fingerprint with the node's trusted SSH identity:</p>
            <pre>{@ssh_probe.fingerprint}</pre>
            <label>
              SSH password<input name="password" type="password" required autocomplete="off" />
            </label>
            <button>Trust identity and connect</button>
          </form>
        </section>
        <section :if={@section == "console" and @targets != []} class="panel">
          <h2>Inspect a node</h2>
          <form phx-submit="inspect-node" id="inspect-node">
            <label>
              Target<select name="target"><option :for={target <- @targets} value={target}>{String.replace(target, "|", ":")}</option></select>
            </label>
            <label>
              View<select name="action"><option value="processes">Processes by memory</option><option value="logs">Kernel log</option><option value="services">Cluster services</option></select>
            </label>
            <button>Inspect node</button>
          </form>
          <h2>Move a service</h2>
          <form phx-submit="move-service" id="move-service">
            <label>
              Execute through<select name="target"><option :for={target <- @targets} value={target}>{String.replace(target, "|", ":")}</option></select>
            </label>
            <label>Service name<input name="service" required placeholder="desktop" /></label>
            <label>
              Destination node<input name="destination" required placeholder="ssi@169.254.1.2" />
            </label>
            <button data-confirm="Move this service to the named cluster member?">
              Move service
            </button>
          </form>
          <h2>Elixir on the cluster</h2>
          <p>
            Runs with the selected node's operator authority. Use this console for processes, services and system operations.
          </p>
          <form phx-submit="remote-evaluate" id="remote-evaluate">
            <label>
              Target<select name="target"><option :for={target <- @targets} value={target}>{String.replace(target, "|", ":")}</option></select>
            </label>
            <label>
              Elixir expression<textarea
                name="source"
                rows="6"
                required
                placeholder="SSI.Cluster.members()"
              ></textarea>
            </label>
            <button data-confirm="Execute this Elixir expression on the selected node?">
              Run on node
            </button>
          </form>
        </section>
        <section :if={@section in ["operations", "console"]} class="panel">
          <h2>Operation history</h2>
          <p :if={@config["operations"] == []}>No operations yet.</p>
          <article :for={op <- @config["operations"]} class="operation">
            <h3>{op["label"]} <span class="pill">{op["status"]}</span></h3>
            <p>{op["started_at"]}</p>
            <pre>{op["result"]}</pre>
          </article>
        </section>
      </main>
    </div>
    """
  end
end
