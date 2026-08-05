Code.require_file("support.exs", __DIR__)
require AshOnetime.CompileFixture

AshOnetime.CompileFixture.resource AshOnetime.CompileFixtures.AttributeMultitenantUnscoped,
  multitenancy: :attribute_account_id do
  onetime do
    protect :charge do
      strategy :idempotency
      scope([{:static, "shared"}])
      key({:client, :idempotency_key})
      fingerprint(arguments: [], attributes: [:amount])
      response(AshOnetime.CompileFixture.Codec, classify: AshOnetime.CompileFixture.Classifier)
      retention(60)
    end
  end
end
