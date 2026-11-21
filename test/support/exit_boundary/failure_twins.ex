defmodule AshOnetime.Test.ExitBoundary.FailureTwins do
  alias AshOnetime.Test.ExitBoundary.Hooks
  alias AshOnetime.Test.ExitBoundary.References
  alias AshOnetime.Test.ExitBoundary.Returned
  @moduledoc false

  # The twin faults at the same entry as the selected library hook. Calling the
  # real installed hook first on a producer failure preserves real admission.
  def install(subject, row, error) do
    if subject.resource == Returned and row.branch in [:direct, :producer_failure] do
      slot = slot(row)
      original = subject |> Map.fetch!(elem(slot, 0)) |> Enum.fetch!(elem(slot, 1))
      hook = build(row.type, row.branch, original, error)
      Map.update!(subject, elem(slot, 0), &List.replace_at(&1, elem(slot, 1), hook))
    else
      subject
    end
  end

  def side_frames(hooks, canonical, row, resource) do
    frames = Hooks.frames(hooks, canonical)

    if resource == AshOnetime.Test.ExitBoundary.Returned and
         row.branch in [:direct, :producer_failure] do
      Map.put(frames, trace_mfa(template(row)), Hooks.trace_mfa(canonical[slot(row)]))
    else
      frames
    end
  end

  def error(:direct),
    do:
      AshOnetime.Error.new(
        :executing_only_requires_call,
        "an action with executing-only values runs only through AshOnetime.deliver/2"
      )

  def error(:producer_failure),
    do:
      AshOnetime.Error.new(
        :executing_only_invalid,
        "executing-only values could not be produced"
      )

  def build(:action, :direct, _original, error) do
    fn _pending -> {:error, error} end
  end

  def build(:action, :producer_failure, original, error) do
    fn pending ->
      case original.(pending) do
        %Ash.ActionInput{} -> {:error, error}
        other -> other
      end
    end
  end

  def build(_crud, :direct, _original, error) do
    fn _pending, _callback -> {:error, error} end
  end

  def build(_crud, :producer_failure, original, error) do
    fn pending, _callback -> original.(pending, failure_callback(error)) end
  end

  def failure_callback(error), do: fn _pending -> {:error, error} end

  def slot(%{type: :action}), do: {:before_action, 0}
  def slot(_), do: {:around_action, 0}

  def selected?(side),
    do: side.resource == Returned and side.row.branch in [:direct, :producer_failure]

  def template(row),
    do:
      build(
        row.type,
        row.branch,
        if(row.type == :action, do: fn _ -> :sentinel end, else: fn _, _ -> :sentinel end),
        error(row.branch)
      )

  def trace_mfa(fun) do
    info = Map.new(Function.info(fun))
    {info.module, info.name, info.arity + length(info.env)}
  end

  def identity(fun) do
    info = Map.new(Function.info(fun))
    {info.module, info.name, info.arity, info.new_uniq, info.index}
  end

  def frames do
    References.memo(:failure_twin_frames, fn ->
      for(
        type <- [:create, :action],
        branch <- [:direct, :producer_failure],
        do: trace_mfa(template(%{type: type, branch: branch}))
      ) ++ [trace_mfa(failure_callback(:sentinel))]
    end)
  end

  def fault_frame?(mfa), do: mfa in frames()

  def environment(row, original) do
    template = template(row)

    template_original =
      if row.type == :action, do: fn _ -> :sentinel end, else: fn _, _ -> :sentinel end

    # A distinguishable constructor call identifies the captured hook source.
    info =
      Map.new(Function.info(build(row.type, row.branch, template_original, error(row.branch))))

    Enum.map(info.env, fn value ->
      cond do
        value === template_original -> original
        value === error(row.branch) -> error(row.branch)
        true -> raise "undeclared failure twin environment: #{inspect(identity(template))}"
      end
    end)
  end

  def validate(fun, side) when is_function(fun) do
    row = side.row
    info = Map.new(Function.info(fun))
    reference = template(row)
    env = Map.new(Function.info(reference)).env
    actual_env = info.env

    if identity(fun) != identity(reference) or length(actual_env) != length(env) do
      {:error, :failure_twin_code, identity(reference), identity(fun)}
    else
      original = Enum.find(actual_env, &is_function/1)
      expected = environment(row, original)

      cond do
        actual_env !== expected -> {:error, :failure_twin_environment, expected, actual_env}
        original != nil -> Hooks.validate_library(original, slot(row), side)
        true -> :ok
      end
    end
  end

  def validate(value, _side), do: {:error, :failure_twin_code, :function, value}
end
