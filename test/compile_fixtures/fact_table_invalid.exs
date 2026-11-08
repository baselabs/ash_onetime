Code.require_file("support.exs", __DIR__)
require AshOnetime.CompileFixture

AshOnetime.CompileFixture.resource AshOnetime.CompileFixtures.FactTableInvalid do
  context_boundary do
    fact_table("Ledger Facts")
  end
end
