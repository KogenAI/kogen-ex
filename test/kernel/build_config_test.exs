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

  test "Grok defaults use Grok models and configured Grok role names are accepted" do
    assert BuildConfig.builder_settings(%{}, :grok) == {"grok-4.6", "high"}
    assert BuildConfig.shape_settings(%{}, :grok) == {"grok-4.6", "high"}

    assert {:ok, %{roles: roles}} =
             Kogen.Project.BuildSettings.parse(%{
               "roles" => %{
                 "builder" => %{"model" => "grok-4.6", "effort" => "high"},
                 "planner" => %{"model" => "grok-4.7", "effort" => "xhigh"}
               }
             })

    assert roles.builder == %{model: "grok-4.6", effort: "high"}
    assert roles.planner == %{model: "grok-4.7", effort: "xhigh"}
  end
end
