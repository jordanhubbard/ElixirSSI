defmodule SSI.UnitTest do
  use ExUnit.Case, async: true
  alias SSI.Net.{Addr, DHCP}

  test "configuration files and kernel command line" do
    assert SSI.Config.parse_conf("# c\ncluster = lab\nsecret=\"s3 cret\"\n\nnet.eth0 = linklocal\n") ==
             %{"cluster" => "lab", "secret" => "s3 cret", "net.eth0" => "linklocal"}

    assert SSI.Config.parse_cmdline("console=ttyAMA0 ssi.cluster=x ssi.data=tmpfs quiet ssi.flag") ==
             %{"cluster" => "x", "data" => "tmpfs", "flag" => "true"}
  end

  test "IPv4 arithmetic" do
    assert Addr.netmask(24) == {255, 255, 255, 0}
    assert Addr.prefix({255, 255, 240, 0}) == 20
    assert Addr.parse_cidr("10.1.2.3/16") == {:ok, {10, 1, 2, 3}, 16}
    assert Addr.parse_cidr("10.1.2/16") == {:error, :einval}
    assert Addr.same_subnet?({10, 1, 2, 3}, {10, 1, 9, 9}, 16)
    {169, 254, c, 0x42} = Addr.link_local(<<0x52, 0x54, 0, 0x12, 0x34, 0x42>>)
    assert c in 1..254
    assert Addr.link_local(<<1, 2, 3, 4, 5, 6>>) == Addr.link_local(<<1, 2, 3, 4, 5, 6>>)
  end

  test "DHCP messages encode and decode" do
    mac = <<0x52, 0x54, 0, 0x12, 0x34, 0x56>>
    discover = DHCP.encode(:discover, 0xDEADBEEF, mac, hostname: "ssi-a")
    assert DHCP.flags_broadcast?(discover)
    assert <<1, 1, 6, 0, 0xDEADBEEF::32, _::binary>> = discover

    # Turn our request into a server reply and decode it.
    <<_op, rest::binary-size(11), _ci::32, _yi::32, tail::binary>> = discover
    <<_si::32, _gi::32, chaddr::binary-size(16), sname::binary-size(64), file::binary-size(128), _magic::32, _::binary>> = tail

    offer =
      <<2>> <> rest <> <<0::32, 10, 0, 2, 15, 10, 0, 2, 2, 0::32>> <> chaddr <> sname <> file <>
        <<99, 130, 83, 99, 53, 1, 2, 1, 4, 255, 255, 255, 0, 3, 4, 10, 0, 2, 2, 6, 8, 10, 0, 2, 3, 1, 1, 1, 1, 51, 4, 0, 0, 14, 16, 54, 4, 10, 0, 2, 2, 255>>

    assert {:ok, msg} = DHCP.decode(offer)
    assert msg.type == :offer and msg.xid == 0xDEADBEEF and msg.ip == {10, 0, 2, 15}
    assert msg.options[1] == {255, 255, 255, 0}
    assert msg.options[3] == {10, 0, 2, 2}
    assert msg.options[6] == [{10, 0, 2, 3}, {1, 1, 1, 1}]
    assert msg.options[51] == 3600
    assert DHCP.decode("garbage") == {:error, :malformed}
  end

  test "module aliases match devices by glob, bucketed by bus" do
    db = %{
      aliases:
        SSI.Devices.parse_aliases("""
        alias of:N*T*Ccdns,macb* macb
        alias pci:v00001AF4d00001000sv*sd*bc*sc*i* virtio_net
        alias usb:v0BDAp8153d*dc*dsc*dp*ic*isc*ip*in* r8152
        alias platform:rp1-pio rp1_pio
        """)
    }

    assert SSI.Devices.match(db, "of:NethernetT(null)Ccdns,macb") == "macb"
    assert SSI.Devices.match(db, "pci:v00001AF4d00001000sv00001AF4sd00000001bc02sc00i00") == "virtio_net"
    assert SSI.Devices.match(db, "platform:rp1-pio") == "rp1_pio"
    assert SSI.Devices.match(db, "pci:v00008086d00001234sv0sd0bc0sc0i0") == nil

    deps = SSI.Devices.parse_deps("kernel/a/macb.ko: kernel/b/phylink.ko kernel/c/libphy.ko\nkernel/d/rp1-pio.ko:\n")
    assert deps["macb"] == {"kernel/a/macb.ko", ["kernel/b/phylink.ko", "kernel/c/libphy.ko"]}
    assert deps["rp1_pio"] == {"kernel/d/rp1-pio.ko", []}
  end

  test "paths resolve against the working directory and mounts" do
    Process.put(:ssi_cwd, "/home/ada")
    assert SSI.FS.expand("notes.txt") == "/home/ada/notes.txt"
    assert SSI.FS.expand("../../etc/./x") == "/etc/x"
    assert SSI.FS.expand("/../..") == "/"
    assert SSI.FS.resolve("/proc/nodes/a/info") == {SSI.FS.Proc, "/nodes/a/info"}
    assert SSI.FS.resolve("/node") == {SSI.FS.Node, "/"}
    assert SSI.FS.resolve("/procedures") == {SSI.FS.Cluster, "/procedures"}
  end

  test "beacons are authenticated" do
    signed = SSI.Cluster.Identity.sign("hello")
    assert SSI.Cluster.Identity.verify(signed) == {:ok, "hello"}
    <<first, rest::binary>> = signed
    assert SSI.Cluster.Identity.verify(<<Bitwise.bxor(first, 1)>> <> rest) == {:error, :bad_signature}
    assert is_atom(SSI.Cluster.Identity.cookie())
  end

  test "the epmd replacement maps every node to the fixed port" do
    alias SSI.Cluster.Epmd
    assert Epmd.port_please(~c"ssi", {10, 0, 0, 1}) == {:port, 4370, 6}
    assert {:ok, {169, 254, 3, 4}, 4370, 6} = Epmd.address_please(~c"ssi", ~c"169.254.3.4", :inet)
    assert {:ok, creation} = Epmd.register_node(~c"ssi", 4370)
    assert creation > 3
  end

  test "Mandelbrot kernel" do
    assert SSI.Demo.Mandelbrot.escape(0.0, 0.0, 100) == 100
    assert SSI.Demo.Mandelbrot.escape(2.0, 2.0, 100) == 1
    px = SSI.Demo.Mandelbrot.tile(SSI.Demo.Mandelbrot.default_view(), {0, 0, 10, 10}, 100, 100, 50)
    assert byte_size(px) == 10 * 10 * 4
  end

  test "scheduler utilisation from wall-time deltas" do
    s = :erlang.system_info(:schedulers)
    before = for id <- 1..s, do: {id, 0, 0}
    now = for id <- 1..s, do: {id, 50, 100}
    assert SSI.Load.utilization(before, now) == 0.5
  end

  test "tables" do
    out = SSI.Shell.Format.table(~w(A BB), [["x", 1], ["yyy", nil]])
    assert out == "A    BB\nx    1\nyyy  -\n"
    assert SSI.Shell.Format.bytes(3 * 1024 * 1024) == "3.0M"
    assert SSI.Shell.Format.bar(0.5, 4) == "##.."
  end
end
