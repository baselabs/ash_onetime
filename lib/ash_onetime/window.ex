defmodule AshOnetime.Window do
  @moduledoc """
  Inclusive replay and expiry window validation.
  """

  @max_duration_seconds 2_147_483_647

  @spec validate(
          DateTime.t(),
          DateTime.t() | nil,
          DateTime.t(),
          non_neg_integer(),
          non_neg_integer()
        ) :: :ok | {:error, :invalid}
  def validate(
        %DateTime{} = issued_at,
        expires_at,
        %DateTime{} = evaluated_at,
        max_age,
        skew
      ) do
    if valid_inputs?(issued_at, expires_at, evaluated_at, max_age, skew) do
      validate_interval(issued_at, expires_at, evaluated_at, max_age, skew)
    else
      {:error, :invalid}
    end
  rescue
    _exception -> {:error, :invalid}
  catch
    _kind, _reason -> {:error, :invalid}
  end

  def validate(_issued_at, _expires_at, _evaluated_at, _max_age, _skew),
    do: {:error, :invalid}

  @spec cleanup_after(DateTime.t(), non_neg_integer(), non_neg_integer()) ::
          DateTime.t() | {:error, :invalid}
  def cleanup_after(%DateTime{} = issued_at, max_age, skew) do
    if valid_datetime?(issued_at) and valid_durations?(max_age, skew) do
      issued_at
      |> DateTime.add(max_age + skew, :second)
      |> DateTime.add(1, :microsecond)
    else
      {:error, :invalid}
    end
  rescue
    _exception -> {:error, :invalid}
  catch
    _kind, _reason -> {:error, :invalid}
  end

  def cleanup_after(_issued_at, _max_age, _skew), do: {:error, :invalid}

  defp valid_inputs?(issued_at, expires_at, evaluated_at, max_age, skew) do
    valid_datetime?(issued_at) and valid_optional_datetime?(expires_at) and
      valid_datetime?(evaluated_at) and valid_durations?(max_age, skew)
  end

  defp valid_durations?(max_age, skew) do
    is_integer(max_age) and max_age >= 0 and max_age <= @max_duration_seconds and
      is_integer(skew) and skew >= 0 and skew <= @max_duration_seconds and
      max_age + skew <= @max_duration_seconds
  end

  defp validate_interval(issued_at, expires_at, evaluated_at, max_age, skew) do
    oldest = DateTime.add(evaluated_at, -(max_age + skew), :second)
    newest = DateTime.add(evaluated_at, skew, :second)

    valid_issuance? =
      DateTime.compare(issued_at, oldest) in [:eq, :gt] and
        DateTime.compare(issued_at, newest) in [:eq, :lt]

    if valid_issuance? and valid_expiry?(issued_at, expires_at, evaluated_at, skew) do
      :ok
    else
      {:error, :invalid}
    end
  end

  defp valid_expiry?(_issued_at, nil, _evaluated_at, _skew), do: true

  defp valid_expiry?(issued_at, %DateTime{} = expires_at, evaluated_at, skew) do
    expiry_horizon = DateTime.add(expires_at, skew, :second)

    DateTime.compare(expires_at, issued_at) in [:eq, :gt] and
      DateTime.compare(evaluated_at, expiry_horizon) in [:eq, :lt]
  end

  defp valid_expiry?(_issued_at, _expires_at, _evaluated_at, _skew), do: false

  defp valid_optional_datetime?(nil), do: true
  defp valid_optional_datetime?(datetime), do: valid_datetime?(datetime)

  defp valid_datetime?(%DateTime{} = datetime) do
    DateTime.to_unix(datetime, :microsecond)
    true
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp valid_datetime?(_datetime), do: false
end
