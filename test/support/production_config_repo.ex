defmodule Doctrans.ProductionConfigRepo do
  @moduledoc false
  use Ecto.Repo,
    otp_app: :doctrans,
    adapter: Ecto.Adapters.Postgres
end
