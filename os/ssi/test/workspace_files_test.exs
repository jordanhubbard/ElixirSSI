defmodule SSI.WorkspaceFilesTest do
  use ExUnit.Case, async: false
  alias SSI.WorkspaceFiles, as: Files

  setup do
    root = "/workspace-test-#{System.unique_integer([:positive])}"
    :ok = SSI.FS.mkdir(root)
    on_exit(fn -> SSI.FS.rm_rf(root) end)
    %{root: root}
  end

  defp request(op, params), do: Files.request(Map.put(params, "op", op))
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp begin_upload(path, bytes, expected \\ "missing") do
    request("begin", %{
      "path" => path,
      "size" => byte_size(bytes),
      "hash" => hash(bytes),
      "expected" => expected
    })
  end

  test "chunked binary transfer and stale overwrite protection", %{root: root} do
    path = root <> "/binary"
    first = :binary.copy(<<0, 255, 1>>, 32_768)
    rest = <<128, 0, 1>>
    bytes = first <> rest
    assert %{"ok" => id} = begin_upload(path, bytes)

    assert %{"error" => _} =
             request("append", %{"id" => id, "offset" => 1, "data" => Base.encode64(first)})

    assert %{"ok" => 98_304} =
             request("append", %{"id" => id, "offset" => 0, "data" => Base.encode64(first)})

    assert %{"ok" => 98_307} =
             request("append", %{"id" => id, "offset" => 98_304, "data" => Base.encode64(rest)})

    assert %{"ok" => digest} = request("finish", %{"id" => id})
    assert digest == hash(bytes)

    assert %{"ok" => %{"data" => encoded, "hash" => ^digest, "size" => 98_307}} =
             request("read", %{"path" => path, "offset" => 98_304})

    assert Base.decode64!(encoded) == rest
    assert %{"error" => _} = begin_upload(path, "overwrite")
    assert %{"error" => _} = request("remove", %{"path" => path, "expected" => "stale"})
    assert {:ok, ^bytes} = SSI.FS.read(path)
    assert %{"ok" => true} = request("remove", %{"path" => path, "expected" => digest})
  end

  test "failed or interrupted transfer preserves existing contents", %{root: root} do
    path = root <> "/existing"
    :ok = SSI.FS.write(path, "before")
    assert %{"ok" => id} = begin_upload(path, "after", hash("before"))
    assert %{"error" => _} = request("finish", %{"id" => id})
    assert {:ok, "before"} = SSI.FS.read(path)
    assert %{"ok" => id} = begin_upload(path, "after", hash("before"))

    assert %{"ok" => 5} =
             request("append", %{"id" => id, "offset" => 0, "data" => Base.encode64("after")})

    :ok = SSI.FS.write(path, "concurrent")
    assert %{"error" => _} = request("finish", %{"id" => id})
    assert {:ok, "concurrent"} = SSI.FS.read(path)
  end

  test "SSH result carries a complete binary transfer chunk", %{root: root} do
    path = root <> "/ssh-chunk"
    bytes = :binary.copy(<<0, 255, 128>>, 32_768)
    :ok = SSI.FS.write(path, bytes)
    payload = JSON.encode!(%{"op" => "read", "path" => path, "offset" => 0}) |> Base.encode64()
    source = "\"SSI_FILES:\" <> Base.encode64(JSON.encode!(SSI.WorkspaceFiles.request(JSON.decode!(Base.decode64!(\"#{payload}\")))))"
    assert {:ok, output} = SSI.SSH.exec(source, ~c"root", nil)
    assert [_, encoded] = Regex.run(~r/^"SSI_FILES:([A-Za-z0-9+\/=]+)"$/, output)
    assert %{"ok" => %{"data" => data, "size" => 98_304}} = JSON.decode!(Base.decode64!(encoded))
    assert Base.decode64!(data) == bytes
  end

  test "listing, mkdir and rename preserve destination and reject traversal", %{root: root} do
    assert %{"ok" => true} = request("mkdir", %{"path" => root <> "/empty"})

    assert %{"ok" => [%{"name" => "empty", "type" => "directory"}]} =
             request("list", %{"path" => root})

    assert %{"ok" => true} =
             request("rename", %{"path" => root <> "/empty", "to" => root <> "/new"})

    assert %{"error" => _} =
             request("rename", %{"path" => root <> "/new", "to" => root <> "/new/sub"})

    assert %{"error" => _} = request("mkdir", %{"path" => "/../escape"})
    assert %{"error" => _} = request("remove", %{"path" => "/", "expected" => "empty_directory"})
  end

  test "node-local access rejects symlinks and follows the hosted root" do
    root = Path.join(SSI.Boot.data_dir(), "root")
    File.mkdir_p!(root)
    name = "workspace-#{System.unique_integer([:positive])}"
    local = Path.join(root, name)
    File.mkdir!(local)
    on_exit(fn -> File.rm_rf!(local) end)
    assert :ok = Files.node_request(:write, "/#{name}/binary", [<<0, 255>>])
    assert {:ok, <<0, 255>>} = Files.node_request(:read, "/#{name}/binary", [])
    File.ln_s!(System.tmp_dir!(), Path.join(local, "escape"))
    assert {:error, _} = Files.node_request(:read, "/#{name}/escape/secret", [])
    assert {:error, _} = Files.node_request(:write, "/#{name}/escape/unwanted", ["no"])
    assert {:error, _} = Files.node_request(:write, "/#{name}/../outside", ["no"])
  end
end
