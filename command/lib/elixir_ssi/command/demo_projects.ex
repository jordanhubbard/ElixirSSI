defmodule ElixirSSI.Command.DemoProjects do
  @moduledoc "Turn a verified guest demo source snapshot into a namespaced, editable Mix project."
  alias ElixirSSI.Command.{LocalFiles, ProjectArchive, Projects, Remote, RemoteFiles}

  @runtime_modules "[SSI.Remote, SSI.Cluster, SSI.Load, SSI.Service, SSI.Shell, SSI.Proc, SSI.Boot, SSI.Sched]"

  def catalog(target), do: RemoteFiles.rpc(target, %{op: "catalog"}, :demos)

  def source(target, id) do
    with {:ok, snapshot} <- RemoteFiles.rpc(target, %{op: "source", id: id}, :demos),
         :ok <- verify(snapshot),
         do: {:ok, snapshot}
  end

  def copy(snapshot, name) do
    with {:ok, _} <- Projects.safe_path(name, ""),
         :ok <- verify(snapshot),
         {:ok, {_, archive}} <-
           :zip.create(~c"demo.zip", project_files(snapshot, name), [:memory]),
         {:ok, _} <- ProjectArchive.import(name, archive) do
      {:ok,
       "Created #{name} from guest #{snapshot["version"]}, source #{snapshot["source_sha256"]}."}
    end
  end

  def metadata(project) do
    with {:ok, text} <- Projects.read(project, ".ssi-demo.json"),
         {:ok, metadata} <- Jason.decode(text),
         true <-
           is_binary(metadata["module"]) and
             Regex.match?(~r/^Elixir\.[A-Z][A-Za-z0-9_.]*$/, metadata["module"]),
         do: {:ok, metadata},
         else: (_ -> {:error, "This project has no valid desktop entrypoint."})
  end

  def deploy_and_run(project, target) do
    with {:ok, metadata} <- metadata(project),
         {:ok, members} <- RemoteFiles.rpc(target, %{op: "members"}, :demos),
         {:ok, deployed} <- Projects.deploy_cluster(project, target, members),
         {:ok, result} <-
           Remote.evaluate(target, """
           :ok = SSI.Desktop.launch(String.to_existing_atom(#{inspect(metadata["module"])}))
           %{application: #{inspect(project)}, desktop: SSI.Desktop.status()}
           """) do
      {:ok, deployed <> "\nLaunched on the cluster desktop:\n" <> result}
    end
  end

  def verify(%{
        "files" => files,
        "hashes" => hashes,
        "source_sha256" => identity,
        "module" => module
      })
      when is_map(files) and is_map(hashes) and is_binary(module) do
    expected = LocalFiles.digest(Jason.encode!(Enum.sort(hashes) |> Enum.map(&Tuple.to_list/1)))

    if map_size(files) in 1..20 and Enum.sort(Map.keys(files)) == Enum.sort(Map.keys(hashes)) and
         identity == expected and
         Enum.all?(files, fn {path, source} ->
           is_binary(source) and byte_size(source) <= 524_288 and String.valid?(source) and
             match?({:ok, _}, LocalFiles.path("/demo", path)) and
             LocalFiles.digest(source) == hashes[path]
         end), do: :ok, else: {:error, "Guest demo source identity verification failed."}
  end

  def verify(_), do: {:error, "Invalid guest source snapshot."}

  defp project_files(snapshot, name) do
    module = Macro.camelize(name)
    original = String.replace_prefix(snapshot["module"], "Elixir.", "")

    replacements = [
      {original, module <> ".App"},
      {"SSI.Desktop.App", module <> ".DesktopApp"},
      {"SSI.Shell.Format", module <> ".Format"},
      {"SSI.Demo.Mandelbrot", module <> ".Mandelbrot"}
    ]

    edited =
      Enum.map(snapshot["files"], fn {path, source} ->
        source =
          Enum.reduce(replacements, source, fn {from, to}, text ->
            String.replace(text, from, to)
          end)

        source =
          String.replace(
            source,
            "alias " <> module <> ".DesktopApp",
            "alias " <> module <> ".DesktopApp, as: App"
          )

        source =
          String.replace(
            source,
            " do\n",
            " do\n  @compile {:no_warn_undefined, #{@runtime_modules}}\n",
            global: false
          )

        {String.to_charlist("lib/" <> Path.basename(path)), source}
      end)

    original_files =
      Enum.map(snapshot["files"], fn {path, source} ->
        {String.to_charlist("priv/original/" <> path), source}
      end)

    mix = """
    defmodule #{module}.MixProject do
      use Mix.Project
      def project, do: [app: :#{name}, version: "0.1.0", elixir: "~> 1.20", deps: []]
      def application, do: [extra_applications: [:logger]]
    end
    """

    readme = """
    # #{module}

    Copied from the running ElixirSSI #{snapshot["version"]} #{snapshot["id"]} demo.
    Source identity: #{snapshot["source_sha256"]}
    Original guest module: #{snapshot["module"]}; compiled identity: #{snapshot["beam_md5"]}.

    Edit the files in lib. The App module implements the desktop contract; its title,
    render and event callbacks control the window. The original sources are retained
    under priv/original with hashes in .ssi-demo.json.

    Compile and Test run in the isolated command-node project environment. SSI runtime
    services are supplied by the guest OS; they are not started in the build container.
    Use Deploy and run desktop app to install this project on all currently connected
    cluster nodes and open its window on the desktop service. Redeploy after adding a
    new node. This does not replace the built-in demo.
    """

    metadata =
      Map.drop(snapshot, ["files"])
      |> Map.put("original_module", snapshot["module"])
      |> Map.put("module", "Elixir." <> module <> ".App")

    test = """
    defmodule #{module}Test do
      use ExUnit.Case
      test "desktop entrypoint supplies a named window with usable dimensions" do
        Code.ensure_loaded!(#{module}.App)
        assert is_binary(#{module}.App.title())
        assert #{module}.App.short() != ""
        {width, height} = #{module}.App.size()
        assert width > 0 and height > 0
      end
    end
    """

    edited ++
      original_files ++
      [
        {~c"mix.exs", mix},
        {~c"README.md", readme},
        {~c".ssi-demo.json", Jason.encode!(metadata, pretty: true)},
        {~c"test/test_helper.exs", "ExUnit.start()\n"},
        {String.to_charlist("test/" <> name <> "_test.exs"), test}
      ]
  end
end
