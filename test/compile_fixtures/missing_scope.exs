Code.require_file("support.exs", __DIR__)
require AshOnetime.CompileFixture

AshOnetime.CompileFixture.resource AshOnetime.CompileFixtures.MissingScope do
  onetime do
    protect :charge do
      strategy :idempotency
      key({:client, :idempotency_key})
    end
  end
end
