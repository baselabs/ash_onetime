defmodule AshOnetime.Test.ExitBoundary.Compiled do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.References

  # Keep the installed BEAM and its debug readers on the same source revision
  # while a hosted test exercises a guarded production edit.
  def with_source(source, path, callback) do
    previous = Code.compiler_options(ignore_module_conflict: true, debug_info: true)

    [_, name] = Regex.run(~r/^defmodule ([A-Za-z0-9_.]+) do$/m, source)
    directory = name |> then(&Module.concat([&1])) |> :code.which() |> Path.dirname()

    # Include modules emitted by defimpl/derive, using the compiled source
    # metadata rather than guessing generated module names from the text.
    modules =
      for beam <- Path.wildcard(Path.join(directory, "*.beam")),
          {:ok, {module, chunks}} = :beam_lib.chunks(String.to_charlist(beam), [:compile_info]),
          original_source = chunks[:compile_info][:source],
          original_source != nil,
          Path.expand(List.to_string(original_source)) == Path.expand(path) do
        {module, String.to_charlist(beam), File.read!(beam)}
      end

    try do
      for {module, binary} <- Code.compile_string(source, path) do
        {^module, beam, _original} = List.keyfind(modules, module, 0)
        File.write!(beam, binary)
        {:module, ^module} = :code.load_binary(module, beam, binary)
      end

      callback.()
    after
      try do
        for {module, beam, binary} <- modules do
          File.write!(beam, binary)
          {:module, ^module} = :code.load_binary(module, beam, binary)
          unless File.read!(beam) === binary, do: raise("BEAM restoration failed")
        end
      after
        Code.compiler_options(previous)
      end
    end
  end

  def identity(module, name, arity) do
    References.memo({:compiled_fun, module, module.module_info(:md5), name, arity}, fn ->
      {:ok, {^module, chunks}} = :beam_lib.chunks(:code.which(module), [:atoms, ~c"FunT"])
      atoms = Map.new(chunks[:atoms])
      <<_count::32, entries::binary>> = elem(List.keyfind(chunks, ~c"FunT", 0), 1)

      entries =
        for <<atom::32, total::32, _label::32, index::32, free::32, _uniq::32 <- entries>>,
          do: {Map.fetch!(atoms, atom), total - free, index}

      {^name, ^arity, index} = Enum.find(entries, &match?({^name, ^arity, _}, &1))
      {module, name, arity, module.module_info(:md5), index}
    end)
  end

  # Read which free register supplies a callee argument. This identifies a
  # closure slot by its compiled call, without guessing a fun number or reading
  # the checked environment to decide where its date belongs.
  def captured_argument(module, function, callee, arity, argument) do
    References.memo(
      {:captured_argument, module, module.module_info(:md5), function, callee, arity, argument},
      fn ->
        {:beam_file, _, _, _, _, functions} = :beam_disasm.file(:code.which(module))

        {:function, ^function, count, _, instructions} =
          Enum.find(functions, &match?({:function, ^function, _, _, _}, &1))

        target = {module, callee, arity}

        calls? =
          Enum.any?(instructions, fn
            {tag, ^arity, ^target} when tag in [:call, :call_only] -> true
            {:call_last, ^arity, ^target, _} -> true
            _ -> false
          end)

        if calls? do
          registers = Map.new(0..(count - 1), &{{:x, &1}, {:environment, &1}})

          labels =
            instructions
            |> Enum.with_index()
            |> Enum.flat_map(fn
              {{:label, label}, index} -> [{label, Enum.drop(instructions, index + 1)}]
              _ -> []
            end)
            |> Map.new()

          captured =
            try do
              capture_path(instructions, registers, labels, target, argument, MapSet.new())
            rescue
              error ->
                IO.inspect(
                  %{
                    function: {module, function, count},
                    callee: target,
                    code: Enum.map(instructions, &AshOnetime.Test.ExitBoundary.Diagnostics.safe/1)
                  },
                  label: "COMPILED_CAPTURE_FAILURE",
                  limit: :infinity
                )

                reraise error, __STACKTRACE__
            end

          case captured do
            {:environment, index} ->
              {:ok, index}

            other ->
              raise "callee argument is not a captured origin: #{inspect({target, argument, other})}"
          end
        else
          :not_called
        end
      end
    )
  end

  defp capture_path([instruction | rest], regs, labels, {_, _, arity} = target, argument, seen) do
    case instruction do
      {tag, ^arity, ^target} when tag in [:call, :call_only] ->
        Map.fetch!(regs, {:x, argument})

      {:call_last, ^arity, ^target, _} ->
        Map.fetch!(regs, {:x, argument})

      {:jump, {:f, label}} ->
        if MapSet.member?(seen, label), do: raise("cyclic captured-origin control flow")

        capture_path(
          Map.fetch!(labels, label),
          regs,
          labels,
          target,
          argument,
          MapSet.put(seen, label)
        )

      _ ->
        capture_path(rest, capture_step(instruction, regs), labels, target, argument, seen)
    end
  end

  defp capture_path([], _, _, target, _, _),
    do: raise("captured-origin callee not reached: #{inspect(target)}")

  defp capture_step({:move, from, to}, regs),
    do: Map.put(regs, register(to), Map.get(regs, register(from), :not_environment))

  defp capture_step({:swap, a, b}, regs) do
    a = register(a)
    b = register(b)
    regs |> Map.put(a, Map.fetch!(regs, b)) |> Map.put(b, Map.fetch!(regs, a))
  end

  defp capture_step({:get_map_elements, _, _, {:list, destinations}}, regs) do
    for [_key, to] <- Enum.chunk_every(destinations, 2), reduce: regs do
      acc -> Map.put(acc, register(to), :not_environment)
    end
  end

  defp capture_step({:bif, _, _, _, to}, regs),
    do: Map.put(regs, register(to), :not_environment)

  defp capture_step({:gc_bif, _, _, _, _, to}, regs),
    do: Map.put(regs, register(to), :not_environment)

  defp capture_step({:get_tuple_element, _, _, to}, regs),
    do: Map.put(regs, register(to), :not_environment)

  defp capture_step({:init, to}, regs),
    do: Map.put(regs, register(to), :not_environment)

  defp capture_step({:init_yregs, {:list, destinations}}, regs),
    do: Enum.reduce(destinations, regs, &Map.put(&2, register(&1), :not_environment))

  # A native call clobbers X registers; only saved Y registers survive it.
  defp capture_step({tag, _, _}, regs) when tag in [:call, :call_ext],
    do:
      regs
      |> Map.reject(fn {{kind, _}, _} -> kind == :x end)
      |> Map.put({:x, 0}, :not_environment)

  defp capture_step({tag, _}, regs) when tag in [:line, :label, :deallocate], do: regs
  defp capture_step({:func_info, _, _, _}, regs), do: regs
  defp capture_step({:test, _, _, _}, regs), do: regs
  defp capture_step({:test, :has_map_fields, _, _, _}, regs), do: regs

  defp capture_step({tag, _, _}, regs) when tag in [:allocate, :allocate_zero, :test_heap],
    do: regs

  defp capture_step({tag, _, _, _}, regs) when tag in [:allocate_heap, :allocate_heap_zero],
    do: regs

  defp capture_step(instruction, _),
    do: raise("undeclared captured-origin instruction: #{inspect(instruction)}")

  defp register({:tr, register, _type}), do: register(register)
  defp register(register), do: register

  # Symbolically execute the compiled closure's register permutation. The source
  # values are the declared callee arguments, never the checked fun's environment.
  def closure_environment(module, function, arity, callee, inputs) do
    permutation =
      References.memo(
        {:compiled_environment, module, module.module_info(:md5), function, arity, callee},
        fn ->
          {:beam_file, _, _, _, _, functions} = :beam_disasm.file(:code.which(module))
          name = String.to_existing_atom("-#{function}/#{arity}-fun-0-")

          {:function, ^name, count, _, instructions} =
            Enum.find(functions, &match?({:function, ^name, _, _, _}, &1))

          registers = Map.new(0..(count - 1), &{{:x, &1}, &1})

          registers =
            Enum.reduce_while(instructions, registers, fn
              {:swap, a, b}, regs ->
                {:cont,
                 regs |> Map.put(a, Map.fetch!(regs, b)) |> Map.put(b, Map.fetch!(regs, a))}

              {:move, from, to}, regs ->
                {:cont, Map.put(regs, to, Map.fetch!(regs, from))}

              {:call_only, ^count, {^module, ^callee, ^count}}, regs ->
                {:halt, regs}

              {tag, _}, regs when tag in [:line, :label] ->
                {:cont, regs}

              {:func_info, _, _, _}, regs ->
                {:cont, regs}

              instruction, _ ->
                raise "undeclared closure instruction: #{inspect(instruction)}"
            end)

          for n <- 0..(count - 1), do: Map.fetch!(registers, {:x, n})
        end
      )

    permutation |> Enum.zip(inputs) |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
  end
end
