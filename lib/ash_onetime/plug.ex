if Code.ensure_loaded?(Plug.Conn) do
  defmodule AshOnetime.Plug do
    @moduledoc """
    Copies configured request headers into `conn.private.ash_onetime.untrusted`.

    Values remain raw and untrusted. Verification and construction of trusted nonce facts happen
    only inside the protected action.
    """

    @behaviour Plug

    @max_headers 16
    @max_header_name_bytes 128
    @max_value_bytes 65_536
    @header_name ~r/^[a-z0-9!#$%&'*+.^_`|~-]+$/

    @impl Plug
    def init(options) when is_list(options) do
      headers = Keyword.get(options, :headers, [])
      max_value_bytes = Keyword.get(options, :max_value_bytes, 4_096)

      if valid_headers?(headers) and valid_max_value_bytes?(max_value_bytes) do
        %{headers: headers, max_value_bytes: max_value_bytes}
      else
        raise ArgumentError, "invalid AshOnetime.Plug configuration"
      end
    end

    def init(_options), do: raise(ArgumentError, "invalid AshOnetime.Plug configuration")

    @impl Plug
    def call(%Plug.Conn{} = conn, %{headers: headers, max_value_bytes: max_value_bytes}) do
      untrusted =
        Enum.reduce(headers, %{}, fn {context_name, header_name}, values ->
          case read_header(conn, header_name, max_value_bytes) do
            :missing ->
              values

            {:ok, value} ->
              Map.put(values, context_name, value)

            :invalid ->
              bad_request!()
          end
        end)

      Plug.Conn.put_private(conn, :ash_onetime, %{untrusted: untrusted})
    end

    def call(_conn, _options), do: bad_request!()

    defp valid_headers?(headers) do
      is_list(headers) and headers != [] and Keyword.keyword?(headers) and
        length(headers) <= @max_headers and
        length(Keyword.keys(headers)) == length(Enum.uniq(Keyword.keys(headers))) and
        length(Keyword.values(headers)) == length(Enum.uniq(Keyword.values(headers))) and
        Enum.all?(headers, fn
          {name, header} when is_atom(name) and is_binary(header) ->
            byte_size(header) in 1..@max_header_name_bytes and Regex.match?(@header_name, header)

          _invalid ->
            false
        end)
    end

    defp valid_max_value_bytes?(value),
      do: is_integer(value) and value >= 1 and value <= @max_value_bytes

    defp read_header(conn, header_name, max_value_bytes) do
      case Plug.Conn.get_req_header(conn, header_name) do
        [] -> :missing
        [value] -> validate_value(value, max_value_bytes)
        _duplicates -> :invalid
      end
    end

    defp validate_value(value, max_value_bytes) do
      if valid_value?(value, max_value_bytes), do: {:ok, value}, else: :invalid
    end

    defp valid_value?(value, max_value_bytes) do
      byte_size(value) in 1..max_value_bytes and
        Enum.all?(:binary.bin_to_list(value), &(&1 >= 0x20 and &1 != 0x7F))
    end

    defp bad_request!, do: raise(Plug.BadRequestError, message: "invalid keyed-effect header")
  end
end
