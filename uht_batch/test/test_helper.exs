{:ok, _} = Application.ensure_all_started(:uht_batch)

for file <- Path.wildcard("test/support/**/*.ex"), do: Code.require_file(file)

ExUnit.start(exclude: [:integration, :web])
