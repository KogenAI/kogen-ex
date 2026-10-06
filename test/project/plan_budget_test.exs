defmodule Kogen.Project.PlanBudgetTest do
  use Kogen.Testkit.Case

  alias Kogen.Project

  test "projects can opt into fuller plans and override the machine budget", %{tmp_dir: root} do
    path = Path.join(root, ".kogen/project.yaml")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "name: fixture\nchecks: []\nbuild:\n  plan_max_words: 1200\n")
    assert {:ok, project} = Project.load(root)

    machine_home = Path.join(root, "machine")
    machine_path = Path.join(machine_home, ".kogen/config.yaml")
    File.mkdir_p!(Path.dirname(machine_path))
    File.write!(machine_path, "build:\n  plan_max_words: 800\n")
    assert {:ok, machine} = Project.load_machine_build_settings(machine_home)
    assert Project.effective_build_settings(machine, project.build).plan_max_words == 1200
    assert Project.effective_build_settings(machine, nil).plan_max_words == 800
    assert Project.effective_build_settings(nil, nil).plan_max_words == 500
  end

  test "invalid configured budgets produce a useful project error", %{tmp_dir: root} do
    path = Path.join(root, ".kogen/project.yaml")
    File.mkdir_p!(Path.dirname(path))

    for value <- ["299", "2001", "wide"] do
      File.write!(path, "name: fixture\nchecks: []\nbuild:\n  plan_max_words: #{value}\n")
      assert {:error, issues} = Project.load(root)

      assert Enum.any?(
               issues,
               &String.contains?(&1.message, "plan_max_words must be an integer from 300 to 2000")
             )
    end
  end
end
