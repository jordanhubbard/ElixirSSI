defmodule ElixirSSI.CommandWeb.FilesLive do
  use Phoenix.LiveView

  alias ElixirSSI.Command.{
    FileCopies,
    FileSpaces,
    FolderSync,
    LinkedFolders,
    LocalFiles,
    ProjectArchive,
    Projects,
    Operations,
    Store
  }

  @impl true
  def mount(_, _, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(ElixirSSI.Command.PubSub, "command")

    {:ok,
     socket
     |> assign(
       ready: connected?(socket),
       spaces: FileSpaces.list(),
       links: LinkedFolders.list(),
       sync_plan: nil,
       sync_records: Store.get()["folder_sync"] || %{},
       operation_id: nil,
       operations: Store.get()["operations"],
       active: "left",
       panes: %{"left" => empty_pane(), "right" => empty_pane()},
       tool: nil,
       space: "",
       directory: "",
       entries: [],
       selected: nil,
       source: nil,
       revision: nil,
       transfer: nil,
       message: nil,
       busy: false
     )
     |> allow_upload(:files,
       accept: :any,
       auto_upload: true,
       max_entries: 10,
       max_file_size: LocalFiles.limits().file
     )
     |> allow_upload(:project,
       accept: ~w(.zip),
       auto_upload: true,
       max_entries: 1,
       max_file_size: LocalFiles.limits().tree
     )}
  end

  @impl true
  def handle_params(params, _, socket) do
    spaces = socket.assigns.spaces
    default_local = Enum.find(spaces, &String.starts_with?(&1.id, ["project:", "link:"]))
    default_remote = Enum.find(spaces, &String.starts_with?(&1.id, ["cluster:", "node:"]))
    requested = params["space"]

    active =
      params["active"] ||
        if(requested && String.starts_with?(requested, ["cluster:", "node:"]),
          do: "right",
          else: "left"
        )

    active = if active in ["left", "right"], do: active, else: "left"

    panes =
      Map.new(socket.assigns.panes, fn {side, pane} ->
        fallback = if side == "left", do: default_local, else: default_remote
        space = params[side] || if(side == active && requested, do: requested, else: pane.space)
        space = if space in [nil, ""], do: (fallback || %{id: ""}).id, else: space

        directory =
          params[side <> "_path"] ||
            if(side == active, do: params["path"] || "", else: pane.directory)

        pane = if pane.space != space || pane.directory != directory, do: empty_pane(), else: pane
        {side, %{pane | space: space, directory: directory}}
      end)

    {:noreply,
     socket |> assign(active: active, panes: panes, tool: nil, transfer: nil) |> load_panes()}
  end

  defp empty_pane,
    do: %{
      space: "",
      directory: "",
      entries: [],
      selected: nil,
      source: nil,
      revision: nil,
      error: nil
    }

  defp other("left"), do: "right"
  defp other("right"), do: "left"

  defp remember(socket),
    do:
      assign(socket,
        panes:
          Map.put(
            socket.assigns.panes,
            socket.assigns.active,
            Map.take(socket.assigns, [:space, :directory, :entries, :selected, :source, :revision])
            |> Map.put(:error, socket.assigns.panes[socket.assigns.active].error)
          )
      )

  defp activate(socket, side) when side in ["left", "right"] do
    socket = remember(socket)
    socket |> assign(active: side) |> assign(Map.drop(socket.assigns.panes[side], [:error]))
  end

  defp pane_location(socket, side, space, path) do
    params = Map.new(socket.assigns.panes, fn {key, pane} -> {key, pane.space} end)

    params =
      Enum.reduce(socket.assigns.panes, params, fn {key, pane}, acc ->
        Map.put(acc, key <> "_path", pane.directory)
      end)

    "/files?" <>
      URI.encode_query(
        params
        |> Map.put(side, space)
        |> Map.put(side <> "_path", path)
        |> Map.put("active", side)
        |> Map.put("space", space)
        |> Map.put("path", path)
      )
  end

  defp load_panes(socket) do
    panes = socket.assigns.panes

    fun = fn ->
      Map.new(panes, fn {side, pane} ->
        result =
          if pane.space == "",
            do: {:ok, []},
            else: FileSpaces.call(pane.space, :list, [pane.directory])

        {side, result}
      end)
    end

    if Enum.any?(panes, fn {_, pane} ->
         String.starts_with?(pane.space, ["cluster:", "node:", "link:"])
       end) do
      socket |> assign(busy: true) |> start_async(:pane_lists, fun)
    else
      finish_panes(socket, fun.())
    end
  end

  defp finish_panes(socket, results) do
    panes =
      Map.new(socket.assigns.panes, fn {side, pane} ->
        case results[side] do
          {:ok, entries} ->
            pane =
              if pane.selected &&
                   not Enum.any?(entries, &(&1.path == pane.selected && &1.type == :regular)),
                 do: %{pane | selected: nil, source: nil, revision: nil},
                 else: pane

            {side, %{pane | entries: entries, error: nil}}

          error ->
            {side,
             %{
               pane
               | entries: [],
                 selected: nil,
                 source: nil,
                 revision: nil,
                 error: FileSpaces.message(error)
             }}
        end
      end)

    socket
    |> assign(panes: panes, busy: false)
    |> assign(Map.drop(panes[socket.assigns.active], [:error]))
  end

  @impl true
  def handle_event(_, _, %{assigns: %{busy: true}} = socket), do: {:noreply, socket}

  def handle_event("pane-rename", %{"side" => side} = params, socket)
      when side in ["left", "right"], do: handle_event("rename", params, activate(socket, side))

  def handle_event("pane-delete-folder", %{"side" => side, "path" => path}, socket)
      when side in ["left", "right"],
      do:
        handle_event(
          "delete",
          %{"path" => path, "revision" => "empty_directory"},
          activate(socket, side)
        )

  def handle_event("pane-browse", %{"side" => side, "space" => space, "path" => path}, socket)
      when side in ["left", "right"],
      do: {:noreply, push_patch(remember(socket), to: pane_location(socket, side, space, path))}

  def handle_event("pane-directory", %{"side" => side, "path" => path}, socket)
      when side in ["left", "right"],
      do:
        {:noreply,
         push_patch(remember(socket),
           to: pane_location(socket, side, socket.assigns.panes[side].space, path)
         )}

  def handle_event("pane-select", %{"side" => side, "path" => path}, socket)
      when side in ["left", "right"] do
    socket = activate(socket, side)

    if Enum.any?(socket.assigns.entries, &(&1.path == path && &1.type == :regular)) do
      {:noreply,
       socket
       |> assign(selected: path, source: nil, revision: nil, tool: nil, transfer: nil)
       |> remember()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("pane-activate", %{"side" => side}, socket) when side in ["left", "right"],
    do: {:noreply, socket |> activate(side) |> assign(tool: nil)}

  def handle_event("tool", %{"name" => name}, socket)
      when name in ["create", "upload", "links", "projects", "rename", "sync"],
      do: {:noreply, assign(socket, tool: if(socket.assigns.tool == name, do: nil, else: name))}

  def handle_event("close-tool", _, socket), do: {:noreply, assign(socket, tool: nil)}

  def handle_event("edit-selected", _, %{assigns: %{selected: path}} = socket)
      when is_binary(path),
      do: handle_event("open-file", %{"path" => path}, socket)

  def handle_event("copy-direction", %{"side" => side}, socket) when side in ["left", "right"] do
    socket = activate(socket, side)
    destination = socket.assigns.panes[other(side)]

    if socket.assigns.selected && destination.space != "" && !destination.error do
      handle_event(
        "preview-copy",
        %{
          "space" => destination.space,
          "path" => child(destination.directory, Path.basename(socket.assigns.selected))
        },
        socket
      )
    else
      {:noreply, assign(socket, message: "Select a file and open a destination folder.")}
    end
  end

  def handle_event("sync-panes", _, socket) do
    socket = remember(socket)

    {:noreply,
     preview_sync(
       assign(socket, tool: "sync"),
       Map.take(socket.assigns.panes["left"], [:space, :directory])
       |> then(&%{space: &1.space, path: &1.directory}),
       Map.take(socket.assigns.panes["right"], [:space, :directory])
       |> then(&%{space: &1.space, path: &1.directory})
     )}
  end

  def handle_event("preview-copy", %{"space" => destination, "path" => path}, socket) do
    source = socket.assigns.space
    selected = socket.assigns.selected

    {:noreply,
     socket
     |> assign(busy: true, transfer: nil, message: "Checking source and destination…")
     |> start_async(:copy_preview, fn ->
       FileCopies.preview(source, selected, destination, path)
     end)}
  end

  def handle_event("apply-copy", _, %{assigns: %{transfer: plan}} = socket) when is_map(plan) do
    {:noreply,
     socket
     |> assign(busy: true, transfer: nil, message: "Copying file…")
     |> start_async(:copy_apply, fn -> FileCopies.apply(plan) end)}
  end

  def handle_event("cancel-copy", _, socket), do: {:noreply, assign(socket, transfer: nil)}

  def handle_event("preview-saved-sync", %{"id" => id}, socket) do
    case Map.get(Store.get()["folder_sync"] || %{}, id) do
      nil ->
        {:noreply, assign(socket, message: "This synchronization baseline is unavailable.")}

      record ->
        {:noreply,
         preview_sync(
           socket,
           %{space: record["left"]["space"], path: record["left"]["path"]},
           %{space: record["right"]["space"], path: record["right"]["path"]}
         )}
    end
  end

  def handle_event("resolve-sync", params, %{assigns: %{sync_plan: plan}} = socket)
      when is_map(plan) do
    choices =
      plan.conflicts
      |> Enum.with_index()
      |> Map.new(fn {conflict, index} -> {conflict.path, params["choice_#{index}"]} end)

    {:noreply,
     assign(socket,
       sync_plan: FolderSync.resolve(plan, Map.merge(plan.choices, choices)),
       message: "Review the resolved changes before applying."
     )}
  end

  def handle_event("apply-sync", _, %{assigns: %{sync_plan: %{conflicts: []} = plan}} = socket) do
    case Operations.submit("Synchronize folders: #{plan.left.path} ↔ #{plan.right.path}", fn ->
           FolderSync.apply(plan)
         end) do
      {:ok, id} ->
        {:noreply,
         assign(socket,
           operation_id: id,
           sync_plan: nil,
           busy: true,
           message: "Synchronizing folders. Progress is retained in Operations."
         )}

      error ->
        {:noreply, assign(socket, message: FileSpaces.message(error))}
    end
  end

  def handle_event("cancel-sync", _, socket), do: {:noreply, assign(socket, sync_plan: nil)}

  def handle_event("link-folder", %{"name" => name, "path" => path} = params, socket) do
    writable = params["writable"] == "true"

    {:noreply,
     socket
     |> assign(busy: true, message: "Checking the selected host folder…")
     |> start_async(:link_folder, fn -> LinkedFolders.register(name, path, writable) end)}
  end

  def handle_event("unlink-folder", %{"id" => id}, socket) do
    :ok = LinkedFolders.unlink(id)

    socket = remember(socket)

    panes =
      Map.new(socket.assigns.panes, fn {side, pane} ->
        {side, if(pane.space == "link:" <> id, do: empty_pane(), else: pane)}
      end)

    {:noreply,
     socket
     |> assign(panes: panes, links: LinkedFolders.list(), spaces: FileSpaces.list())
     |> push_patch(to: "/files")}
  end

  def handle_event("open-file", %{"path" => path}, socket) do
    space = socket.assigns.space
    {:noreply, perform(socket, {:opened, path}, fn -> FileSpaces.call(space, :read, [path]) end)}
  end

  def handle_event("save", %{"source" => source}, socket) do
    %{space: space, selected: selected, revision: revision} = socket.assigns

    {:noreply,
     perform(socket, :saved, fn ->
       FileSpaces.call(space, :write, [selected, source, revision])
     end)}
  end

  def handle_event("create", %{"name" => name, "kind" => kind}, socket) do
    space = socket.assigns.space
    path = child(socket.assigns.directory, name)

    {:noreply,
     perform(socket, :mutated, fn ->
       case kind do
         "folder" -> FileSpaces.call(space, :mkdir, [path])
         "file" -> FileSpaces.call(space, :write, [path, ""])
         _ -> {:error, "Choose file or folder."}
       end
     end)}
  end

  def handle_event("rename", %{"from" => from, "to" => to}, socket) do
    space = socket.assigns.space
    destination = child(socket.assigns.directory, to)

    {:noreply,
     perform(socket, :mutated, fn -> FileSpaces.call(space, :rename, [from, destination]) end)}
  end

  def handle_event("delete", %{"path" => path, "revision" => revision}, socket) do
    space = socket.assigns.space
    expected = if revision == "empty_directory", do: :empty_directory, else: revision

    {:noreply,
     perform(socket, :mutated, fn -> FileSpaces.call(space, :remove, [path, expected]) end)}
  end

  def handle_event("validate-upload", _, socket), do: {:noreply, socket}

  def handle_event("cancel-upload", %{"ref" => ref, "kind" => kind}, socket)
      when kind in ["files", "project"],
      do: {:noreply, cancel_upload(socket, if(kind == "files", do: :files, else: :project), ref)}

  def handle_event("upload", _, socket) do
    # Copy the bounded uploads out of LiveView's temporary storage before starting SSH work.
    uploads =
      consume_uploaded_entries(socket, :files, fn %{path: temp}, entry ->
        {:ok, {entry.client_name, File.read(temp)}}
      end)

    space = socket.assigns.space
    directory = socket.assigns.directory

    {:noreply,
     perform(socket, :uploaded, fn ->
       Enum.map_join(uploads, " · ", fn {name, content} ->
         result =
           with {:ok, bytes} <- content,
                do: FileSpaces.call(space, :write, [child(directory, name), bytes])

         "#{name}: #{FileSpaces.message(result)}"
       end)
     end)}
  end

  def handle_event("import-project", %{"name" => name}, socket) do
    results =
      consume_uploaded_entries(socket, :project, fn %{path: temp}, _ ->
        result = with {:ok, bytes} <- File.read(temp), do: ProjectArchive.import(name, bytes)
        {:ok, result}
      end)

    case results do
      [{:ok, _}] ->
        {:noreply,
         socket
         |> assign(spaces: FileSpaces.list())
         |> push_patch(to: location("project:" <> name, ""))}

      [error] ->
        {:noreply, assign(socket, message: FileSpaces.message(error))}

      _ ->
        {:noreply, assign(socket, message: "Choose a project ZIP to import.")}
    end
  end

  def handle_event("new-project", %{"name" => name}, socket) do
    case Projects.create(name) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(spaces: FileSpaces.list())
         |> push_patch(to: location("project:" <> name, ""))}

      error ->
        {:noreply, assign(socket, message: FileSpaces.message(error))}
    end
  end

  defp preview_sync(socket, left, right) do
    socket
    |> assign(
      busy: true,
      sync_plan: nil,
      message: "Comparing both folders with the last successful synchronization…"
    )
    |> start_async(:sync_preview, fn -> FolderSync.preview(left, right) end)
  end

  defp perform(socket, kind, fun) do
    if String.starts_with?(socket.assigns.space, ["cluster:", "node:", "link:"]) do
      socket
      |> assign(busy: true, message: "Working with the selected node…")
      |> start_async(:file_job, fn -> {kind, fun.()} end)
    else
      finish_job(socket, kind, fun.())
    end
  end

  defp finish_job(socket, {:opened, path}, {:ok, bytes}) do
    source =
      if byte_size(bytes) <= 524_288 and String.valid?(bytes) and
           not String.contains?(bytes, <<0>>),
         do: bytes

    assign(socket,
      busy: false,
      selected: path,
      source: source,
      revision: LocalFiles.digest(bytes),
      message: nil,
      tool: "edit"
    )
    |> remember()
  end

  defp finish_job(socket, :saved, {:ok, revision}),
    do: assign(socket, busy: false, revision: revision, message: "File saved.") |> remember()

  defp finish_job(socket, :mutated, {:error, _} = result),
    do: assign(socket, busy: false, message: FileSpaces.message(result))

  defp finish_job(socket, :mutated, result), do: refresh(assign(socket, busy: false), result)

  defp finish_job(socket, :uploaded, message),
    do: refresh(assign(socket, busy: false), {:ok, nil}) |> assign(message: message)

  defp finish_job(socket, _, result),
    do: assign(socket, busy: false, message: FileSpaces.message(result))

  defp refresh(socket, result) do
    socket
    |> assign(selected: nil, source: nil, revision: nil, tool: nil)
    |> remember()
    |> load_panes()
    |> assign(message: FileSpaces.message(result))
  end

  defp child("", name), do: name
  defp child(directory, name), do: directory <> "/" <> name
  defp location(space, path), do: "/files?" <> URI.encode_query(%{space: space, path: path})

  defp download(space, path),
    do: "/files/download?" <> URI.encode_query(%{space: space, path: path})

  defp parent(path), do: if(Path.dirname(path) == ".", do: "", else: Path.dirname(path))
  defp upload_message(:too_large), do: "File exceeds the transfer limit."
  defp upload_message(:too_many_files), do: "Too many files selected."
  defp upload_message(:not_accepted), do: "Choose a ZIP archive."
  defp upload_message(_), do: "Upload failed. Please retry."

  @impl true
  def handle_async(:pane_lists, {:ok, results}, socket),
    do: {:noreply, finish_panes(socket, results)}

  def handle_async(:sync_preview, {:ok, {:ok, plan}}, socket),
    do:
      {:noreply,
       assign(socket,
         busy: false,
         sync_plan: plan,
         message: "Preview ready. No files have changed."
       )}

  def handle_async(:link_folder, {:ok, {:ok, link}}, socket) do
    {:noreply,
     socket
     |> assign(busy: false, links: LinkedFolders.list(), spaces: FileSpaces.list())
     |> push_patch(to: location("link:" <> link["id"], ""))}
  end

  def handle_async(:file_job, {:ok, {kind, result}}, socket),
    do: {:noreply, finish_job(socket, kind, result)}

  def handle_async(:copy_preview, {:ok, {:ok, plan}}, socket),
    do:
      {:noreply,
       assign(socket,
         busy: false,
         transfer: plan,
         message: "Review the copy destination before applying."
       )}

  def handle_async(:copy_apply, {:ok, {:ok, message}}, socket),
    do: {:noreply, socket |> remember() |> load_panes() |> assign(message: message)}

  def handle_async(_, {:ok, error}, socket),
    do: {:noreply, assign(socket, busy: false, message: FileSpaces.message(error))}

  def handle_async(_, {:exit, _}, socket),
    do:
      {:noreply,
       assign(socket,
         busy: false,
         message: "File operation interrupted. Refresh before retrying."
       )}

  @impl true
  def handle_info(:cluster_changed, socket), do: {:noreply, socket}

  def handle_info(:changed, socket) do
    state = Store.get()

    socket =
      assign(socket,
        operations: state["operations"],
        sync_records: state["folder_sync"] || %{},
        links: LinkedFolders.list(),
        spaces: FileSpaces.list()
      )

    operation = Enum.find(state["operations"], &(&1["id"] == socket.assigns.operation_id))

    if operation && operation["status"] != "running" do
      {:noreply,
       socket
       |> assign(busy: false, operation_id: nil)
       |> remember()
       |> load_panes()
       |> assign(message: operation["result"])}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <p class="connection-notice" role="status">Connecting to the command node…</p>
    <div class="workspace" inert={not @ready}>
      <aside>
        <a class="brand" href="/">λ ElixirSSI<span>COMMAND NODE</span></a>
        <nav aria-label="Workspace">
          <a
            :for={section <- ~w(cluster projects console desktop operations)}
            href={"/?section=" <> section}
          >
            {String.capitalize(section)}
          </a>
          <a href="/files" aria-current="page">Files</a>
        </nav>
        <p class="aside-note">
          Select a file, then copy it to the folder in the opposite pane.
        </p>
      </aside>
      <main>
        <header>
          <div>
            <p class="eyebrow">YOUR SINGLE SYSTEM IMAGE</p>
            <h1>Files</h1>
          </div>
          <span class="pill" role="status">
            {if @busy, do: "Working…", else: "Command node online"}
          </span>
        </header>
        <p :if={@message} class="notice" role="status">{@message}</p>
        <fieldset class="file-controls" disabled={@busy} aria-busy={to_string(@busy)}>
          <div class="commander" id="file-browser">
            <.file_pane
              side="left"
              title="Local"
              subtitle="Command node & linked folders"
              pane={@panes["left"]}
              spaces={@spaces}
              active={@active}
            />
            <div class="transfer-controls" aria-label="Transfer files">
              <button
                id="copy-right"
                phx-click="copy-direction"
                phx-value-side="left"
                disabled={
                  is_nil(@panes["left"].selected) or @panes["right"].space == "" or
                    not is_nil(@panes["right"].error)
                }
                aria-label="Copy local to remote"
                title="Copy selected local file to the remote folder"
              >
                →<span>Copy to remote</span>
              </button>
              <button
                id="copy-left"
                phx-click="copy-direction"
                phx-value-side="right"
                disabled={
                  is_nil(@panes["right"].selected) or @panes["left"].space == "" or
                    not is_nil(@panes["left"].error)
                }
                aria-label="Copy remote to local"
                title="Copy selected remote file to the local folder"
              >
                ←<span>Copy to local</span>
              </button>
            </div>
            <.file_pane
              side="right"
              title="Remote"
              subtitle="Cluster & node files"
              pane={@panes["right"]}
              spaces={@spaces}
              active={@active}
            />
          </div>
          <div class="file-toolbar" aria-label="File actions">
            <span>
              {if @active == "left", do: "Local", else: "Remote"}{if @selected,
                do: " · " <> Path.basename(@selected)}
            </span>
            <button class="quiet" phx-click="edit-selected" disabled={is_nil(@selected)}>Edit</button>
            <button
              class="quiet"
              phx-click="tool"
              phx-value-name="rename"
              disabled={is_nil(@selected)}
            >
              Rename
            </button>
            <button class="quiet" phx-click="tool" phx-value-name="create" disabled={@space == ""}>
              New…
            </button>
            <button class="quiet" phx-click="tool" phx-value-name="upload" disabled={@space == ""}>
              Upload…
            </button>
            <a :if={@selected} class="file-link" href={download(@space, @selected)} download>
              Download file
            </a>
            <button class="quiet" phx-click="tool" phx-value-name="links">Link folder…</button>
            <button class="quiet" phx-click="tool" phx-value-name="projects">Project ZIP…</button>
            <button class="quiet" phx-click="tool" phx-value-name="sync">Synchronize…</button>
          </div>
          <section :if={@tool} class="panel context-panel">
            <button class="quiet close-tool" phx-click="close-tool" aria-label="Close file tool">
              Close
            </button>
            <h2>
              {%{
                "create" => "New file or folder",
                "upload" => "Upload files",
                "rename" => "Rename file",
                "edit" => "Edit file",
                "links" => "Linked folders",
                "projects" => "Project archives",
                "sync" => "Synchronize folders"
              }[@tool]}
            </h2>
            <p :if={@tool in ["create", "upload", "rename", "edit"]}>{@space}/{@directory}</p>
            <div :if={@tool == "create"}>
              <form id="create-entry" phx-submit="create" class="fields">
                <label>Name<input name="name" required /></label><label>Type<select name="kind"><option value="file">File</option><option value="folder">Folder</option></select></label><button>Create</button>
              </form>
            </div>
            <div :if={@tool == "upload"}>
              <form id="upload-files" phx-submit="upload" phx-change="validate-upload">
                <label>
                  Upload files (up to 16 MiB each)<.live_file_input upload={@uploads.files} />
                </label>
                <p>
                  Existing files are preserved. Open a text file to edit it, or explicitly delete it before uploading a replacement.
                </p>
                <div :for={entry <- @uploads.files.entries}>
                  {entry.client_name} · {entry.progress}%
                  <button
                    type="button"
                    phx-click="cancel-upload"
                    phx-value-kind="files"
                    phx-value-ref={entry.ref}
                    class="quiet"
                  >
                    Cancel
                  </button>
                  <p :for={error <- upload_errors(@uploads.files, entry)}>{upload_message(error)}</p>
                </div>
                <p :for={error <- upload_errors(@uploads.files)}>{upload_message(error)}</p>
                <button disabled={
                  @uploads.files.entries == [] or Enum.any?(@uploads.files.entries, &(!&1.done?))
                }>
                  Upload to this folder
                </button>
              </form>
            </div>
            <form
              :if={@tool == "rename" && @selected}
              id="rename-file"
              phx-submit="rename"
              class="fields"
            >
              <input type="hidden" name="from" value={@selected} />
              <label>New name<input name="to" value={Path.basename(@selected)} required /></label><button>Rename</button>
            </form>
            <section :if={@tool == "edit" && @selected}>
              <h2>{@selected}</h2>
              <form :if={@source != nil} id="file-editor" phx-submit="save">
                <label>
                  Contents<textarea name="source" rows="18" spellcheck="false">{@source}</textarea>
                </label>
                <button>Save file</button>
              </form>
              <p :if={@source == nil}>This binary or large file can be downloaded.</p>
              <div class="actions">
                <button
                  phx-click="delete"
                  phx-value-path={@selected}
                  phx-value-revision={@revision}
                  data-confirm={"Delete " <> @selected <> "?"}
                  class="danger"
                >
                  Delete file
                </button>
              </div>
            </section>
            <section :if={@tool == "sync"}>
              <p>
                Compare this folder with another location. Review additions, updates and deletions before applying. Files changed on both sides require a choice. Nothing runs in the background.
              </p>
              <p>Excluded at every level: {Enum.join(FolderSync.excluded(), ", ")}.</p>
              <p>
                Local: {@panes["left"].space}/{@panes["left"].directory}<br />Remote: {@panes["right"].space}/{@panes[
                  "right"
                ].directory}
              </p>
              <button
                id="preview-sync"
                phx-click="sync-panes"
                disabled={@panes["left"].space == "" or @panes["right"].space == ""}
              >
                Compare open folders
              </button>
              <details :if={map_size(@sync_records) > 0}>
                <summary>Previous folder pairs</summary>
                <div :for={{id, record} <- @sync_records} class="operation">
                  <p>
                    {record["left"]["space"]}/{record["left"]["path"]} ↔ {record["right"]["space"]}/{record[
                      "right"
                    ]["path"]}
                  </p>
                  <p>Last synchronized: {record["completed_at"]}</p>
                  <button phx-click="preview-saved-sync" phx-value-id={id} disabled={@busy}>
                    Compare again
                  </button>
                </div>
              </details>
              <div :if={@sync_plan} id="sync-preview" class="notice">
                <p>
                  Left: {@sync_plan.left.space}/{@sync_plan.left.path}<br />Right: {@sync_plan.right.space}/{@sync_plan.right.path}
                </p>
                <p :if={@sync_plan.baseline_record == nil}>
                  First synchronization: unrelated files are preserved and differences require a choice.
                </p>
                <form :if={@sync_plan.conflicts != []} id="resolve-sync" phx-submit="resolve-sync">
                  <h3>Resolve conflicts</h3>
                  <p>
                    Choosing a deleted version deletes the other copy. A folder choice applies to its entire subtree. To keep both versions, rename one before making a new preview.
                  </p>
                  <label :for={{conflict, index} <- Enum.with_index(@sync_plan.conflicts)}>
                    {conflict.path}
                    <select name={"choice_#{index}"} required>
                      <option value="">Choose which version to keep</option>
                      <option value="left">Left · {conflict.left}</option>
                      <option value="right">Right · {conflict.right}</option>
                    </select>
                  </label>
                  <button>Review resolved changes</button>
                </form>
                <h3>Proposed changes</h3>
                <p :if={@sync_plan.operations == [] and @sync_plan.conflicts == []}>
                  Both folders already agree. Apply to save their baseline.
                </p>
                <ul class="sync-changes">
                  <li :for={op <- @sync_plan.operations}>
                    <strong>{op.side}</strong>
                    · {case op.action do
                      :delete -> "Delete"
                      :mkdir -> "Create folder"
                      :write -> if(op.before, do: "Replace file", else: "Create file")
                    end} · {op.path}
                  </li>
                </ul>
                <p>
                  Applying rechecks both folders. If a transfer fails, earlier listed changes may have completed; no new baseline is saved until both folders agree.
                </p>
                <button
                  phx-click="apply-sync"
                  disabled={@busy or @sync_plan.conflicts != []}
                  data-confirm="Apply all listed changes, including any overwrites and deletions?"
                >
                  Apply synchronization
                </button>
                <button phx-click="cancel-sync" class="quiet">Discard preview</button>
              </div>
              <article
                :for={
                  op <-
                    Enum.filter(
                      @operations,
                      &String.starts_with?(&1["label"], "Synchronize folders:")
                    )
                    |> Enum.take(3)
                }
                class="operation"
              >
                <h3>{op["label"]} · {op["status"]}</h3>
                <p>{op["result"]}</p>
              </article>
            </section>
            <section :if={@tool == "links"}>
              <p>
                Link an existing folder on the command node's Docker host. On this installation that is your workstation, even when the browser is on another computer. Unlinking preserves the folder and its contents.
              </p>
              <ul class="file-list">
                <li :for={link <- @links}>
                  <a class="file-link" href={location("link:" <> link["id"], "")}>{link["name"]}</a>
                  <span>
                    {link["host_path"]} · {if link["writable"],
                      do: "read and write",
                      else: "read-only"}
                  </span>
                  <button
                    phx-click="unlink-folder"
                    phx-value-id={link["id"]}
                    data-confirm="Unlink this folder? Its files will be preserved."
                    class="quiet"
                  >
                    Unlink
                  </button>
                </li>
              </ul>
              <form
                id="link-folder"
                phx-submit="link-folder"
                data-confirm="Make the selected host folder accessible through this authenticated workspace?"
              >
                <label>Display name<input name="name" required /></label>
                <label>
                  Absolute host folder path<input
                    name="path"
                    required
                    placeholder="/Users/you/Src/my_project"
                  />
                </label>
                <label>
                  Access<select name="writable"><option value="false">Read-only</option><option value="true">Allow reading and writing</option></select>
                </label>
                <button disabled={@busy}>Link folder</button>
              </form>
            </section>
            <section :if={@tool == "projects"}>
              <a
                :if={String.starts_with?(@space, "project:")}
                class="file-link"
                href={"/files/export?" <> URI.encode_query(%{project: String.replace_prefix(@space, "project:", "")})}
                download
              >
                Download project ZIP
              </a>
              <form id="new-file-project" phx-submit="new-project" class="fields">
                <label>
                  New project name<input name="name" required pattern="[a-z][a-z0-9_]*" />
                </label>
                <button>Create project</button>
              </form>
              <form id="import-project" phx-submit="import-project" phx-change="validate-upload">
                <label>
                  Imported project name<input name="name" required pattern="[a-z][a-z0-9_]*" />
                </label>
                <label>Project ZIP<.live_file_input upload={@uploads.project} /></label>
                <p>
                  ZIP must contain mix.exs at its root. Build output and dependencies are excluded. Import creates a new project.
                </p>
                <div :for={entry <- @uploads.project.entries}>
                  {entry.client_name} · {entry.progress}%
                  <button
                    type="button"
                    phx-click="cancel-upload"
                    phx-value-kind="project"
                    phx-value-ref={entry.ref}
                    class="quiet"
                  >
                    Cancel
                  </button>
                  <p :for={error <- upload_errors(@uploads.project, entry)}>
                    {upload_message(error)}
                  </p>
                </div>
                <p :for={error <- upload_errors(@uploads.project)}>{upload_message(error)}</p>
                <button disabled={
                  @uploads.project.entries == [] or Enum.any?(@uploads.project.entries, &(!&1.done?))
                }>
                  Import project
                </button>
              </form>
            </section>
          </section>
          <div :if={@transfer} class="notice" id="copy-preview">
            <p>
              Copy {@transfer.size} bytes from {@transfer.source_space}/{@transfer.source_path} to {@transfer.destination_space}/{@transfer.destination_path}.
            </p>
            <p>
              {if @transfer.destination_revision == :missing,
                do: "Creates a new file.",
                else: "Replaces the existing destination file."}
            </p>
            <button
              phx-click="apply-copy"
              disabled={@busy}
              data-confirm="Apply this reviewed copy? Existing destination contents may be replaced."
            >
              Apply copy
            </button>
            <button phx-click="cancel-copy" class="quiet">Cancel</button>
          </div>
        </fieldset>
      </main>
    </div>
    """
  end

  defp file_pane(assigns) do
    ~H"""
    <section
      id={"pane-" <> @side}
      class={["file-pane", @active == @side && "active-pane"]}
      aria-label={@title <> " files"}
    >
      <div class="pane-heading">
        <button
          class="quiet"
          phx-click="pane-activate"
          phx-value-side={@side}
          aria-pressed={to_string(@active == @side)}
        >
          {@title}
        </button>
        <span>{@subtitle}</span>
      </div>
      <form id={"location-" <> @side} phx-submit="pane-browse" class="pane-location">
        <input type="hidden" name="side" value={@side} />
        <label>
          Location<select name="space" aria-label={@title <> " location"}><option value="">Choose a location</option><option
              :for={space <- @spaces}
              value={space.id}
              selected={space.id == @pane.space}
            >{space.label}</option></select>
        </label>
        <label>
          Folder<input
            name="path"
            value={@pane.directory}
            placeholder="/"
            aria-label={@title <> " folder"}
          />
        </label>
        <button>Open</button>
      </form>
      <div class="pane-path">
        <button
          phx-click="pane-directory"
          phx-value-side={@side}
          phx-value-path={parent(@pane.directory)}
          disabled={@pane.directory == ""}
          class="quiet"
          aria-label={@title <> " parent folder"}
        >
          ↑
        </button>
        <span>/{@pane.directory}</span><button
          phx-click="pane-directory"
          phx-value-side={@side}
          phx-value-path={@pane.directory}
          disabled={@pane.space == ""}
          class="quiet"
          aria-label={"Refresh " <> String.downcase(@title)}
        >↻</button>
      </div>
      <p :if={@pane.error} class="notice pane-error" role="status">{@pane.error}</p>
      <p :if={@pane.space == ""} class="pane-empty">
        {if @side == "left",
          do: "Create a project or link a folder to begin.",
          else: "Connect and trust a node in Console to browse remote files."}
      </p>
      <ul class="file-list pane-list" aria-label={@title <> " folder contents"}>
        <li :for={entry <- @pane.entries} class={@pane.selected == entry.path && "selected"}>
          <button
            :if={entry.type == :directory}
            phx-click="pane-directory"
            phx-value-side={@side}
            phx-value-path={entry.path}
            class="quiet"
          >
            <span aria-hidden="true">▸</span> Folder · {entry.name}
          </button>
          <button
            :if={entry.type == :regular}
            phx-click="pane-select"
            phx-value-side={@side}
            phx-value-path={entry.path}
            aria-pressed={to_string(@pane.selected == entry.path)}
            class="quiet"
          >
            {entry.name}
          </button>
          <span :if={entry.type == :unavailable}>{entry.name} · unavailable</span>
          <span :if={entry.type == :regular} class="file-size">{entry.size} B</span>
          <details :if={entry.type == :directory} class="folder-menu">
            <summary aria-label={"Actions for " <> entry.name}>⋯</summary>
            <div>
              <form phx-submit="pane-rename">
                <input type="hidden" name="side" value={@side} /><input
                  type="hidden"
                  name="from"
                  value={entry.path}
                /><label>New name<input name="to" value={entry.name} required /></label><button>Rename folder</button>
              </form>
              <button
                phx-click="pane-delete-folder"
                phx-value-side={@side}
                phx-value-path={entry.path}
                data-confirm={"Delete empty folder " <> entry.name <> "?"}
                class="danger"
              >
                Delete empty folder
              </button>
            </div>
          </details>
        </li>
      </ul>
      <p :if={@pane.space != "" && @pane.entries == [] && is_nil(@pane.error)} class="pane-empty">
        This folder is empty.
      </p>
      <div class="pane-footer">
        {length(@pane.entries)} items<span :if={@pane.selected}>{Path.basename(@pane.selected)} selected</span>
      </div>
    </section>
    """
  end
end
