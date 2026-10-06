require "json"
require "minitest"

# Rails' test "A1 outcome" DSL and plain Minitest's test_A1_outcome both identify A1.
# Write every result, including untagged results, as the ExUnit reporter does.
class KogenLedgerReporter < Minitest::AbstractReporter
  def record(result)
    id = result.name.match(/\Atest[_ ](A\d+)(?:[_ ]|\z)/)
    tag = id ? "#{ENV.fetch('KOGEN_LEDGER_SLUG')}/#{id[1]}" : ""
    status = if result.skipped?
      "skipped"
    elsif result.passed?
      "passed"
    else
      "failed"
    end
    row = {tag: tag, test: result.name, status: status}
    File.open(ENV.fetch("KOGEN_LEDGER_REPORT"), "a") { |file| file.puts(JSON.generate(row)) }
  end
end

module Minitest
  def self.plugin_kogen_ledger_init(_options)
    reporter << KogenLedgerReporter.new
  end

  extensions << "kogen_ledger"
end
