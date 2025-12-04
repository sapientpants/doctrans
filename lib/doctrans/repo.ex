defmodule Doctrans.Repo do
  use Ecto.Repo,
    otp_app: :doctrans,
    adapter: Ecto.Adapters.Postgres
end
