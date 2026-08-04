defmodule AshOnetime.MutationCheck do
  @moduledoc false

  @registered MapSet.new()

  def main(["--self-test"]) do
    case validate(["unregistered-mutation"]) do
      {:error, ["unregistered-mutation"]} ->
        IO.puts("mutation checker self-test: unknown mutations fail closed")

      result ->
        IO.puts(:stderr, "mutation checker self-test failed: #{inspect(result)}")
        System.halt(1)
    end
  end

  def main(names) do
    case validate(names) do
      :ok ->
        IO.puts("mutation checks passed: #{Enum.join(names, ", ")}")

      {:error, unknown} ->
        IO.puts(:stderr, "unknown mutation checks: #{Enum.join(unknown, ", ")}")
        System.halt(2)
    end
  end

  defp validate([]), do: {:error, ["no mutation checks requested"]}

  defp validate(names) do
    unknown = Enum.reject(names, &MapSet.member?(@registered, &1))
    if unknown == [], do: :ok, else: {:error, unknown}
  end
end

AshOnetime.MutationCheck.main(System.argv())
