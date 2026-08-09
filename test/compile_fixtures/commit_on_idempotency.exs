Code.require_file("support.exs", __DIR__)
require AshOnetime.CompileFixture

AshOnetime.CompileFixture.resource AshOnetime.CompileFixtures.CommitOnIdempotency do
  onetime do
    protect :charge do
      strategy :idempotency
      scope([{:static, "tenant"}])
      key({:client, :idempotency_key})
      fingerprint(arguments: [:idempotency_key])

      response(AshOnetime.CompileFixture.Codec,
        fields: [],
        classify: AshOnetime.CompileFixture.Classifier
      )

      retention({1, :hour})
      commit(:independent)
    end
  end
end
