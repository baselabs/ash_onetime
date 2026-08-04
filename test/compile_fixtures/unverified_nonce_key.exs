Code.require_file("support.exs", __DIR__)
require AshOnetime.CompileFixture

AshOnetime.CompileFixture.resource AshOnetime.CompileFixtures.UnverifiedNonceKey do
  onetime do
    protect :redeem do
      strategy :one_time_nonce
      scope([{:static, "tenant"}])
      key({:argument, :proof})
      window(max_age: 60, clock_skew: 5)
    end
  end
end
