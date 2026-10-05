# The internal Credo adapters share the dependency-free analyzers used by the gate.
# Load those sources when this tooling package is tested on its own.
for name <- ["scope", "path", "external_resource", "map_shapes"] do
  module = Module.concat([Kogen.Quality.Source, Macro.camelize(name)])

  if !Code.ensure_loaded?(module) do
    Code.require_file(Path.expand("../../../lib/kogen/quality/source/#{name}.ex", __DIR__))
  end
end

_ = Application.ensure_all_started(:credo)
ExUnit.start()
