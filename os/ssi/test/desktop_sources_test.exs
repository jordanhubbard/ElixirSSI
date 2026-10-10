defmodule SSI.DesktopSourcesTest do
  use ExUnit.Case, async: false
  alias SSI.Desktop.Sources

  test "catalog binds each built-in demo to the loaded compiled module" do
    assert %{"ok" => catalog} = Sources.local_request(%{"op" => "catalog"})
    assert Enum.sort(Enum.map(catalog, & &1["id"])) == ~w(cluster mandelbrot processes shell)

    for demo <- catalog do
      module = String.to_existing_atom(demo["module"])
      assert demo["matches_running"]
      assert demo["beam_md5"] == module.module_info(:md5) |> Base.encode16(case: :lower)
    end
  end

  test "source snapshots contain the exact compiled inputs and verifiable hashes" do
    for id <- ~w(cluster mandelbrot processes shell) do
      assert %{"ok" => snapshot} = Sources.local_request(%{"op" => "source", "id" => id})

      for {path, source} <- snapshot["files"] do
        assert File.read!(path) == source

        assert snapshot["hashes"][path] ==
                 :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
      end

      assert byte_size(snapshot["source_sha256"]) == 64
    end

    assert %{"error" => _} = Sources.local_request(%{"op" => "source", "id" => "../secret"})
  end

  test "cluster deployment rejects a changed member list before uploading" do
    assert {:error, message} = Sources.deploy([], :begin_upload, ["ignored", "ignored", 1])
    assert message =~ "membership changed"
  end
end
