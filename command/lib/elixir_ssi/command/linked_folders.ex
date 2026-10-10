defmodule ElixirSSI.Command.LinkedFolders do
  @moduledoc "Explicit host-folder links accessed through restricted, short-lived Elixir containers."
  alias ElixirSSI.Command.{Instances, LocalFiles, Runner, Store}
  @operations [:list, :read, :stat, :revision, :write, :mkdir, :rename, :remove, :snapshot]
  @mutations [:write, :mkdir, :rename, :remove]

  def list, do: Map.get(Store.get(), "linked_folders", [])

  def register(name, host_path, writable) when is_binary(name) and is_boolean(writable) do
    with true <- String.trim(name) != "" and byte_size(name) <= 80,
         {:ok, host_path} <- validate_host_path(host_path),
         false <- Enum.any?(list(), &(&1["host_path"] == host_path)) do
      link = %{
        "id" => Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
        "name" => String.trim(name),
        "host_path" => host_path,
        "writable" => writable
      }

      with {:ok, %{type: :directory}} <- worker(link, :stat, [""]),
           :ok <-
             Store.update(fn config ->
               Map.update(config, "linked_folders", [link], &(&1 ++ [link]))
             end) do
        {:ok, link}
      else
        {:ok, _} -> {:error, "Choose an existing host folder."}
        error -> error
      end
    else
      true -> {:error, "This folder is already linked."}
      false -> {:error, "Give this folder a name of up to 80 bytes."}
      error -> error
    end
  end

  def unlink(id) do
    Store.update(fn config ->
      Map.update(config, "linked_folders", [], &Enum.reject(&1, fn link -> link["id"] == id end))
    end)
  end

  def call(id, operation, args) when operation in @operations do
    case Enum.find(list(), &(&1["id"] == id)) do
      nil ->
        {:error, "This folder is no longer linked."}

      %{"writable" => false} when operation in @mutations ->
        {:error, "This host folder is linked read-only."}

      link ->
        worker(link, operation, args)
    end
  end

  def validate_host_path(path) when is_binary(path) do
    path = String.trim(path)

    cond do
      path == "" or String.contains?(path, [<<0>>, "\n", "\r"]) ->
        {:error, "Enter an absolute host folder path."}

      Regex.match?(~r{^[A-Za-z]:[\\/]}, path) ->
        <<drive::binary-size(1), _::binary-size(1), rest::binary>> =
          String.replace(path, "\\", "/")

        {:ok, "/run/desktop/mnt/host/" <> String.downcase(drive) <> rest}

      Path.type(path) == :absolute ->
        {:ok, Path.expand(path)}

      true ->
        {:error,
         "Use an absolute path on the command node's Docker host, not on the browser's computer."}
    end
  end

  def validate_host_path(_), do: {:error, "Enter an absolute host folder path."}

  defp worker(link, operation, args) do
    with {:ok, install} <- Instances.installation(),
         {:ok, image} <- File.read(Path.join(install.root, "command-image")) do
      id = "files-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      directory = Path.join([Store.directory(), "transfers", id])
      host_data = Application.get_env(:ssi_command, :data_host_dir) || Store.directory()
      exchange = Path.join([host_data, "transfers", id])
      File.mkdir_p!(directory)
      File.write!(Path.join(directory, "request"), :erlang.term_to_binary({operation, args}))
      mount = mount(link["host_path"], "/linked", not link["writable"])

      try do
        with {:ok, _} <-
               Runner.run(
                 "docker",
                 [
                   "run",
                   "--rm",
                   "--name",
                   id,
                   "--network",
                   "none",
                   "--memory",
                   "512m",
                   "--cpus",
                   "1",
                   "--pids-limit",
                   "128",
                   "--read-only",
                   "--cap-drop",
                   "ALL",
                   "--security-opt",
                   "no-new-privileges",
                   "--tmpfs",
                   "/tmp:rw,nosuid,size=64m",
                   "-e",
                   "SSI_COMMAND_DATA=/tmp/command",
                   "--mount",
                   mount,
                   "--mount",
                   mount(exchange, "/exchange", false),
                   String.trim(image),
                   "/command/bin/ssi_command",
                   "eval",
                   "ElixirSSI.Command.LinkedFolders.worker!()"
                 ],
                 timeout: 60_000
               ),
             {:ok, bytes} <- File.read(Path.join(directory, "response")),
             true <- byte_size(bytes) <= LocalFiles.limits().tree do
          :erlang.binary_to_term(bytes, [:safe])
        else
          false -> {:error, "Host-folder response exceeds the transfer limit."}
          error -> error
        end
      after
        Runner.run("docker", ["rm", "-f", id], timeout: 10_000)
        File.rm_rf(directory)
      end
    end
  end

  defp mount(source, target, readonly) do
    fields =
      ["type=bind", "source=" <> source, "target=" <> target] ++
        if(readonly, do: ["readonly"], else: [])

    Enum.map_join(fields, ",", fn field -> "\"" <> String.replace(field, "\"", "\"\"") <> "\"" end)
  end

  @doc false
  def worker! do
    Code.ensure_loaded!(LocalFiles)
    {operation, args} = File.read!("/exchange/request") |> :erlang.binary_to_term([:safe])

    result =
      if operation in @operations and is_list(args),
        do: apply(LocalFiles, operation, ["/linked" | args]),
        else: {:error, "Unsupported host-folder operation."}

    File.write!("/exchange/response", :erlang.term_to_binary(result))
  end
end
