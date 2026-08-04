Code.require_file("support.exs", __DIR__)
require AshOnetime.CompileFixture

AshOnetime.CompileFixture.resource AshOnetime.CompileFixtures.NonceFailureOption do
  onetime do
    protect :redeem do
      strategy :one_time_nonce
      scope([{:static, "tenant"}])
      key({:verified, :proof, AshOnetime.CompileFixture.Verifier})
      window(max_age: 60, clock_skew: 5)
      on_definite_store_failure(:fail_closed)
    end
  end
end
