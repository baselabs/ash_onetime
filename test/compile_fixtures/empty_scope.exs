Code.require_file("support.exs", __DIR__)
require AshOnetime.CompileFixture

AshOnetime.CompileFixture.resource AshOnetime.CompileFixtures.EmptyScope do
  onetime do
    protect :charge do
      strategy :idempotency
      scope([])
      key({:client, :idempotency_key})
    end
  end
end
