database_url = System.fetch_env!("DATABASE_URL")

unless database_url == "ecto://postgres:postgres@127.0.0.1:18841/ash_onetime_test" do
  raise "DATABASE_URL must target the dedicated ash_onetime_test database on 127.0.0.1:18841"
end

{:ok, _supervisor} = AshOnetime.Test.Application.start(:normal, [])
AshOnetime.Test.Migration.assert_isolated_database!()
Ecto.Adapters.SQL.Sandbox.mode(AshOnetime.Test.Repo, :manual)

ExUnit.start()
