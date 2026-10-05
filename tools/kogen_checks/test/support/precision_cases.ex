defmodule KogenChecks.PrecisionCases do
  @moduledoc false

  def positives do
    [
      {"attribute_bang", "@data File.read!(\"input.txt\")"},
      {"attribute_read", "@data File.read(\"input.txt\")"},
      {"attribute_stream", "@data File.stream!(\"input.txt\") |> Enum.to_list()"},
      {"body_bang", "File.read!(\"input.txt\")"},
      {"body_read", "File.read(\"input.txt\")"},
      {"body_stream", "File.stream!(\"input.txt\") |> Enum.to_list()"},
      {"pipeline", "@data \"input.txt\" |> File.read!()"},
      {"joined", "@data File.read!(Path.join([__DIR__, \"input.txt\"]))"},
      {"expanded", "@data File.read!(Path.expand(\"input.txt\", __DIR__))"},
      {"attribute_path", "@path \"input.txt\"\n@data File.read!(@path)"},
      {"variable_path", "path = \"input.txt\"\nFile.read!(path)"},
      {"alias", "alias File, as: F\n@data F.read!(\"input.txt\")"},
      {"import", "import File, only: [read!: 1]\n@data read!(\"input.txt\")"},
      {"unrelated_resource", ~s{@external_resource "other.txt"\n@data File.read!("input.txt")}},
      {"sibling_module",
       ~s{defmodule Declared do\n@external_resource "input.txt"\nend\ndefmodule Missing do\n@data File.read!("input.txt")\nend}},
      {"joined_attributes",
       ~s{@dir Path.expand("priv", __DIR__)\n@path Path.join(@dir, "input.txt")\n@data File.read!(@path)}},
      {"path_alias", "alias Path, as: P\n@data File.read!(P.join(__DIR__, \"input.txt\"))"},
      {"template", "@data EEx.compile_file(\"template.eex\")"},
      {"open_read", "@data File.open!(\"input.txt\", [:read], fn io -> IO.read(io, :all) end)"},
      {"executed_callback", "@data Enum.map([\"input.txt\"], fn path -> File.read!(path) end)"},
      {"compile_branch", "@data (if true do\nFile.read!(\"input.txt\")\nend)"}
    ]
  end

  def negatives do
    [
      {"runtime_def", "def data, do: File.read!(\"input.txt\")"},
      {"runtime_private", "defp data, do: File.read!(\"input.txt\")"},
      {"unused_macro", "defmacro data, do: File.read!(\"input.txt\")"},
      {"closure", "@reader fn -> File.read!(\"input.txt\") end"},
      {"quoted", "@reader (quote do\nFile.read!(\"input.txt\")\nend)"},
      {"capture", "@reader &File.read!/1"},
      {"string", "@example \"File.read!(input)\""},
      {"declared_before", ~s{@external_resource "input.txt"\n@data File.read!("input.txt")}},
      {"declared_after", ~s{@data File.read!("input.txt")\n@external_resource "input.txt"}},
      {"declared_attribute",
       "@path Path.expand(\"input.txt\", __DIR__)\n@external_resource @path\n@data File.read!(@path)"},
      {"declared_variable",
       "path = Path.join(__DIR__, \"input.txt\")\n@external_resource path\nFile.read!(path)"},
      {"shadow_alias",
       "defmodule OtherFile do\ndef read!(_), do: :data\nend\nalias OtherFile, as: File\n@data File.read!(\"input.txt\")"},
      {"runtime_test", ~s{test "data" do\nFile.read!("input.txt")\nend}},
      {"runtime_setup", "setup do\nFile.read!(\"input.txt\")\nend"},
      {"declared_normalized",
       ~s{@external_resource Path.join(__DIR__, "input.txt")\n@data File.read!(Path.expand("./input.txt", __DIR__))}},
      {"declared_stream",
       ~s{@external_resource "input.txt"\n@data File.stream!("input.txt") |> Enum.to_list()}},
      {"declared_import",
       ~s{import File, only: [read!: 1]\n@external_resource "input.txt"\n@data read!("input.txt")}},
      {"declared_alias",
       ~s{alias File, as: F\n@external_resource "input.txt"\n@data F.read!("input.txt")}},
      {"symbolic_resource",
       "@path Application.app_dir(:hearth, \"priv/input.txt\")\n@external_resource @path\n@data File.read!(@path)"},
      {"inactive_branch", "@data (if false do\nFile.read!(\"input.txt\")\nend)"},
      {"nil_branch", "@data (if nil do\nFile.read!(\"input.txt\")\nend)"},
      {"excluded_import",
       "import File, except: [read!: 1]\nimport OtherReader, only: [read!: 1]\n@data read!(\"input.txt\")"},
      {"write_only", ~s{File.open!("output.txt", [:write], fn io -> IO.write(io, "data") end)}}
    ]
  end

  def source(name, body), do: "defmodule T79.Precision.#{Macro.camelize(name)} do\n#{body}\nend\n"
end
