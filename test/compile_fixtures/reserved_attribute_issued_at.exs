Code.require_file("support.exs", __DIR__)
require AshOnetime.CompileFixture

AshOnetime.CompileFixture.resource AshOnetime.CompileFixtures.ReservedAttributeIssuedAt,
  attributes: {:reserved, :issued_at},
  actions: {:reserved_attribute, :issued_at} do
  onetime do
    protect :charge do
      strategy :idempotency
      scope([{:static, "tenant"}])
      key({:client, :idempotency_key})
    end
  end
end
