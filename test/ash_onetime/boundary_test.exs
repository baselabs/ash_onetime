defmodule AshOnetime.BoundaryTest do
  @moduledoc """
  Functional coverage for the conditional-append context boundary: read cutoffs,
  admitted and refused appends, tenant isolation, fail-closed inputs, and the
  Ash change surface. Concurrency proofs live in BoundaryContentionTest.
  """
  use AshOnetime.Test.DataCase, async: false

  alias AshOnetime.Boundary
  alias AshOnetime.Error
  alias AshOnetime.Test.Repo
  alias AshOnetime.Test.Support.{BoundaryResource, UnscopedBoundaryResource}
  alias Ecto.Adapters.SQL

  @tenant "boundary-tenant"

  # Repo.transaction returns {:ok, inner}; an append that refuses commits
  # nothing and answers its error tuple, so unwrap to the boundary's answer.
  defp in_transaction(fun), do: Repo.transaction(fun) |> elem(1)

  setup do
    SQL.query!(
      Repo,
      """
      CREATE TABLE IF NOT EXISTS boundary_examples (
        id uuid PRIMARY KEY,
        context_tag text NOT NULL,
        amount bigint
      )
      """,
      []
    )

    %{tenant: @tenant <> "-" <> Integer.to_string(System.unique_integer([:positive]))}
  end

  describe "read/3" do
    test "an empty context reads as no facts and cutoff 0", %{tenant: tenant} do
      assert {:ok, %{facts: [], cutoff: 0}} =
               Boundary.read(BoundaryResource, {:tag, "cart:1"}, tenant: tenant)
    end

    test "returns matching facts newest first with the highest matching seq as cutoff", %{
      tenant: tenant
    } do
      in_transaction(fn ->
        {:ok, [%{seq: hold_seq}]} =
          Boundary.append_if(
            BoundaryResource,
            {:tag, "cart:1"},
            0,
            [
              %{type: "hold", tags: ["cart:1"]}
            ],
            tenant: tenant
          )

        # The second append must present the first's seq as its cutoff.
        {:ok, _} =
          Boundary.append_if(
            BoundaryResource,
            {:tag, "cart:1"},
            hold_seq,
            [
              %{type: "release", tags: ["cart:1"]}
            ],
            tenant: tenant
          )
      end)

      assert {:ok, %{facts: facts, cutoff: cutoff}} =
               Boundary.read(BoundaryResource, {:tag, "cart:1"}, tenant: tenant)

      assert length(facts) == 2
      assert [newer, older] = facts
      assert newer.seq > older.seq
      assert newer.seq == cutoff
      assert older.type == "hold"
      assert newer.type == "release"
      assert Enum.all?(facts, &(&1.tags == ["cart:1"]))
    end

    test "non-matching facts neither appear nor raise the cutoff", %{tenant: tenant} do
      in_transaction(fn ->
        {:ok, _} =
          Boundary.append_if(
            BoundaryResource,
            {:tag, "other:cart"},
            0,
            [
              %{type: "hold", tags: ["other:cart"]}
            ],
            tenant: tenant
          )
      end)

      assert {:ok, %{facts: [], cutoff: 0}} =
               Boundary.read(BoundaryResource, {:tag, "cart:2"}, tenant: tenant)
    end

    test "reads never cross tenants", %{tenant: tenant} do
      in_transaction(fn ->
        {:ok, _} =
          Boundary.append_if(
            BoundaryResource,
            {:tag, "cart:3"},
            0,
            [
              %{type: "hold", tags: ["cart:3"]}
            ],
            tenant: tenant
          )
      end)

      assert {:ok, %{facts: [], cutoff: 0}} =
               Boundary.read(BoundaryResource, {:tag, "cart:3"}, tenant: tenant <> "-other")
    end

    test "limit bounds the returned page while the cutoff still spans every matching fact", %{
      tenant: tenant
    } do
      in_transaction(fn ->
        Enum.reduce(1..3, 0, fn _index, cutoff ->
          {:ok, [%{seq: seq}]} =
            Boundary.append_if(
              BoundaryResource,
              {:tag, "cart:4"},
              cutoff,
              [
                %{type: "hold", tags: ["cart:4"]}
              ],
              tenant: tenant
            )

          seq
        end)
      end)

      assert {:ok, %{facts: facts, cutoff: cutoff}} =
               Boundary.read(BoundaryResource, {:tag, "cart:4"}, tenant: tenant, limit: 2)

      assert length(facts) == 2
      # The page is newest-first, so the highest matching seq is always in it.
      assert cutoff == hd(facts).seq
    end

    test "fails closed without a tenant" do
      assert {:error, %Error{code: :invalid_request}} =
               Boundary.read(BoundaryResource, {:tag, "cart:5"})
    end

    test "fails closed on a resource without a context_boundary section" do
      assert {:error, %Error{code: :invalid_request}} =
               Boundary.read(UnscopedBoundaryResource, {:tag, "cart:6"}, tenant: @tenant)
    end
  end

  describe "append_if/5 on an unchanged context" do
    test "admits and returns appended facts with assigned seq values", %{tenant: tenant} do
      assert {:ok, [%{seq: seq, type: "hold", tags: ["cart:7"]} = appended]} =
               in_transaction(fn ->
                 Boundary.append_if(
                   BoundaryResource,
                   {:tag, "cart:7"},
                   0,
                   [
                     %{type: "hold", tags: ["cart:7"]}
                   ],
                   tenant: tenant
                 )
               end)

      assert is_integer(seq) and seq > 0
      assert %DateTime{} = appended.inserted_at

      assert {:ok, %{facts: [fact]}} =
               Boundary.read(BoundaryResource, {:tag, "cart:7"}, tenant: tenant)

      assert fact.seq == seq
    end

    test "a read cutoff from the same context admits the append", %{tenant: tenant} do
      {:ok, %{cutoff: cutoff}} =
        Boundary.read(BoundaryResource, {:any, [{:tag, "cart:8"}, {:tag, "cart:8-b"}]},
          tenant: tenant
        )

      assert {:ok, _} =
               in_transaction(fn ->
                 Boundary.append_if(
                   BoundaryResource,
                   {:any, [{:tag, "cart:8"}, {:tag, "cart:8-b"}]},
                   cutoff,
                   [
                     %{type: "hold", tags: ["cart:8"]}
                   ],
                   tenant: tenant
                 )
               end)
    end

    test "requires the caller's open transaction", %{tenant: tenant} do
      assert {:error, %Error{code: :not_in_transaction}} =
               Boundary.append_if(
                 BoundaryResource,
                 {:tag, "cart:9"},
                 0,
                 [
                   %{type: "hold", tags: ["cart:9"]}
                 ],
                 tenant: tenant
               )
    end

    test "a fact matching the query above the cutoff refuses with the highest such seq", %{
      tenant: tenant
    } do
      {:ok, _} =
        in_transaction(fn ->
          Boundary.append_if(
            BoundaryResource,
            {:tag, "cart:10"},
            0,
            [
              %{type: "hold", tags: ["cart:10"]}
            ],
            tenant: tenant
          )
        end)

      assert {:error, {:context_changed, changed_to}} =
               in_transaction(fn ->
                 Boundary.append_if(
                   BoundaryResource,
                   {:tag, "cart:10"},
                   0,
                   [
                     %{type: "hold", tags: ["cart:10"]}
                   ],
                   tenant: tenant
                 )
               end)

      assert is_integer(changed_to) and changed_to > 0
    end

    test "a non-matching fact above the cutoff does not refuse the append", %{tenant: tenant} do
      {:ok, _} =
        in_transaction(fn ->
          Boundary.append_if(
            BoundaryResource,
            {:tag, "elsewhere"},
            0,
            [
              %{type: "hold", tags: ["elsewhere"]}
            ],
            tenant: tenant
          )
        end)

      assert {:ok, _} =
               in_transaction(fn ->
                 Boundary.append_if(
                   BoundaryResource,
                   {:tag, "cart:11"},
                   0,
                   [
                     %{type: "hold", tags: ["cart:11"]}
                   ],
                   tenant: tenant
                 )
               end)
    end

    test "facts committing under another tenant never change this tenant's context", %{
      tenant: tenant
    } do
      {:ok, _} =
        in_transaction(fn ->
          Boundary.append_if(
            BoundaryResource,
            {:tag, "cart:12"},
            0,
            [
              %{type: "hold", tags: ["cart:12"]}
            ],
            tenant: tenant <> "-peer"
          )
        end)

      assert {:ok, _} =
               in_transaction(fn ->
                 Boundary.append_if(
                   BoundaryResource,
                   {:tag, "cart:12"},
                   0,
                   [
                     %{type: "hold", tags: ["cart:12"]}
                   ],
                   tenant: tenant
                 )
               end)
    end

    test "appends several facts in one admitted call", %{tenant: tenant} do
      assert {:ok, appended} =
               in_transaction(fn ->
                 Boundary.append_if(
                   BoundaryResource,
                   {:any, [{:tag, "cart:13"}, {:tag, "cart:13-b"}]},
                   0,
                   [
                     %{type: "hold", tags: ["cart:13"]},
                     %{type: "hold", tags: ["cart:13", "cart:13-b"]}
                   ],
                   tenant: tenant
                 )
               end)

      assert length(appended) == 2
      assert [first, second] = appended
      assert second.seq > first.seq
    end
  end

  describe "append_if/5 fail-closed inputs" do
    test "requires a tenant" do
      assert {:error, %Error{code: :invalid_request}} =
               in_transaction(fn ->
                 Boundary.append_if(BoundaryResource, {:tag, "x"}, 0, [
                   %{type: "hold", tags: ["x"]}
                 ])
               end)
    end

    test "refuses a query naming no tag", %{tenant: tenant} do
      assert {:error, %Error{code: :invalid_request}} =
               in_transaction(fn ->
                 Boundary.append_if(
                   BoundaryResource,
                   {:type, "hold"},
                   0,
                   [
                     %{type: "hold", tags: ["x"]}
                   ],
                   tenant: tenant
                 )
               end)
    end

    test "refuses a query a matching fact could satisfy without carrying a named tag", %{
      tenant: tenant
    } do
      unsound = {:any, [type: "hold", tag: "cart:14"]}

      assert {:error, %Error{code: :invalid_request}} =
               in_transaction(fn ->
                 Boundary.append_if(
                   BoundaryResource,
                   unsound,
                   0,
                   [
                     %{type: "hold", tags: ["cart:14"]}
                   ],
                   tenant: tenant
                 )
               end)

      negation = {:all, [[not: {:tag, "cart:15"}], {:tag, "cart:16"}]}

      assert {:error, %Error{code: :invalid_request}} =
               in_transaction(fn ->
                 Boundary.append_if(
                   BoundaryResource,
                   negation,
                   0,
                   [
                     %{type: "hold", tags: ["cart:16"]}
                   ],
                   tenant: tenant
                 )
               end)
    end

    test "refuses an oversized query", %{tenant: tenant} do
      big = {:any, for(i <- 1..33, do: {:tag, "t#{i}"})}

      assert {:error, %Error{code: :invalid_request}} =
               in_transaction(fn ->
                 Boundary.append_if(BoundaryResource, big, 0, [%{type: "hold", tags: ["t1"]}],
                   tenant: tenant
                 )
               end)
    end

    test "refuses empty facts, over-tagged facts, and bad tag bytes", %{tenant: tenant} do
      assert {:error, %Error{code: :invalid_request}} =
               in_transaction(fn ->
                 Boundary.append_if(BoundaryResource, {:tag, "cart:17"}, 0, [], tenant: tenant)
               end)

      assert {:error, %Error{code: :invalid_request}} =
               in_transaction(fn ->
                 Boundary.append_if(
                   BoundaryResource,
                   {:tag, "cart:17"},
                   0,
                   [
                     %{type: "hold", tags: Enum.map(1..17, &"tag#{&1}")}
                   ],
                   tenant: tenant
                 )
               end)

      assert {:error, %Error{code: :invalid_request}} =
               in_transaction(fn ->
                 Boundary.append_if(
                   BoundaryResource,
                   {:tag, "cart:17"},
                   0,
                   [
                     %{type: "hold", tags: ["bad" <> <<0>>]}
                   ],
                   tenant: tenant
                 )
               end)
    end

    test "refuses a negative cutoff and an unknown option", %{tenant: tenant} do
      assert {:error, %Error{code: :invalid_request}} =
               in_transaction(fn ->
                 Boundary.append_if(
                   BoundaryResource,
                   {:tag, "cart:18"},
                   -1,
                   [
                     %{type: "h", tags: ["cart:18"]}
                   ],
                   tenant: tenant
                 )
               end)

      assert {:error, %Error{code: :invalid_request}} =
               in_transaction(fn ->
                 Boundary.append_if(
                   BoundaryResource,
                   {:tag, "cart:18"},
                   0,
                   [
                     %{type: "h", tags: ["cart:18"]}
                   ],
                   tenant: tenant,
                   unexpected: :option
                 )
               end)
    end

    test "refuses a query whose facts would take more lock tags than the ceiling allows", %{
      tenant: tenant
    } do
      facts =
        Enum.map(1..9, fn i -> %{type: "hold", tags: Enum.map(1..15, &"lock:#{i}:#{&1}")} end)

      assert {:error, %Error{code: :invalid_request}} =
               in_transaction(fn ->
                 Boundary.append_if(BoundaryResource, {:tag, "cart:19"}, 0, facts, tenant: tenant)
               end)
    end
  end

  describe "lock order seam" do
    test "the advisory lock set is sorted and deduplicated" do
      assert Boundary.sorted_lock_tags(["b", "a", "c", "a", "b"]) == ["a", "b", "c"]
    end
  end

  describe "Ash change surface" do
    test "a create action appends facts through the boundary and records admitted seqs", %{
      tenant: tenant
    } do
      assert {:ok, record} =
               Ash.Changeset.for_create(BoundaryResource, :record, %{
                 context_tag: "cart:20",
                 amount: 500,
                 context_cutoff: 0,
                 context_facts: [%{type: "record", tags: ["cart:20"]}],
                 context_tenant: tenant
               })
               |> Ash.create()

      assert record.context_tag == "cart:20"

      assert {:ok, %{facts: [fact]}} =
               Boundary.read(BoundaryResource, {:tag, "cart:20"}, tenant: tenant)

      assert fact.type == "record"

      assert record.__metadata__[:ash_onetime_boundary] == %{seqs: [fact.seq]}
    end

    test "a changed context fails the action with a typed context_changed error", %{
      tenant: tenant
    } do
      assert {:ok, _} =
               Ash.Changeset.for_create(BoundaryResource, :record, %{
                 context_tag: "cart:21",
                 amount: 100,
                 context_cutoff: 0,
                 context_facts: [%{type: "record", tags: ["cart:21"]}],
                 context_tenant: tenant
               })
               |> Ash.create()

      assert {:error, error} =
               Ash.Changeset.for_create(BoundaryResource, :record, %{
                 context_tag: "cart:21",
                 amount: 100,
                 context_cutoff: 0,
                 context_facts: [%{type: "record", tags: ["cart:21"]}],
                 context_tenant: tenant
               })
               |> Ash.create()

      assert Error.code(error) == :context_changed
    end
  end
end
