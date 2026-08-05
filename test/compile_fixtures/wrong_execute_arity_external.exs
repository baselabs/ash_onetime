Code.require_file("support.exs", __DIR__)
require AshOnetime.CompileFixture

AshOnetime.CompileFixture.resource AshOnetime.CompileFixtures.WrongExecuteArityExternal do
  onetime do
    protect :charge do
      strategy :idempotency
      scope([{:static, "tenant"}])
      key({:client, :idempotency_key})
      fingerprint(arguments: [], attributes: [:account_id])
      response(AshOnetime.CompileFixture.Codec, classify: AshOnetime.CompileFixture.Classifier)
      retention(60)
      external_effect(AshOnetime.CompileFixture.WrongExecuteArityExternal)
    end
  end
end
