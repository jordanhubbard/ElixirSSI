defmodule SSI.StoreLogTest do
  # A member must boot from whatever a power cut left in its store log.
  use ExUnit.Case, async: false

  test "a log ending in zeros or a torn record still boots, keeps its entries and appends after them" do
    dir = Path.join(System.tmp_dir!(), "ssi-storelog-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    good = frame({{:t, :kept}, "before the cut", {1, 0, :"x@h"}})
    # ext4 can leave a file extended with zeros it never wrote; a write can also stop mid-record.
    File.write!(Path.join(dir, "store.log"), [good, :binary.copy(<<0>>, 4096), frame({{:t, :late}, 1, {2, 0, :"x@h"}})])

    {node, pid} = boot(dir)
    assert :erpc.call(node, SSI.Store, :get, [:t, :kept]) == "before the cut"
    :ok = :erpc.call(node, SSI.Store, :put_sync, [:t, :after, "written after"])
    :peer.stop(pid)

    # The torn tail was cut off, so the new record is found on the next boot.
    assert File.stat!(Path.join(dir, "store.log")).size > byte_size(good)
    {node, pid} = boot(dir)
    assert :erpc.call(node, SSI.Store, :get, [:t, :after]) == "written after"
    :peer.stop(pid)

    File.write!(Path.join(dir, "store.log"), [good, binary_part(good, 0, 7)])
    {node, pid} = boot(dir)
    assert :erpc.call(node, SSI.Store, :get, [:t, :kept]) == "before the cut"
    :peer.stop(pid)
  end

  defp frame(entry) do
    bin = :erlang.term_to_binary(entry)
    <<byte_size(bin)::32, bin::binary>>
  end

  # A lone member (its own cluster name, so it joins no one) on `dir`.
  defp boot(dir) do
    cookie = [~c"-setcookie", Atom.to_charlist(SSI.Cluster.Identity.cookie())]
    args = cookie ++ Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
    name = :"ssi-log-#{System.unique_integer([:positive])}"
    {:ok, pid, node} = :peer.start_link(%{name: name, host: ~c"127.0.0.1", longnames: true, args: args, wait_boot: 30_000})
    :ok = :erpc.call(node, Logger, :configure, [[level: :error]])
    :ok = :erpc.call(node, Application, :put_env, [:ssi, :data_dir, dir])
    :ok = :erpc.call(node, Application, :put_env, [:ssi, :autostart_services, false])
    :ok = :erpc.call(node, Application, :put_env, [:ssi, :config, %{"cluster" => "storelog-#{name}"}])
    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:ssi])
    {node, pid}
  end
end
