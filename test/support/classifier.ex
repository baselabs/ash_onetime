defmodule AshOnetime.Test.StoreClassifier do
  @moduledoc false
  def classify(value, _context), do: {:store, value}
end

defmodule AshOnetime.Test.RejectClassifier do
  @moduledoc false
  def classify(value, _context), do: {:reject, value}
end

defmodule AshOnetime.Test.RollbackClassifier do
  @moduledoc false
  def classify(value, _context), do: {:rollback, value}
end

defmodule AshOnetime.Test.InvalidClassifier do
  @moduledoc false
  def classify(_value, _context), do: :invalid
end

defmodule AshOnetime.Test.RaisingClassifier do
  @moduledoc false
  def classify(_value, _context), do: raise("classified value must not leak")
end

defmodule AshOnetime.Test.FixedEmptyCodec do
  @moduledoc false
  def format_tag, do: "fixed-empty"

  def encode(value, _contract, opts) do
    if value == Keyword.fetch!(opts, :value), do: {:ok, format_tag(), <<>>}, else: :error
  end

  def decode("fixed-empty", <<>>, _contract, opts), do: {:ok, Keyword.fetch!(opts, :value)}
  def decode(_tag, _payload, _contract, _opts), do: :error
end

defmodule AshOnetime.Test.LongTagCodec do
  @moduledoc false
  @tag String.duplicate("a", 81)
  def format_tag, do: @tag
  def encode(value, _contract, _opts), do: {:ok, format_tag(), :erlang.term_to_binary(value)}
  def decode(@tag, payload, _contract, _opts), do: {:ok, :erlang.binary_to_term(payload, [:safe])}
end

defmodule AshOnetime.Test.ObservingCodec do
  @moduledoc false
  def format_tag, do: "observing"

  def encode(value, _contract, opts) do
    send(Keyword.fetch!(opts, :observer), {:codec_received, value})
    {:ok, format_tag(), :erlang.term_to_binary(value)}
  end

  def decode("observing", payload, _contract, _opts),
    do: {:ok, :erlang.binary_to_term(payload, [:safe])}
end

defmodule AshOnetime.Test.FixedDecodeCodec do
  @moduledoc false
  def format_tag, do: "fixed-decode"
  def encode(_value, _contract, _opts), do: {:ok, format_tag(), <<>>}
  def decode("fixed-decode", <<>>, _contract, opts), do: {:ok, Keyword.fetch!(opts, :decoded)}
end
