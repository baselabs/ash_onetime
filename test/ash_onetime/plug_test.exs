defmodule AshOnetime.PlugTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias AshOnetime.Plug, as: OnetimePlug
  alias AshOnetime.Verified

  @options OnetimePlug.init(
             headers: [request_key: "idempotency-key", proof: "x-onetime-proof"],
             max_value_bytes: 32
           )

  test "configured headers become only bounded namespaced untrusted private context" do
    conn =
      conn(:post, "/")
      |> put_req_header("idempotency-key", "request-1")
      |> put_req_header("x-onetime-proof", "raw-proof")

    result = OnetimePlug.call(conn, @options)

    assert result.assigns == conn.assigns
    assert Map.keys(result.private) == [:ash_onetime]

    assert result.private.ash_onetime == %{
             untrusted: %{request_key: "request-1", proof: "raw-proof"}
           }

    refute contains_verified?(result.private)
  end

  test "missing configured headers are omitted" do
    assert %{private: %{ash_onetime: %{untrusted: %{}}}} =
             conn(:get, "/") |> OnetimePlug.call(@options)
  end

  test "duplicate, empty, oversized, and control-byte values are rejected" do
    duplicate = %{
      conn(:get, "/")
      | req_headers: [{"idempotency-key", "one"}, {"idempotency-key", "two"}]
    }

    assert_raise Plug.BadRequestError, fn -> OnetimePlug.call(duplicate, @options) end

    empty = conn(:get, "/") |> put_req_header("idempotency-key", "")
    assert_raise Plug.BadRequestError, fn -> OnetimePlug.call(empty, @options) end

    oversized = conn(:get, "/") |> put_req_header("idempotency-key", String.duplicate("a", 33))
    assert_raise Plug.BadRequestError, fn -> OnetimePlug.call(oversized, @options) end

    control = %{conn(:get, "/") | req_headers: [{"idempotency-key", "bad\a"}]}
    assert :binary.match("bad\a", <<7>>) != :nomatch
    assert_raise Plug.BadRequestError, fn -> OnetimePlug.call(control, @options) end
  end

  test "configuration is bounded and header names must be lowercase HTTP tokens" do
    assert_raise ArgumentError, fn -> OnetimePlug.init(headers: []) end

    assert_raise ArgumentError, fn ->
      OnetimePlug.init(headers: [request_key: "Upper-Case"])
    end

    assert_raise ArgumentError, fn ->
      OnetimePlug.init(headers: Enum.map(1..17, &{String.to_atom("field_#{&1}"), "x-#{&1}"}))
    end
  end

  defp contains_verified?(%Verified{}), do: true
  defp contains_verified?(map) when is_map(map), do: Enum.any?(map, &contains_verified?/1)

  defp contains_verified?({left, right}),
    do: contains_verified?(left) or contains_verified?(right)

  defp contains_verified?(list) when is_list(list), do: Enum.any?(list, &contains_verified?/1)
  defp contains_verified?(_term), do: false
end
