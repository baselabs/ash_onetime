Code.require_file("support.exs", __DIR__)
require AshOnetime.CompileFixture

# M2: a protected resource that DECLARES a reserved-named attribute (`:key`) but does NOT
# accept it on the protected action must fail compilation — the compile-time check now
# matches the runtime guard (reject_reserved/1 checks changeset.attributes). Previously
# this compiled clean (the transformer checked arguments/accept only, not declared attrs).
AshOnetime.CompileFixture.resource AshOnetime.CompileFixtures.ReservedAttributeUnacceptedKey,
  attributes: {:reserved, :key},
  actions: {:reserved_attribute_unaccepted, :key} do
  onetime do
    protect :charge do
      strategy :idempotency
      scope([{:static, "tenant"}])
      key({:client, :idempotency_key})
    end
  end
end
