defmodule ElixirSSI.Command.LocalFilesTest do
  use ExUnit.Case, async: true
  alias ElixirSSI.Command.LocalFiles, as: Files

  setup do
    # /tmp is a symlink on macOS; resolve it before testing the explicit root.
    root = Path.join(File.cwd!(), "_build/files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "binary round trip, folders, rename and confirmed deletion", %{root: root} do
    bytes = <<0, 255, 128, 10>>
    assert :ok = Files.mkdir(root, "assets")
    assert {:ok, hash} = Files.write(root, "assets/picture.bin", bytes)
    assert {:ok, ^bytes} = Files.read(root, "assets/picture.bin")
    assert {:ok, [%{name: "picture.bin", type: :regular}]} = Files.list(root, "assets")
    assert :ok = Files.rename(root, "assets/picture.bin", "assets/renamed.bin")
    assert {:error, _} = Files.remove(root, "assets", :empty_directory)
    assert :ok = Files.remove(root, "assets/renamed.bin", hash)
    assert :ok = Files.remove(root, "assets", :empty_directory)
  end

  test "overwrites and deletes reject stale file identities", %{root: root} do
    assert {:ok, first} = Files.write(root, "data.txt", "first")
    assert {:error, _} = Files.write(root, "data.txt", "unconfirmed")
    assert {:ok, second} = Files.write(root, "data.txt", "second", first)
    assert {:error, _} = Files.write(root, "data.txt", "stale", first)
    assert {:error, _} = Files.remove(root, "data.txt", first)
    assert {:ok, "second"} = Files.read(root, "data.txt")
    assert :ok = Files.remove(root, "data.txt", second)
  end

  test "rejects path traversal, symlink roots, nested symlinks and portable invalid names", %{
    root: root
  } do
    for path <- [
          "../outside",
          "/etc/passwd",
          "a/../b",
          "a\\b",
          "a//b",
          "NUL.txt",
          "foo.",
          "foo:bar"
        ] do
      assert {:error, _} = Files.path(root, path)
    end

    File.ln_s!(root, Path.join(root, "link"))
    assert {:error, _} = Files.read(root, "link/a")
    assert {:error, _} = Files.write(Path.join(root, "link"), "a", "escape")
    assert {:error, _} = Files.snapshot(root)
    assert {:error, _} = Files.remove(root, "", :empty_directory)
    assert {:error, _} = Files.rename(root, "", "elsewhere")
  end

  test "snapshot fingerprints files and preserves empty directories", %{root: root} do
    assert :ok = Files.mkdir(root, "empty")
    assert {:ok, hash} = Files.write(root, "nested/data", "hello")
    assert {:ok, snapshot} = Files.snapshot(root)
    assert snapshot["empty"] == %{type: :directory}
    assert snapshot["nested/data"] == %{type: :regular, hash: hash, size: 5}
    assert {:error, _} = Files.rename(root, "nested", "empty")
    assert {:ok, "hello"} = Files.read(root, "nested/data")
  end

  test "bounds binary transfers", %{root: root} do
    bytes = :binary.copy(<<0>>, Files.limits().file + 1)
    assert {:error, _} = Files.write(root, "oversize.bin", bytes)
    File.write!(Path.join(root, "oversize.bin"), bytes)
    assert {:error, _} = Files.read(root, "oversize.bin")
  end
end
