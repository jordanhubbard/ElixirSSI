defmodule ElixirSSI.Command.FileSpaces do
  @moduledoc "Named file roots available to the authenticated workspace."
  alias ElixirSSI.Command.{LinkedFolders, LocalFiles, Projects, Remote, RemoteFiles}

  def list do
    Enum.map(Projects.list(), &%{id: "project:" <> &1, label: "Command workspace / " <> &1}) ++
      Enum.map(
        LinkedFolders.list(),
        &%{id: "link:" <> &1["id"], label: "Host folder / " <> &1["name"]}
      ) ++
      Enum.flat_map(Remote.targets(), fn target ->
        [
          %{id: "cluster:" <> target, label: "Cluster files via " <> target},
          %{id: "node:" <> target, label: "Node-local files via " <> target}
        ]
      end)
  end

  def root("project:" <> name), do: Projects.safe_path(name, "")
  def root(_), do: {:error, "Select an available file location."}

  def call("cluster:" <> target, operation, args),
    do: RemoteFiles.call(target, "/", operation, args)

  def call("node:" <> target, operation, args),
    do: RemoteFiles.call(target, "/node", operation, args)

  def call("link:" <> id, operation, args), do: LinkedFolders.call(id, operation, args)

  def call(space, operation, args)
      when operation in [
             :list,
             :read,
             :stat,
             :revision,
             :write,
             :mkdir,
             :rename,
             :remove,
             :snapshot
           ] do
    with {:ok, root} <- root(space), do: apply(LocalFiles, operation, [root | args])
  end

  def message({:ok, _}), do: "Done."
  def message(:ok), do: "Done."
  def message({:error, error}) when is_binary(error), do: error

  def message({:error, error}) when is_atom(error),
    do: error |> :file.format_error() |> to_string()

  def message(_), do: "The file operation failed."
end
