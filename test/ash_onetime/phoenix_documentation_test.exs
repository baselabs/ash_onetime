defmodule AshOnetime.PhoenixDocumentationTest do
  use ExUnit.Case, async: false

  alias AshOnetime.Error

  @phoenix_guide "documentation/phoenix.md"
  @errors_guide "documentation/errors.md"

  test "the shared guide helper maps every documented code and sanitizes wrapped errors" do
    helper = compile_guide_helper!()
    documented = documented_statuses!()

    # Known-positive rows prove the table parser sees each status family before its
    # complete output is used to check the guide helper.
    assert documented[:verification_failed] == [401]
    assert documented[:request_in_progress] == [409, 425]
    assert documented[:verification_timeout] == [503]
    assert documented[:store_invariant] == [500]
    assert documented[:checkout_unavailable] == [503]

    for {code, allowed_http_statuses} <- documented do
      actual = helper.status(code) |> status_number!()

      assert actual in allowed_http_statuses,
             "#{inspect(code)} maps to #{actual}, expected one of #{inspect(allowed_http_statuses)}"

      assert helper.public_code(code) == Atom.to_string(code)
    end

    assert helper.status(:request_in_progress) == :conflict
    assert helper.status(:verification_timeout) == :service_unavailable
    assert helper.status(:unknown_code) == :internal_server_error
    assert helper.public_code(:unknown_code) == "internal_error"

    leaf =
      Error.new(
        :key_resolution_failed,
        "provider returned a classified reason",
        %{reason: "classified-provider-reason"}
      )

    wrapped = Ash.Error.to_ash_error([leaf, Error.new(:nonce_already_used, "other")])
    code = Error.code(wrapped)

    response = %{
      status: helper.status(code),
      body: %{errors: %{code: helper.public_code(code)}}
    }

    assert response == %{
             status: :unprocessable_entity,
             body: %{errors: %{code: "key_resolution_failed"}}
           }

    rendered = inspect(response)
    refute rendered =~ "classified-provider-reason"
    refute rendered =~ "provider returned a classified reason"
  end

  defp compile_guide_helper! do
    source = File.read!(@phoenix_guide)

    case Regex.run(
           ~r/<!-- onetime-errors-helper:start -->\s*```elixir\s*(.*?)\s*```\s*<!-- onetime-errors-helper:end -->/s,
           source,
           capture: :all_but_first
         ) do
      [helper_source] ->
        [{module, _bytecode}] = Code.compile_string(helper_source, @phoenix_guide)
        module

      nil ->
        flunk("#{@phoenix_guide} must contain the marked shared error helper")
    end
  end

  defp documented_statuses! do
    source = File.read!(@errors_guide)
    table_rows = Regex.scan(~r/^\| `:([a-z0-9_]+)` \| ([^|]+) \|/m, source)

    rows =
      table_rows
      |> Map.new(fn [_row, code, statuses] ->
        numbers =
          statuses
          |> then(&Regex.scan(~r/\d{3}/, &1))
          |> List.flatten()
          |> Enum.map(&String.to_integer/1)

        {String.to_atom(code), numbers}
      end)

    assert map_size(rows) > 0, "known-positive Error-table parser returned no rows"
    assert map_size(rows) == length(table_rows), "Error tables contain duplicate code rows"
    rows
  end

  defp status_number!(:unauthorized), do: 401
  defp status_number!(:not_found), do: 404
  defp status_number!(:conflict), do: 409
  defp status_number!(:unprocessable_entity), do: 422
  defp status_number!(:internal_server_error), do: 500
  defp status_number!(:service_unavailable), do: 503
end
