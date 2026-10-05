defmodule Kogen.Provider.AccountChoicesTest do
  use Kogen.Testkit.Case

  alias Kogen.Provider.ChatGPT.CredentialStore

  test "no file means no default and no project choices", %{tmp_dir: tmp_dir} do
    assert CredentialStore.account_choices(tmp_dir) == {:ok, %{default: nil, projects: %{}}}
  end

  test "writes the default and per-project choices to one machine file", %{tmp_dir: tmp_dir} do
    project = Path.join(tmp_dir, "client \"app\"")
    gone = Path.join(tmp_dir, "deleted")
    File.mkdir_p!(project)
    File.mkdir_p!(gone)

    assert CredentialStore.put_account_choice(tmp_dir, :default, "kogen") == :ok
    assert CredentialStore.put_account_choice(tmp_dir, {:project, gone}, "old") == :ok
    File.rmdir!(gone)
    assert CredentialStore.put_account_choice(tmp_dir, {:project, project}, "client") == :ok

    assert CredentialStore.account_choices(tmp_dir) ==
             {:ok, %{default: "kogen", projects: %{project => "client"}}}

    assert File.read!(Path.join(tmp_dir, "accounts.yaml")) == """
           # Kogen accounts on this machine, written by kogen provider use.
           chatgpt:
             default: kogen
             projects:
               - path: "#{tmp_dir}/client \\"app\\""
                 account: client
           """
  end

  test "rejects invalid labels and files", %{tmp_dir: tmp_dir} do
    assert CredentialStore.put_account_choice(tmp_dir, :default, "bad label") ==
             {:error, :invalid_account_label}

    path = Path.join(tmp_dir, "accounts.yaml")
    File.write!(path, "chatgpt:\n  default: \"no spaces allowed\"\n")
    assert CredentialStore.account_choices(tmp_dir) == {:error, {:invalid_accounts_file, path}}

    File.write!(path, "other: x\n")
    assert CredentialStore.account_choices(tmp_dir) == {:error, {:invalid_accounts_file, path}}
  end
end
