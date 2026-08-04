Code.require_file("support.exs", __DIR__)
require AshOnetime.CompileFixture

AshOnetime.CompileFixture.resource AshOnetime.CompileFixtures.MissingStrategy do
  onetime do
    protect :charge do
      scope([{:static, "tenant"}])
      key({:client, :idempotency_key})
    end
  end
end
