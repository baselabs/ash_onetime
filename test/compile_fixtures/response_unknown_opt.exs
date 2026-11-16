Code.require_file("support.exs", __DIR__)
require AshOnetime.CompileFixture

# Unknown response options must fail compilation, including field: instead of fields:.
# No unknown option may silently remove the field allowlist.
# Keep the fixture otherwise well formed.
# Its failure must identify the unknown option.
AshOnetime.CompileFixture.resource AshOnetime.CompileFixtures.ResponseUnknownOpt do
  onetime do
    protect :charge do
      strategy :idempotency
      scope([{:static, "tenant"}])
      key({:client, :idempotency_key})
      fingerprint(arguments: [], attributes: [:account_id])

      response(AshOnetime.CompileFixture.Codec,
        field: [:id],
        classify: AshOnetime.CompileFixture.Classifier
      )

      retention({24, :hour})
    end
  end
end
