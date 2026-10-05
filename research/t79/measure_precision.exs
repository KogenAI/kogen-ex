alias Kogen.Quality.Request
alias Kogen.Quality.Source
alias KogenChecks.PrecisionCases

Code.require_file("../../tools/kogen_checks/test/support/precision_cases.ex", __DIR__)

# Run only against fresh, disposable copies made by copy_precision_projects.py.
results =
  for label <- ["kogen", "campfire"] do
    root = Path.expand("_build/t79-#{label}-copy")
    input_dir = Path.join(root, "lib/t79_precision")
    if File.exists?(input_dir), do: raise("Recreate the disposable copies before measuring.")
    request = Request.new(root, root, %{}, %{})
    [natural] = Source.run(request)
    native = Enum.filter(natural.findings, &(&1.rule == "MissingExternalResource"))

    # Manual review: this module reads a JSON fixture into @expected at line 4,
    # with no resource declaration. All other natural findings require review.
    expected =
      if label == "campfire", do: [{"test/hearth/web_push_test.exs", 4}], else: []

    actual = Enum.map(native, &{&1.path, &1.line})
    if actual != expected, do: raise("Natural findings changed; review them before measuring.")

    natural_count =
      Enum.sum(
        for dir <- ["lib", "test"],
            do: length(Path.wildcard(Path.join([root, dir, "**/*.{ex,exs}"])))
      )

    File.mkdir_p!(input_dir)
    File.write!(Path.join(root, "input.txt"), "fixture input\n")
    File.write!(Path.join(root, "template.eex"), "fixture input\n")

    corpus =
      for {kind, samples} <- [
            {:positive, PrecisionCases.positives()},
            {:negative, PrecisionCases.negatives()}
          ],
          {name, body} <- samples do
        file = "lib/t79_precision/#{kind}_#{name}.ex"
        File.write!(Path.join(root, file), PrecisionCases.source("#{kind}_#{name}", body))
        %{kind: kind, file: file, name: name}
      end

    [measured] = Source.run(request)
    findings = Enum.filter(measured.findings, &(&1.rule == "MissingExternalResource"))

    cases =
      for sample <- corpus do
        hits = Enum.filter(findings, &(&1.path == sample.file))
        Map.put(sample, :findings, hits)
      end

    tp = Enum.count(cases, &(&1.kind == :positive and length(&1.findings) == 1))
    fp = Enum.count(cases, &(&1.kind == :negative and &1.findings != []))

    known = MapSet.new(Enum.map(corpus, & &1.file) ++ Enum.map(native, & &1.path))
    unexpected = Enum.reject(findings, &MapSet.member?(known, &1.path))
    fp = fp + length(unexpected)

    # Verify the suggested declaration clears the naturally occurring finding,
    # changing only the disposable Phoenix copy.
    cleared? =
      if label == "campfire" do
        file = Path.join(root, "test/hearth/web_push_test.exs")
        lines = file |> File.read!() |> String.split("\n")
        fixed = List.insert_at(lines, 3, ~s(  @external_resource "test/fixtures/web_push.json"))
        File.write!(file, Enum.join(fixed, "\n"))
        [repaired] = Source.run(request)
        not Enum.any?(repaired.findings, &(&1.path == "test/hearth/web_push_test.exs"))
      end

    %{
      project: label,
      natural_source_files: natural_count,
      natural_findings: native,
      natural_true_positives: length(native),
      natural_false_positives: 0,
      natural_fix_clears_finding: cleared?,
      controlled_true_positives: tp,
      controlled_false_positives: fp,
      controlled_negatives: length(PrecisionCases.negatives()),
      controlled_precision: tp / (tp + fp),
      combined_precision: (tp + length(native)) / (tp + length(native) + fp),
      cases: cases
    }
  end

File.write!("_build/t79-precision.json", JSON.encode!(results))

for result <- results do
  IO.puts(
    "#{result.project}: natural TP=#{result.natural_true_positives}, " <>
      "controlled TP=#{result.controlled_true_positives}, FP=#{result.controlled_false_positives}, " <>
      "precision=#{result.combined_precision * 100}%"
  )
end
