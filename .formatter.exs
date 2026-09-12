[
  import_deps: [:ecto, :ecto_sql, :phoenix],
  subdirectories: ["priv/*/migrations"],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  # Dotfiles are listed explicitly: Path.wildcard/1 does not match a leading dot,
  # so a "*.exs" glob silently skips .credo.exs and .dialyzer_ignore.exs.
  inputs: [
    "{mix,.formatter,.credo,.dialyzer_ignore}.exs",
    "{config,lib,test,scripts}/**/*.{heex,ex,exs}",
    "priv/*/seeds.exs"
  ]
]
