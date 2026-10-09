# Runs inside the isolated project build, never inside the command application.
root = Mix.Project.config() |> Keyword.fetch!(:app)
provided = ~w(kernel stdlib elixir logger compiler crypto public_key ssl ssh sasl runtime_tools iex asn1)a
collect = fn collect, app, seen ->
  if app in provided or Map.has_key?(seen, Atom.to_string(app)) do
    seen
  else
    app_file = :code.where_is_file(String.to_charlist("#{app}.app"))
    if app_file == :non_existing, do: raise("Missing runtime application #{app}")
    {:ok, [{:application, ^app, props}]} = :file.consult(app_file)
    directory = app_file |> to_string() |> Path.dirname() |> Path.dirname()
    files = Path.wildcard(Path.join(directory, "ebin/*")) ++ Path.wildcard(Path.join(directory, "priv/**/*"), match_dot: true)
    bundle = for file <- files, File.regular?(file), into: %{} do
      {Path.relative_to(file, directory), Base.encode64(File.read!(file))}
    end
    seen = Map.put(seen, Atom.to_string(app), bundle)
    optional = Keyword.get(props, :optional_applications, [])
    dependencies = Keyword.get(props, :applications, []) ++ Keyword.get(props, :included_applications, [])
    dependencies = Enum.reject(dependencies, fn dep ->
      dep in optional and :code.where_is_file(String.to_charlist("#{dep}.app")) == :non_existing
    end)
    Enum.reduce(dependencies, seen, fn dep, acc -> collect.(collect, dep, acc) end)
  end
end
bundle = collect.(collect, root, %{})
bytes = JSON.encode!(%{applications: bundle})
if byte_size(bytes) > 67_108_864, do: raise("Deployment exceeds 64 MiB")
File.write!(".ssi-deployment.json", bytes)
IO.puts("Prepared #{map_size(bundle)} runtime applications (#{byte_size(bytes)} bytes).")
