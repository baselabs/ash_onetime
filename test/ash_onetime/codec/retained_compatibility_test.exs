defmodule AshOnetime.Codec.RetainedCompatibilityTest do
  use AshOnetime.Test.StoreCase, async: false

  alias AshOnetime.Response
  alias AshOnetime.Test.{FixedEmptyCodec, StoreClassifier}
  alias AshOnetime.Test.ResultExamples.Account

  # Computed on the box by evaluating the Response source from
  # `git show 83bd402:lib/ash_onetime/response.ex` under a separate test module name.
  # These cover every pre-existing result mode, including nullable and constrained types.
  @contracts [
    {:create_account, [:id, :name], %{}, "1a3e2a91ee69f0958db3f105f1a2271a823eb7e0d156df265d0ae0bfb72f2b80"},
    {:update_account, [:id, :name], %{}, "1edaee3896141f3c30b22c3d208ff699ed8ace2d265a8d257cf2270c99139f1c"},
    {:destroy_account, [], %{}, "72089551e77f839a6a8c09a2af0577c4de8a48600569346c0c42aaa3ff235533"},
    {:destroy_account, [:id, :name], %{return_destroyed?: true}, "35f9542037e76190ad0ab00a6611f5c40f6ada808c66864fe5b60a28350e45ad"},
    {:nothing, [], %{}, "5f32a831e080a9d1fb670bf4948a8fe76e4b1c5f0cd4b955295a272537e9a686"},
    {:decimal_result, [], %{}, "6f412ad352d5a73ccb4017cddb17093dec5485f234353e027d319f02a0effee7"},
    {:uuid_result, [], %{}, "9ae067b18f31b73e087c0401cc2778140baca710850f920396301a195502cfa7"},
    {:datetime_result, [], %{}, "5693d59c0c18d99017569eecf23151af4bd1bb08aeed74835cd6a63292a4fd33"},
    {:array_result, [], %{}, "e028c042561123b91005478bbc2b41ba034e101f5ddb5549028fa4f730940da5"},
    {:map_result, [], %{}, "c0dda059334217a1dcee617dccfa5c3a14c12183c2999b05a06c40fbcb11e4ca"},
    {:nullable_result, [], %{}, "d15f5b9d77f36715968e14d705ef479067f2e216f20e0248597353537b08f967"}
  ]

  setup_all do
    installation = install_store!()
    {:ok, prefix: installation.schema}
  end

  for {action, fields, trusted, digest} <- @contracts do
    @action action
    @fields fields
    @trusted trusted
    @digest digest
    test "retains the old descriptor digest for #{action}, #{inspect(fields)}, #{inspect(trusted)}" do
      response = %AshOnetime.Resource.Response{
        codec: AshOnetime.Codec.Resource, fields: @fields, classify: StoreClassifier}
      assert {:ok, contract} = Response.contract(Account, @action, response, @trusted)
      assert Base.encode16(contract.digest, case: :lower) == @digest
    end
  end

  test "a response stored with the old binding replays from real PostgreSQL", %{target: target} do
    # Exact codec binding and bytes produced by the old Response.encode/3 on the box.
    binding = "ao:fixed-empty:qOrwDE5KM8cy6ap184HN_WWByO6f3n_UOFGOz-ik3Sc"
    payload = <<>>
    digest = Base.decode16!("E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855")
    request = idempotency_request("retained-old-descriptor")
    response = %AshOnetime.Resource.Response{codec: FixedEmptyCodec,
      fields: [], classify: StoreClassifier, codec_opts: [value: "fixed"]}
    assert {:ok, contract} = Response.contract(Account, :nullable_result, response, %{})

    assert {:ok, %Result{status: :complete}} = Repo.transaction(fn ->
      admitted = Store.claim(target, request)
      Store.complete(target, admitted.claim, binding, digest, payload)
    end)
    assert {:ok, %Result{status: :complete} = retained} =
      Repo.transaction(fn -> Store.claim(target, request) end)
    assert {:ok, "fixed"} = Response.replay(retained, contract, [])
  end
end
