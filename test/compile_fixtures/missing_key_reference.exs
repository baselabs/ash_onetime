Code.require_file("support.exs", __DIR__)
require AshOnetime.CompileFixture

AshOnetime.CompileFixture.resource AshOnetime.CompileFixtures.MissingKeyReference do
  onetime do
    protect :charge do
      strategy :idempotency
      scope([{:static, "tenant"}])
      key({:client, :missing_key})
      fingerprint(arguments: [], attributes: [:account_id])

      response(AshOnetime.CompileFixture.Codec,
        classify: AshOnetime.CompileFixture.Classifier
      )

      retention(60)
    end
  end
end
