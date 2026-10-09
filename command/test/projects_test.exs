defmodule ElixirSSI.Command.ProjectsTest do
  use ExUnit.Case, async: false
  alias ElixirSSI.Command.Projects

  setup do
    name = "project_#{System.unique_integer([:positive])}"
    {:ok, _} = Projects.create(name)
    on_exit(fn -> File.rm_rf!(Path.join(Projects.root(), name)) end)
    %{name: name}
  end

  test "creates usable Mix source and preserves edits", %{name: name} do
    assert {:ok, files} = Projects.files(name)
    assert "mix.exs" in files
    assert "test/test_helper.exs" in files
    assert {:ok, _} = Projects.save(name, "lib/new.ex", "defmodule New, do: def(value, do: 42)\n")
    assert {:ok, source} = Projects.read(name, "lib/new.ex")
    assert source =~ "42"
    assert {:error, _} = Projects.create(name)
  end

  test "rejects traversal, absolute paths and symlinks", %{name: name} do
    assert {:error, _} = Projects.safe_path(name, "../configuration.json")
    assert {:error, _} = Projects.safe_path(name, "/etc/passwd")
    assert {:error, _} = Projects.safe_path("../outside", "mix.exs")
    link = Path.join([Projects.root(), name, "escape"])
    File.ln_s!(System.tmp_dir!(), link)
    assert {:error, _} = Projects.save(name, "escape/outside.ex", "not written")
    assert {:error, _} = Projects.read(name, "escape/outside.ex")
  end

  test "rejects oversize and non-source writes", %{name: name} do
    assert {:error, _} = Projects.save(name, "big.ex", String.duplicate("a", 524_289))
    assert {:error, _} = Projects.save(name, "image.beam", "not a source file")
  end
end
