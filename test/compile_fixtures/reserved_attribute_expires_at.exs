Code.require_file("support.exs", __DIR__)
require AshOnetime.CompileFixture

AshOnetime.CompileFixture.resource AshOnetime.CompileFixtures.ReservedAttributeExpiresAt,
  attributes: {:reserved, :expires_at},
  actions: {:reserved_attribute, :expires_at} do
  onetime do
    protect :charge do
      strategy :idempotency
      scope([{:static, "tenant"}])
      key({:client, :idempotency_key})
    end
  end
end
