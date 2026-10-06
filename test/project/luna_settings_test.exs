defmodule Kogen.Project.LunaSettingsTest do
  use Kogen.Testkit.Case, async: true

  alias Kogen.Project.BuildSettings

  test "project and machine settings select Luna mode independently of role models" do
    assert {:ok, machine} = BuildSettings.parse(%{"luna_provider_mode" => "lite"})
    assert {:ok, project} = BuildSettings.parse(%{"luna_provider_mode" => "responses"})
    assert BuildSettings.effective(machine, nil).luna_provider_mode == :lite
    assert BuildSettings.effective(machine, project).luna_provider_mode == :responses
    assert {:error, [_issue]} = BuildSettings.parse(%{"luna_provider_mode" => "unknown"})
    assert BuildSettings.effective(nil, nil).roles == %{}
  end

  test "tool-result and generation budgets have independent defaults and overrides" do
    defaults = BuildSettings.effective(nil, nil)
    assert defaults.tool_result_tokens == 2_000
    assert defaults.model_generation_tokens == nil

    assert {:ok, machine} =
             BuildSettings.parse(%{
               "tool_result_tokens" => 1000,
               "model_generation_tokens" => 12_000
             })

    assert {:ok, project} = BuildSettings.parse(%{"tool_result_tokens" => 2000})
    effective = BuildSettings.effective(machine, project)
    assert effective.tool_result_tokens == 2000
    assert effective.model_generation_tokens == 12_000

    for {key, invalid} <- [{"tool_result_tokens", 0}, {"model_generation_tokens", "2000"}] do
      assert {:error, [%{message: message}]} = BuildSettings.parse(%{key => invalid})
      assert message =~ key
    end
  end
end
