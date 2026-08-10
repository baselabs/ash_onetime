defmodule AshOnetime.Resource.VerifierTest do
  use ExUnit.Case, async: true

  alias AshOnetime.Resource.Info
  alias AshOnetime.Resource.Protection
  alias AshOnetime.Resource.Verifier
  alias AshOnetime.Test.Support.Resource
  alias Spark.Error.DslError

  @tag wrapper_protection_mutation: true
  test "postcompile verifier accepts exact normalized wrapper protection" do
    assert {:module, AshOnetime.Resource.Verifier} =
             Code.ensure_loaded(AshOnetime.Resource.Verifier)

    assert function_exported?(AshOnetime.Resource.Verifier, :verify, 1)
    assert length(Info.protections(Resource)) == 2

    protection = Info.protection(Resource, :charge)
    change = Resource |> Ash.Resource.Info.action(:charge) |> Map.fetch!(:changes) |> List.first()

    assert %Ash.Resource.Change{change: {AshOnetime.Change, opts}} = change
    assert opts[:protection] == protection
  end

  # M4: the verifier's verify_required_shape/2 re-asserts the AGENTS.md load-bearing
  # invariants (strategy in [:idempotency, :one_time_nonce]; scope non-nil; key non-nil) as
  # defense-in-depth against a future transformer regression. But the transformer's required/2
  # rejects these FIRST, so every compile-fixture that would exercise the verifier's reject
  # arms is short-circuited at the transformer — drop verify_required_shape and no test fails.
  # These tests drive verify_required_shape/2 DIRECTLY (exposed @doc false) with hand-built
  # %Protection{} structs, so each reject arm is proven to fire with its exact message.
  describe "verify_required_shape/2 (M4 defense-in-depth)" do
    # A minimal dsl_state satisfying verifier_error/2's get_persisted(:module) read; the
    # module is real (the test support resource) so the DslError carries a usable module.
    @verifier_dsl %{persist: %{module: AshOnetime.Test.Support.Resource}}

    @tag verifier_required_shape: true
    test "accepts a well-formed idempotency protection" do
      protection = %Protection{strategy: :idempotency, scope: [:s], key: [:k]}

      assert :ok = Verifier.verify_required_shape(@verifier_dsl, [protection])
    end

    @tag verifier_required_shape: true
    test "accepts a well-formed one_time_nonce protection" do
      protection = %Protection{strategy: :one_time_nonce, scope: [:s], key: [:k]}

      assert :ok = Verifier.verify_required_shape(@verifier_dsl, [protection])
    end

    @tag verifier_required_shape: true
    test "rejects a nil strategy (no default)" do
      protection = %Protection{strategy: nil, scope: [:s], key: [:k]}

      assert {:error, %DslError{message: "strategy is required and has no default"}} =
               Verifier.verify_required_shape(@verifier_dsl, [protection])
    end

    @tag verifier_required_shape: true
    test "rejects a strategy outside the allowed set" do
      protection = %Protection{strategy: :bogus, scope: [:s], key: [:k]}

      assert {:error, %DslError{message: "strategy must be :idempotency or :one_time_nonce"}} =
               Verifier.verify_required_shape(@verifier_dsl, [protection])
    end

    @tag verifier_required_shape: true
    test "rejects a nil scope (no global fallback)" do
      protection = %Protection{strategy: :idempotency, scope: nil, key: [:k]}

      assert {:error, %DslError{message: "scope is required and has no global fallback"}} =
               Verifier.verify_required_shape(@verifier_dsl, [protection])
    end

    @tag verifier_required_shape: true
    test "rejects a nil key" do
      protection = %Protection{strategy: :idempotency, scope: [:s], key: nil}

      assert {:error, %DslError{message: "key is required"}} =
               Verifier.verify_required_shape(@verifier_dsl, [protection])
    end

    @tag verifier_required_shape: true
    test "checks strategy before scope (a nil-strategy + nil-scope reports strategy first)" do
      # Pins the cond order: strategy is asserted before scope, so a malformed protection
      # carrying BOTH nils surfaces the strategy error, not the scope error.
      protection = %Protection{strategy: nil, scope: nil, key: nil}

      assert {:error, %DslError{message: "strategy is required and has no default"}} =
               Verifier.verify_required_shape(@verifier_dsl, [protection])
    end

    @tag verifier_required_shape: true
    test "halts at the first malformed protection in the list" do
      malformed = %Protection{strategy: :bogus, scope: [:s], key: [:k]}
      well_formed = %Protection{strategy: :idempotency, scope: [:s], key: [:k]}

      # The malformed first protection halts the reduce_while; the well-formed second is
      # never reached. Reordering (well-formed first) accepts the first and then rejects.
      assert {:error, %DslError{message: "strategy must be :idempotency or :one_time_nonce"}} =
               Verifier.verify_required_shape(@verifier_dsl, [malformed, well_formed])

      assert {:error, %DslError{message: "strategy must be :idempotency or :one_time_nonce"}} =
               Verifier.verify_required_shape(@verifier_dsl, [well_formed, malformed])
    end
  end
end
