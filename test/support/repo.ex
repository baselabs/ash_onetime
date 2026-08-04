defmodule AshOnetime.Test.Repo do
  @moduledoc false

  use AshPostgres.Repo, otp_app: :ash_onetime

  @impl AshPostgres.Repo
  def installed_extensions, do: ["ash-functions"]

  @impl AshPostgres.Repo
  def min_pg_version, do: %Version{major: 18, minor: 0, patch: 0}
end
