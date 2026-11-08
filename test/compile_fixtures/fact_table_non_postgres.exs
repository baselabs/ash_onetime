Code.require_file("support.exs", __DIR__)
require AshOnetime.CompileFixture

AshOnetime.CompileFixture.resource AshOnetime.CompileFixtures.FactTableNonPostgres,
  data_layer: Ash.DataLayer.Ets do
  context_boundary do
    fact_table("fixture_facts")
  end
end
