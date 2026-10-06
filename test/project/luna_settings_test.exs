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
end
