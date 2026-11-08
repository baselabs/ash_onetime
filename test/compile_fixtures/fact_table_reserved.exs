Code.require_file("support.exs", __DIR__)
require AshOnetime.CompileFixture

AshOnetime.CompileFixture.resource AshOnetime.CompileFixtures.FactTableReserved do
  context_boundary do
    fact_table("ash_onetime_facts")
  end
end
