defmodule Kogen.Kernel.BuildConfigTest do
  use Kogen.Testkit.Case

  alias Kogen.Kernel.BuildConfig

  test "KOGEN_BENCH_NO_FALLBACK=1 overrides project and machine settings", %{tmp_dir: root} do
    assert {:ok, %{model_fallback: true}} = BuildConfig.load(root, nil, nil)
    assert {:ok, %{model_fallback: true}} = BuildConfig.load(root, nil, "0")
    assert {:ok, %{model_fallback: false}} = BuildConfig.load(root, nil, "1")

    File.mkdir_p!(Path.join(root, ".kogen"))
    File.write!(Path.join(root, ".kogen/config.yaml"), "build:\n  model_fallback: true\n")
    assert {:ok, %{model_fallback: false}} = BuildConfig.load(root, %{model_fallback: true}, "1")

    File.write!(Path.join(root, ".kogen/config.yaml"), "build:\n  model_fallback: false\n")
    assert {:ok, %{model_fallback: false}} = BuildConfig.load(root, nil, nil)
    assert {:ok, %{model_fallback: false}} = BuildConfig.load(root, nil, "0")
    assert {:ok, %{model_fallback: true}} = BuildConfig.load(root, %{model_fallback: true}, nil)
  end
end
