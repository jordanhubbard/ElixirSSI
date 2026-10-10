defmodule ElixirSSI.Command.FolderSync do
  @moduledoc "Explicit three-way folder synchronization with reviewed, stale-checked plans."
  alias ElixirSSI.Command.{FileSpaces, LocalFiles, Store}
  @excluded [".git", "_build", "deps", ".tools", ".ssi-deployment.json"]

  def excluded, do: @excluded

  def preview(left, right) do
    with :ok <- distinct(left, right),
         {:ok, l} <- scan(left),
         {:ok, r} <- scan(right) do
      id = identity(left, right)
      saved = Store.get() |> Map.get("folder_sync", %{}) |> Map.get(id)
      baseline = if saved, do: saved["baseline"], else: %{}

      plan = %{
        id: id,
        left: left,
        right: right,
        left_tree: l,
        right_tree: r,
        baseline: baseline,
        baseline_record: saved,
        choices: %{},
        desired: nil,
        operations: [],
        conflicts: []
      }

      {:ok, resolve(plan, %{})}
    end
  end

  def resolve(plan, choices) do
    {desired, conflicts} =
      merge_children("", plan.left_tree, plan.right_tree, plan.baseline, choices, %{}, [])

    operations =
      operations(:left, plan.left_tree, desired) ++ operations(:right, plan.right_tree, desired)

    operations =
      Enum.reject(operations, fn op ->
        Enum.any?(
          conflicts,
          &(op.path == &1.path or String.starts_with?(op.path, &1.path <> "/"))
        )
      end)

    %{
      plan
      | desired: desired,
        conflicts: Enum.reverse(conflicts),
        choices: choices,
        operations: operations
    }
  end

  def apply(%{conflicts: [_ | _]}),
    do: {:error, "Resolve every conflict before applying synchronization."}

  def apply(plan) do
    :global.trans({{__MODULE__, plan.id}, self()}, fn ->
      with true <-
             Store.get() |> Map.get("folder_sync", %{}) |> Map.get(plan.id) ==
               plan.baseline_record,
           {:ok, left} <- scan(plan.left),
           {:ok, right} <- scan(plan.right),
           true <- left == plan.left_tree and right == plan.right_tree,
           :ok <- bounds(plan.desired),
           {:ok, contents} <- read_sources(plan),
           :ok <- execute(plan, contents),
           {:ok, final_left} <- scan(plan.left),
           {:ok, final_right} <- scan(plan.right),
           true <- final_left == plan.desired and final_right == plan.desired do
        record = %{
          "left" => stringify(plan.left),
          "right" => stringify(plan.right),
          "baseline" => plan.desired,
          "completed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

        :ok =
          Store.update(fn config ->
            Map.update(config, "folder_sync", %{plan.id => record}, &Map.put(&1, plan.id, record))
          end)

        {:ok,
         "Synchronized #{length(plan.operations)} changes. Both folders agree; baseline saved."}
      else
        false ->
          {:error,
           "Folders or synchronization baseline changed. Preview again. No new baseline was saved."}

        {:error, message} ->
          {:error,
           FileSpaces.message({:error, message}) <>
             " No new baseline was saved; inspect both folders before retrying."}
      end
    end)
  end

  def scan(endpoint) do
    with {:ok, %{type: :directory}} <- FileSpaces.call(endpoint.space, :stat, [endpoint.path]),
         {:ok, entries} <- FileSpaces.call(endpoint.space, :snapshot, [endpoint.path, @excluded]) do
      prefix = if endpoint.path == "", do: "", else: endpoint.path <> "/"

      tree =
        Map.new(entries, fn {path, entry} ->
          {String.replace_prefix(path, prefix, ""), stringify(entry)}
        end)

      {:ok, tree}
    else
      {:ok, _} -> {:error, "Select an existing folder at each location."}
      error -> error
    end
  end

  defp merge_children(parent, left, right, baseline, choices, desired, conflicts) do
    paths =
      (Map.keys(left) ++ Map.keys(right) ++ Map.keys(baseline))
      |> Enum.uniq()
      |> Enum.filter(&(dirname(&1) == parent))
      |> Enum.sort()

    Enum.reduce(paths, {desired, conflicts}, fn path, {acc, pending} ->
      l = subtree(left, path)
      r = subtree(right, path)
      b = subtree(baseline, path)

      cond do
        l == r ->
          {Map.merge(acc, l), pending}

        directory?(left[path]) and directory?(right[path]) ->
          merge_children(
            path,
            left,
            right,
            baseline,
            choices,
            Map.put(acc, path, left[path]),
            pending
          )

        l == b ->
          {Map.merge(acc, r), pending}

        r == b ->
          {Map.merge(acc, l), pending}

        choices[path] == "left" ->
          {Map.merge(acc, l), pending}

        choices[path] == "right" ->
          {Map.merge(acc, r), pending}

        true ->
          {acc,
           [
             %{path: path, left: description(left[path], l), right: description(right[path], r)}
             | pending
           ]}
      end
    end)
  end

  defp description(nil, _), do: "deleted / absent"

  defp description(%{"type" => "directory"}, subtree),
    do: "folder (#{map_size(subtree) - 1} entries)"

  defp description(%{"size" => size}, _), do: "file (#{size} bytes)"
  defp directory?(%{"type" => "directory"}), do: true
  defp directory?(_), do: false

  defp subtree(tree, path),
    do: Map.filter(tree, fn {key, _} -> key == path or String.starts_with?(key, path <> "/") end)

  defp dirname(path), do: if(Path.dirname(path) == ".", do: "", else: Path.dirname(path))
  defp stringify(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp identity(left, right),
    do: LocalFiles.digest(Enum.join([left.space, left.path, right.space, right.path], <<0>>))

  defp distinct(left, right) do
    with {:ok, _} <- LocalFiles.path("/workspace", left.path),
         {:ok, _} <- LocalFiles.path("/workspace", right.path) do
      if namespace(left.space) == namespace(right.space) and
           (left.path == right.path or left.path == "" or right.path == "" or
              String.starts_with?(left.path, right.path <> "/") or
              String.starts_with?(right.path, left.path <> "/")),
         do: {:error, "Choose distinct folders that do not contain one another."},
         else: :ok
    end
  end

  defp namespace("cluster:" <> _), do: "cluster"
  defp namespace(space), do: space

  defp operations(side, current, desired) do
    deletes =
      current
      |> Enum.filter(fn {path, entry} ->
        desired[path] == nil or desired[path]["type"] != entry["type"]
      end)
      |> Enum.sort_by(fn {path, _} -> {-depth(path), path} end)
      |> Enum.map(fn {path, entry} ->
        %{side: side, action: :delete, path: path, before: entry, after: nil}
      end)

    directories =
      desired
      |> Enum.filter(fn {path, entry} -> directory?(entry) and not directory?(current[path]) end)
      |> Enum.sort_by(fn {path, _} -> {depth(path), path} end)
      |> Enum.map(fn {path, entry} ->
        %{side: side, action: :mkdir, path: path, before: current[path], after: entry}
      end)

    writes =
      desired
      |> Enum.filter(fn {path, entry} ->
        entry["type"] == "regular" and current[path] != entry
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {path, entry} ->
        %{side: side, action: :write, path: path, before: current[path], after: entry}
      end)

    deletes ++ directories ++ writes
  end

  defp depth(path), do: length(String.split(path, "/"))

  defp full(endpoint, path),
    do: if(endpoint.path == "", do: path, else: endpoint.path <> "/" <> path)

  defp bounds(tree) do
    size = Enum.reduce(tree, 0, fn {_, entry}, total -> total + Map.get(entry, "size", 0) end)

    if map_size(tree) <= LocalFiles.limits().entries and size <= LocalFiles.limits().tree,
      do: :ok,
      else: {:error, "Merged folders exceed the synchronization size or entry limit."}
  end

  defp read_sources(plan) do
    plan.operations
    |> Enum.filter(&(&1.action == :write))
    |> Enum.uniq_by(& &1.path)
    |> Enum.reduce_while({:ok, %{}}, fn op, {:ok, acc} ->
      endpoint = if plan.left_tree[op.path] == op.after, do: plan.left, else: plan.right

      case FileSpaces.call(endpoint.space, :read, [full(endpoint, op.path)]) do
        {:ok, bytes} ->
          if LocalFiles.digest(bytes) == op.after["hash"],
            do: {:cont, {:ok, Map.put(acc, op.path, bytes)}},
            else: {:halt, {:error, "Source changed after preview."}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp execute(plan, contents) do
    Enum.reduce_while(plan.operations, :ok, fn op, :ok ->
      endpoint = Map.fetch!(plan, op.side)
      path = full(endpoint, op.path)

      result =
        case op.action do
          :delete ->
            FileSpaces.call(endpoint.space, :remove, [
              path,
              if(directory?(op.before), do: :empty_directory, else: op.before["hash"])
            ])

          :mkdir ->
            FileSpaces.call(endpoint.space, :mkdir, [path])

          :write ->
            expected =
              if op.before && op.before["type"] == "regular",
                do: op.before["hash"],
                else: :missing

            FileSpaces.call(endpoint.space, :write, [path, contents[op.path], expected])
        end

      case result do
        :ok ->
          {:cont, :ok}

        {:ok, _} ->
          {:cont, :ok}

        error ->
          {:halt,
           {:error,
            "Stopped at #{op.side}/#{op.path}: #{FileSpaces.message(error)} Earlier listed changes may have completed."}}
      end
    end)
  end
end
