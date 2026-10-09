defmodule SSI.DeployTest do
  use ExUnit.Case, async: false

  test "chunked deployment includes dependencies and resources and rolls back failed activation" do
    suffix = System.unique_integer([:positive])
    root = "a_runtime_#{suffix}"
    dependency = "z_runtime_#{suffix}"
    root_app = String.to_atom(root)
    dependency_app = String.to_atom(dependency)
    root_module = Module.concat(["RuntimeRoot#{suffix}"])
    dependency_module = Module.concat(["RuntimeDependency#{suffix}"])
    compiled = Code.compile_string("""
    defmodule #{inspect(dependency_module)} do
      def value, do: File.read!(Application.app_dir(#{inspect(dependency_app)}, "priv/value.txt"))
    end
    defmodule #{inspect(root_module)} do
      def value, do: #{inspect(dependency_module)}.value()
    end
    """) |> Map.new()
    for module <- [root_module, dependency_module], do: (:code.purge(module); :code.delete(module))
    spec = fn app, module, dependencies ->
      :io_lib.format(~c"~tp.~n", [{:application, app, [vsn: ~c"0.1.0", modules: [module], applications: dependencies]}])
      |> IO.iodata_to_binary() |> Base.encode64()
    end
    applications = %{
      root => %{"ebin/#{root}.app" => spec.(root_app, root_module, [:kernel, :stdlib, :elixir, dependency_app]),
                "ebin/#{root_module}.beam" => Base.encode64(compiled[root_module])},
      dependency => %{"ebin/#{dependency}.app" => spec.(dependency_app, dependency_module, [:kernel, :stdlib, :elixir]),
                      "ebin/#{dependency_module}.beam" => Base.encode64(compiled[dependency_module]),
                      "priv/value.txt" => Base.encode64("resource survives deployment")}
    }
    assert {:ok, _} = transfer(applications)
    assert apply(root_module, :value, []) == "resource survives deployment"
    before = SSI.Deploy.installed()

    broken = Map.put(applications[root], "ebin/#{root}.app", spec.(root_app, root_module, [:not_an_installed_dependency]))
    assert {:error, message} = transfer(%{root => broken})
    assert message =~ "Activation failed"
    assert SSI.Deploy.installed() == before
    assert apply(root_module, :value, []) == "resource survives deployment"

    id = String.duplicate("c", 32)
    assert :ok = SSI.Deploy.begin_upload(id, String.duplicate("0", 64), 2)
    assert :ok = SSI.Deploy.append_upload(id, Base.encode64("{}"))
    assert {:error, _} = SSI.Deploy.finish_upload(id)
    assert SSI.Deploy.installed() == before
  end

  defp transfer(applications) do
    bytes = JSON.encode!(%{applications: applications})
    id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    :ok = SSI.Deploy.begin_upload(id, hash, byte_size(bytes))
    for chunk <- Enum.chunk_every(:binary.bin_to_list(bytes), 128) do
      :ok = SSI.Deploy.append_upload(id, Base.encode64(:binary.list_to_bin(chunk)))
    end
    SSI.Deploy.finish_upload(id)
  end

  test "corrupt deployment metadata and missing artifacts cannot prevent boot" do
    dir = Path.join(System.tmp_dir!(), "deploy-recovery-#{System.unique_integer([:positive])}")
    old = Application.get_env(:ssi, :data_dir)
    Application.put_env(:ssi, :data_dir, dir)
    on_exit(fn ->
      if old, do: Application.put_env(:ssi, :data_dir, old), else: Application.delete_env(:ssi, :data_dir)
      File.rm_rf!(dir)
    end)
    root = Path.join(dir, "applications")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "installed.json"), "")
    assert {:ok, %{apps: %{}} = state} = SSI.Deploy.init(nil)
    assert_receive :restore
    assert {:noreply, ^state} = SSI.Deploy.handle_info(:restore, state)
    assert [_] = Path.wildcard(Path.join(root, "installed.json.invalid-*"))

    apps = %{"missing_application" => String.duplicate("a", 64)}
    File.write!(Path.join(root, "installed.json"), JSON.encode!(apps))
    assert {:ok, %{apps: ^apps} = state} = SSI.Deploy.init(nil)
    assert_receive :restore
    assert {:noreply, ^state} = SSI.Deploy.handle_info(:restore, state)
  end

  test "rejects paths, invalid beams and replacement of OS applications" do
    assert {:error, _} = SSI.Deploy.install("../escape", %{})
    assert {:error, _} = SSI.Deploy.install("example", %{"../x.beam" => Base.encode64("bad")})
    assert {:error, _} = SSI.Deploy.install("ssi", %{"ssi.app" => Base.encode64("{application,ssi,[{modules,[]}]}. ")})
  end

  test "installs and starts a compiled OTP application, with a persistent identity" do
    name = "deploy_test_#{System.unique_integer([:positive])}"
    app = String.to_atom(name)
    module = Module.concat(["DeployTest#{System.unique_integer([:positive])}"])
    [{^module, beam}] = Code.compile_string("defmodule #{inspect(module)} do\n def value, do: 42\nend")
    :code.purge(module)
    :code.delete(module)
    app_text = :io_lib.format(~c"~tp.~n", [{:application, app, [vsn: ~c"0.1.0", modules: [module], applications: [:kernel, :stdlib, :elixir]]}]) |> IO.iodata_to_binary()
    bundle = %{name <> ".app" => Base.encode64(app_text), Atom.to_string(module) <> ".beam" => Base.encode64(beam)}
    assert {:ok, %{application: ^name, identity: identity}} = SSI.Deploy.install(name, bundle)
    assert {:file, _} = :code.is_loaded(module)
    assert apply(module, :value, []) == 42
    assert SSI.Deploy.installed()[name] == identity
    assert Enum.any?(Application.started_applications(), fn {id, _, _} -> id == app end)
    assert {:error, _} = SSI.Deploy.install(name, Map.put(bundle, "extra.app", Base.encode64("bad")))
    assert {:ok, _} = SSI.Deploy.install(name, bundle)

    # Restore must load code explicitly; the target boots in embedded mode.
    :ok = Application.stop(app)
    :ok = Application.unload(app)
    :code.purge(module)
    :code.delete(module)
    state = %{root: Path.join(SSI.Boot.data_dir(), "applications"), apps: %{name => identity}}
    assert {:noreply, ^state} = SSI.Deploy.handle_info(:restore, state)
    assert {:file, _} = :code.is_loaded(module)
    assert apply(module, :value, []) == 42
  end
end
