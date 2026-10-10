defmodule SSI.Desktop.Sources do
  @moduledoc "Source snapshots bound to the built-in desktop modules in this guest build."
  @definitions [
    {"cluster", SSI.Desktop.ClusterApp,
     ["desktop/cluster_app.ex", "desktop/app.ex", "shell/format.ex"]},
    {"processes", SSI.Desktop.ProcessApp,
     ["desktop/process_app.ex", "desktop/app.ex", "shell/format.ex"]},
    {"mandelbrot", SSI.Desktop.MandelbrotApp,
     ["desktop/mandelbrot_app.ex", "desktop/app.ex", "demo/mandelbrot.ex"]},
    {"shell", SSI.Desktop.ShellApp, ["desktop/shell_app.ex", "desktop/app.ex"]}
  ]
  @root Path.expand("..", __DIR__)
  @files @definitions |> Enum.flat_map(&elem(&1, 2)) |> Enum.uniq()
  for file <- @files do
    @external_resource Path.join(@root, file)
  end

  @sources Map.new(@files, fn file -> {"lib/ssi/" <> file, File.read!(Path.join(@root, file))} end)
  @modules [
    SSI.Desktop.ClusterApp,
    SSI.Desktop.ProcessApp,
    SSI.Desktop.MandelbrotApp,
    SSI.Desktop.ShellApp,
    SSI.Desktop.App,
    SSI.Shell.Format,
    SSI.Demo.Mandelbrot
  ]
  @identities Map.new(@modules, fn module ->
                Code.ensure_compiled!(module)
                {module, module.module_info(:md5) |> Base.encode16(case: :lower)}
              end)

  def request(%{"op" => operation} = params) when operation in ["catalog", "source"] do
    case SSI.Service.whereis(:desktop) do
      pid when is_pid(pid) ->
        if node(pid) == node(),
          do: local_request(params),
          else: :erpc.call(node(pid), __MODULE__, :local_request, [params], 10_000)

      _ ->
        local_request(params)
    end
  end

  def request(params), do: local_request(params)

  def local_request(%{"op" => "catalog"}) do
    %{
      "ok" =>
        Enum.map(@definitions, fn {id, module, paths} ->
          Code.ensure_loaded!(module)

          %{
            "id" => id,
            "title" => module.title(),
            "module" => Atom.to_string(module),
            "version" => to_string(Application.spec(:ssi, :vsn)),
            "node" => Atom.to_string(node()),
            "beam_md5" => @identities[module],
            "matches_running" => identity(module) == @identities[module],
            "files" => Enum.map(paths, &("lib/ssi/" <> &1))
          }
        end)
    }
  end

  def local_request(%{"op" => "source", "id" => id}) do
    case Enum.find(@definitions, &(elem(&1, 0) == id)) do
      nil ->
        %{"error" => "Unknown desktop demo."}

      {_, module, paths} ->
        if Enum.all?(@modules, &(identity(&1) == @identities[&1])) do
          files = Map.take(@sources, Enum.map(paths, &("lib/ssi/" <> &1)))
          hashes = Map.new(files, fn {path, text} -> {path, digest(text)} end)

          %{
            "ok" => %{
              "id" => id,
              "module" => Atom.to_string(module),
              "version" => to_string(Application.spec(:ssi, :vsn)),
              "node" => Atom.to_string(node()),
              "beam_md5" => @identities[module],
              "source_sha256" =>
                digest(JSON.encode!(Enum.sort(hashes) |> Enum.map(&Tuple.to_list/1))),
              "hashes" => hashes,
              "files" => files
            }
          }
        else
          %{
            "error" =>
              "A desktop module changed after this build. Embedded sources no longer match the running code."
          }
        end
    end
  end

  def local_request(%{"op" => "members"}),
    do: %{"ok" => Enum.map(SSI.Cluster.members(), &Atom.to_string/1)}

  def local_request(_), do: %{"error" => "Unsupported desktop-source request."}

  defp identity(module) do
    Code.ensure_loaded!(module)
    module.module_info(:md5) |> Base.encode16(case: :lower)
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc "Deploy to exactly the connected members reviewed by the command node."
  def deploy(members, operation, arguments)
      when operation in [:begin_upload, :append_upload, :finish_upload, :cancel_upload] do
    connected = Map.new(SSI.Cluster.members(), &{Atom.to_string(&1), &1})

    if Enum.sort(members) != Enum.sort(Map.keys(connected)) do
      {:error, "Cluster membership changed. Inspect deployment state before retrying."}
    else
      Enum.reduce_while(members, {:ok, []}, fn member, {:ok, results} ->
        try do
          case :erpc.call(connected[member], SSI.Deploy, operation, arguments, 20_000) do
            {:error, why} ->
              {:halt, {:error, "#{member}: #{inspect(why)}. Other members may have completed."}}

            result ->
              {:cont, {:ok, [{member, result} | results]}}
          end
        catch
          _, _ ->
            {:halt,
             {:error, "#{member} became unavailable. Inspect deployment state before retrying."}}
        end
      end)
    end
  end
end
