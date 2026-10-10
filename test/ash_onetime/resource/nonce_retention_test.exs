defmodule AshOnetime.Resource.NonceRetentionTest do
  use ExUnit.Case, async: false

  alias AshOnetime.Resource.Info

  test "the nonce guide DSL example compiles with separate retention" do
    path = "documentation/one-time-nonces.md"

    [_, source] =
      Regex.run(
        ~r/<!-- nonce-retention-dsl:start -->\s*```elixir\s*(.*?)\s*```/s,
        File.read!(path)
      )

    resource = compile_protection!(source)

    assert Info.protection(resource, :redeem).window == [
             max_age: 300,
             clock_skew: 0,
             retain_for: 664
           ]
  end

  test "DSL normalizes retention independently and preserves omitted window shape" do
    retained =
      compile_window!(
        "max_age: {5, :minute}, clock_skew: {1, :second}, retain_for: {664, :second}"
      )

    assert Info.protection(retained, :redeem).window == [
             max_age: 300,
             clock_skew: 1,
             retain_for: 664
           ]

    omitted = compile_window!("max_age: {5, :minute}, clock_skew: {1, :second}")
    assert Info.protection(omitted, :redeem).window == [max_age: 300, clock_skew: 1]
  end

  test "DSL rejects retention shorter than acceptance and beyond the duration sum bound" do
    for retention <- ["{299, :second}", "{2_147_483_647, :second}", "{-1, :second}", "nil"] do
      assert_raise Spark.Error.DslError, ~r/retain_for/, fn ->
        compile_window!(
          "max_age: {5, :minute}, clock_skew: {1, :second}, retain_for: #{retention}"
        )
      end
    end
  end

  defp compile_window!(window) do
    compile_protection!("""
    protect :redeem do
      strategy :one_time_nonce
      scope [{:static, "retention"}]
      key {:verified, :proof, MyApp.DPoPVerifier}
      window #{window}
    end
    """)
  end

  defp compile_protection!(protection) do
    module = Module.concat(__MODULE__, "Resource#{System.unique_integer([:positive])}")

    protection =
      String.replace(
        protection,
        "MyApp.DPoPVerifier",
        "AshOnetime.Test.LivebookExamples.ProofVerifier"
      )

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use Ash.Resource, domain: nil, data_layer: AshPostgres.DataLayer,
        extensions: [AshOnetime.Resource]
      postgres do
        table "nonce_retention_examples"
        repo AshOnetime.Test.Repo
      end
      attributes do
        uuid_primary_key :id
      end
      actions do
        create :redeem do
          accept []
          argument :proof, :string, allow_nil?: false
        end
      end
      onetime do
        #{protection}
      end
    end
    """)

    module
  end
end
