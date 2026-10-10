defmodule AshOnetime.Resource.NonceRetentionTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.{Admission, Error, Token, Verified, Window}
  alias AshOnetime.Resource.Info

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  defmodule SharedClock do
    @moduledoc false
    def now, do: :persistent_term.get(__MODULE__)
    def freeze(now), do: :persistent_term.put(__MODULE__, now)
  end

  defmodule SignedProof do
    @moduledoc false
    @behaviour AshOnetime.Verifier
    def algorithm, do: :hmac_sha256
    def trust_model, do: :same_service

    def verify(proof, _context) do
      with {:ok, token} <-
             Token.verify(proof, AshOnetime.Test.KeyResolver,
               algorithm: :hmac_sha256,
               namespace: "retention",
               max_age: 10_000,
               clock: SharedClock,
               resolver_context: :persistent_term.get(__MODULE__)
             ) do
        Verified.new(key: token.key, issued_at: token.issued_at, verifier_id: "signed-retention")
      end
    end
  end

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  # :with_action is the DSL name for transaction-owned commit in this release.
  for commit <- [:with_action, :independent] do
    @tag unboxed: true
    @tag retention_forward_mutation: true
    test "Ash resource retention reaches #{commit} claims", %{prefix: prefix} do
      commit = unquote(commit)
      repo = start_unboxed_repo!()
      previous = Repo.get_dynamic_repo()
      Repo.put_dynamic_repo(repo)
      issued = Clock.now()
      SharedClock.freeze(issued)
      material = %{key: :crypto.strong_rand_bytes(32), trust: :same_service}

      keys = %{
        keys: %{
          {:sign, "retention", :hmac_sha256} => material,
          {:verify, "retention", :hmac_sha256} => material
        }
      }

      :persistent_term.put(SignedProof, keys)

      try do
        SQL.query!(
          repo,
          ~s|CREATE TABLE IF NOT EXISTS "#{prefix}".nonce_retention_examples (id uuid PRIMARY KEY)|,
          []
        )

        SharedClock.freeze(issued)

        resource =
          compile_protection!("""
          protect :redeem do
            strategy :one_time_nonce
            scope [{:static, "retention"}]
            key {:verified, :proof, #{inspect(SignedProof)}}
            window max_age: {300, :second}, clock_skew: {0, :second}, retain_for: {664, :second}
            commit #{inspect(commit)}
          end
          """)

        {:ok, token} =
          Token.mint("resource-#{commit}",
            algorithm: :hmac_sha256,
            key_id: "retention",
            namespace: "retention",
            issued_at: issued
          )

        {:ok, proof} = Token.sign(token, AshOnetime.Test.KeyResolver, keys)

        subject =
          resource
          |> Ash.Changeset.for_create(:redeem, %{proof: proof}, domain: Domain)
          |> Ash.Changeset.set_tenant(prefix)

        protection = Info.protection(resource, :redeem)
        assert protection.commit == commit
        assert {:ok, prepared} = Admission.prepare(subject, protection, %{})
        # Inject only time at the prepared-request boundary. The resource's DSL,
        # verifier, locator and retain_for all come through real Admission.prepare.
        state = %{prepared | request: %{prepared.request | clock: SharedClock}}
        # Exercise the real Ash action dispatch, including claim_committed for
        # independent protection. Only the late replay needs a moved store clock.
        assert {:ok, _record} = Ash.create(subject)

        assert {:ok, deadline} =
                 Postgres.nonce_retention_deadline(
                   state.target,
                   state.request.operation_hash,
                   state.request.scope_hash,
                   state.request.key_hash
                 )

        assert deadline == Window.cleanup_after(issued, 664, 0)

        SharedClock.freeze(DateTime.add(issued, 400, :second))

        assert {:error, %Error{code: :nonce_already_used}} =
                 resolve(claim(state, commit), state, protection)
      after
        Repo.put_dynamic_repo(previous)
        :persistent_term.erase(SharedClock)
        :persistent_term.erase(SignedProof)
      end
    end
  end

  defp claim(state, :with_action) do
    {:ok, result} = Repo.transaction(fn -> Store.claim(state.target, state.request) end)
    result
  end

  defp claim(state, :independent), do: Store.claim_committed(state.target, state.request)

  defp resolve(result, state, protection) do
    mode = if protection.commit == :independent, do: :committed_external_claim, else: :local_claim
    Admission.resolve(result, state, protection, System.monotonic_time(), mode)
  end

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
      multitenancy do
        strategy :context
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
