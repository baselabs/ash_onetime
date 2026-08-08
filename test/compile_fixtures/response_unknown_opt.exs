Code.require_file("support.exs", __DIR__)
require AshOnetime.CompileFixture

# A typo'd response option (`field:` for `fields:`) MUST fail to compile: the `@response`
# entity's schema rejects unknown keys (ARCH-4). Before the typed-schema change this was a
# silent drop — `field:` landed in the freeform `opts` keyword bag and the protection compiled
# green with NO field allowlist. This fixture is the RED-capable proof that the silent drop is
# closed: it must be REJECTED. It is otherwise well-formed (valid strategy/scope/key/
# fingerprint/classify) so the ONLY reason it can fail is the unknown `field:` opt — proving
# the rejection is specific to the unknown key, not a vacuous failure.
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
