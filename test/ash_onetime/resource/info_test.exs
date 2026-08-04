defmodule AshOnetime.Resource.InfoTest do
  use ExUnit.Case, async: true

  alias AshOnetime.Resource.Info
  alias AshOnetime.Test.Support.Resource
  alias Spark.Dsl.Extension

  test "reads the normalized persisted index" do
    assert Info.protected?(Resource, :charge)
    assert Info.strategy(Resource, :charge) == :idempotency
    assert Info.strategy(Resource, :redeem) == :one_time_nonce
    refute Info.protected?(Resource, :missing)
    assert Info.protection(Resource, :missing) == nil

    raw = Extension.get_entities(Resource, [:onetime])
    raw_charge = Enum.find(raw, &(&1.action == :charge))

    assert raw_charge.retention == {24, :hour}
    assert Info.protection(Resource, :charge).retention == 86_400
  end
end
