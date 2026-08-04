Code.require_file("support.exs", __DIR__)
require AshOnetime.CompileFixture

AshOnetime.CompileFixture.resource AshOnetime.CompileFixtures.ReadAction, actions: :read do
  onetime do
    protect :lookup do
      strategy :one_time_nonce
      scope([{:static, "tenant"}])
      key({:minted, AshOnetime.CompileFixture.Verifier})
      window(max_age: 60, clock_skew: 5)
    end
  end
end
