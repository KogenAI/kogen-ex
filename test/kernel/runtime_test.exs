defmodule Kogen.Kernel.RuntimeTest do
  use Kogen.Testkit.Case

  alias Kogen.Engine.Runtime
  alias Kogen.Kernel.RuntimeDiscovery

  test "project PATH keeps mise available alongside the target toolchain" do
    runtime = Runtime.new(%{"PATH" => "/system/bin"}, "/mise/bin/mise", nil, "/erts", "/erts/bin")
    environment = Runtime.process_env(runtime, %{"PATH" => "/target/bin"})

    assert environment["PATH"] == "/mise/bin:/target/bin"
  end

  test "proxy variables reach agent processes and git checks in both cases" do
    proxy_env = %{
      "https_proxy" => "http://lower.example:8080",
      "HTTPS_PROXY" => "http://upper.example:8080",
      "all_proxy" => "http://all-lower.example:8080",
      "ALL_PROXY" => "http://all-upper.example:8080",
      "http_proxy" => "http://http-lower.example:8080",
      "HTTP_PROXY" => "http://http-upper.example:8080",
      "no_proxy" => "localhost,.internal.example",
      "NO_PROXY" => "example.com"
    }

    runtime =
      Runtime.new(
        Map.put(proxy_env, "PATH", "/system/bin"),
        "/mise/bin/mise",
        nil,
        "/erts",
        "/erts/bin"
      )

    process_env = Runtime.process_env(runtime, %{})

    assert Map.take(process_env, Map.keys(proxy_env)) == proxy_env
    assert Map.take(runtime.git_env, Map.keys(proxy_env)) == proxy_env
  end

  test "escript path markers resolve symlinks to their immutable generation", %{
    tmp_dir: tmp_dir
  } do
    generation = Path.join([tmp_dir, "gen", "kogen"])
    link = Path.join([tmp_dir, "bin", "kogen"])
    File.mkdir_p!(Path.dirname(generation))
    File.mkdir_p!(Path.dirname(link))
    File.write!(generation, "escript")
    File.ln_s!(generation, link)

    assert {:ok, ^generation} = RuntimeDiscovery.resolve_script_path(link)
  end

  test "runtime discovery does not treat Mix as the Kogen escript" do
    assert {:ok, %Runtime{base_env: env}} = RuntimeDiscovery.runtime()
    refute Map.has_key?(env, "KOGEN_ESCRIPT_DIR")
    refute Map.has_key?(env, "KOGEN_ERTS_DIR")
    refute Map.has_key?(env, "KOGEN_ERTS_BIN")
  end
end
