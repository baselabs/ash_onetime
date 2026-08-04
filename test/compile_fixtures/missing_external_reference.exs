Code.require_file("support.exs", __DIR__)
require AshOnetime.CompileFixture

AshOnetime.CompileFixture.resource AshOnetime.CompileFixtures.MissingExternalReference do
  onetime do
    protect :charge do
      strategy :idempotency
      scope([{:static, "tenant"}])
      key({:external, :missing_external_key})
      fingerprint(arguments: [], attributes: [:account_id])

      response(AshOnetime.CompileFixture.Codec,
        classify: AshOnetime.CompileFixture.Classifier
      )

      retention(60)
    end
  end
end
