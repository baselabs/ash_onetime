Code.require_file("support.exs", __DIR__)
require AshOnetime.CompileFixture

AshOnetime.CompileFixture.resource AshOnetime.CompileFixtures.NontransactionalGeneric,
  actions: :nontransactional_generic do
  onetime do
    protect :redeem do
      strategy :one_time_nonce
      scope([{:static, "tenant"}])
      key({:verified, :proof, AshOnetime.CompileFixture.Verifier})
      window(max_age: 60, clock_skew: 5)
    end
  end
end
