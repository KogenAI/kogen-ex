defmodule Kogen.Workspace.WorkspacesTest do
  use Kogen.Testkit.Case

  alias Kogen.Workspace.Workspaces

  test "workspace key is readable, stable, and distinguishes checkout paths", %{tmp_dir: tmp_dir} do
    project = Path.join(tmp_dir, "careful-rebuild")
    home = Path.join(tmp_dir, "home")
    root = Workspaces.root(project, home)

    assert Path.dirname(root) == Path.join([home, ".kogen", "workspaces"])
    assert Regex.match?(~r/careful-rebuild-[0-9a-f]{10}\z/, Path.basename(root))

    assert Workspaces.root(project, home) == root
    refute Workspaces.root(Path.join(tmp_dir, "other"), home) == root
  end

  test "workspace key canonicalizes a symlinked project directory", %{tmp_dir: tmp_dir} do
    project = Path.join(tmp_dir, "project")
    symlink = Path.join(tmp_dir, "project-link")
    home = Path.join(tmp_dir, "home")

    File.mkdir_p!(project)
    File.ln_s!(project, symlink)

    assert Workspaces.root(symlink, home) == Workspaces.root(project, home)
  end
end
