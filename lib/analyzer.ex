defmodule Cracker.Analyzer do
  @moduledoc """
  Handles the analysis of function calls and module definitions.
  """

  alias Cracker.Cache

  def analyze_function({module_name, function_name, arity} = mfa, state) do
    function_key = "#{module_name}.#{function_name}/#{arity}"

    if MapSet.member?(state.visited, function_key) do
      state
    else
      state = %{state | visited: MapSet.put(state.visited, function_key)}

      case Cache.get_or_find_source_file(module_name, state) do
        nil ->
          state

        path ->
          {module_definitions, ast} = Cache.get_or_extract_module_definitions(path, module_name, state)

          {calls, updated_state} =
            extract_function_calls(ast, function_name, arity, module_name, module_definitions, state)

          project_calls = filter_project_calls(calls, state)
          state = add_edges(updated_state, mfa, project_calls)

          project_calls
          |> Enum.reject(fn {mod, _, _} -> String.starts_with?(to_string(mod), "Dynamic.") end)
          |> Enum.reduce(state, fn call, acc ->
            analyze_function(call, acc)
          end)
      end
    end
  end

  defp extract_function_calls(ast, target_function, target_arity, current_module, module_definitions, state) do
    initial_state = %{
      target_function: target_function,
      target_arity: target_arity,
      in_target_function: false,
      completed_traversing: false,
      # Map to store alias definitions
      aliases: %{},
      # Current module being analyzed
      current_module: current_module,
      calls: [],
      module_definitions: module_definitions,
      line: state.line
    }

    final_state =
      try do
        {_, final_state} = Macro.traverse(ast, initial_state, &pre_traverse/2, &post_traverse/2)
        final_state
      catch
        {_, final_state} ->
          final_state
      end

    {Enum.reverse(final_state.calls), %{state | module_definitions: final_state.module_definitions, line: nil}}
  end

  defp pre_traverse(_node, %{completed_traversing: true} = state) do
    throw({:completed, state})
  end

  defp pre_traverse({:alias, _, [{:__aliases__, _, module_parts}, [as: {:__aliases__, _, [alias_as]}]]} = node, state) do
    full_module = Module.concat(module_parts)
    aliases = Map.put(state.aliases, alias_as, full_module)
    {node, %{state | aliases: aliases}}
  end

  defp pre_traverse({:alias, _, [{:__aliases__, _, module_parts} | _]} = node, state) do
    full_module = Module.concat(module_parts)
    alias_name = List.last(module_parts)
    aliases = Map.put(state.aliases, alias_name, full_module)
    {node, %{state | aliases: aliases}}
  end

  defp pre_traverse({def_type, meta, [{name, _, args} = _fun_head, body]} = node, state) when def_type in [:def, :defp] do
    arity = if is_list(args), do: length(args), else: 0

    if name == state.target_function and arity == state.target_arity and (state.line == meta[:line] or is_nil(state.line)) do
      {{:function_boundary, meta, [body]}, %{state | in_target_function: true}}
    else
      {node, state}
    end
  end

  defp pre_traverse(
         {{:., _, [{:__aliases__, _, module_parts}, function]}, _, args} = node,
         %{in_target_function: true} = state
       ) do
    actual_module = resolve_module(module_parts, state.aliases)
    arity = length(args)
    {node, %{state | calls: [{actual_module, function, arity} | state.calls]}}
  end

# function call in a pipe
    defp pre_traverse(
         {:|>, meta,[node, {{:., _, [{:__aliases__, _, module_parts}, function]}, _, args}]},
         %{in_target_function: true} = state
       ) do
    actual_module = resolve_module(module_parts, state.aliases)
      arity = length(args) + 1

      # remove the last call from the list then it wont match above pattern
    {{:done, meta, [node]}, %{state | calls: [{actual_module, function, arity} | state.calls]}}
  end


  # dynamic module name call
  defp pre_traverse({{:., _, [{dynamic, _, _}, function]}, meta, args} = node, %{in_target_function: true} = state)
       when is_atom(dynamic) do
    actual_module = "Dynamic.#{dynamic}"
    arity = length(args)

    # no_parens, it could be dot operator for map
    if meta[:no_parens] == true do
      {node, state}
    else
      {node, %{state | calls: [{actual_module, function, arity} | state.calls]}}
    end
  end

  # handle call module function in pipe
  defp pre_traverse({:|>, _, [_, {function, _, args}]} = node, %{in_target_function: true} = state)
       when is_atom(function) and is_list(args) do
    # pass down to below function
    {_, state} = pre_traverse({function, nil, [:placeholder, args]}, state)
    {node, state}
  end

  defp pre_traverse({function, _, args} = node, %{in_target_function: true, current_module: current_module} = state)
       when is_atom(function) and is_list(args) do
    arity = length(args)

    if is_user_defined_function?(current_module, function, arity, state.module_definitions) do
      {node, %{state | calls: [{current_module, function, arity} | state.calls]}}
    else
      {node, state}
    end
  end

  defp pre_traverse(node, state) do
    {node, state}
  end

  defp post_traverse({:function_boundary, _meta, _body}, state) do
    {{:function_boundary, [], []}, %{state | in_target_function: false, completed_traversing: true}}
  end

  defp post_traverse({:defmodule, _, _}, state) do
    {{:defmodule, [], []}, %{state | current_module: nil}}
  end

  defp post_traverse(node, state) do
    {node, state}
  end

  defp resolve_module(module_parts, aliases) do
    case module_parts do
      [part] ->
        case Map.get(aliases, part) do
          nil -> Module.concat([part])
          full_module -> full_module
        end

      [first | rest] ->
        case Map.get(aliases, first) do
          nil -> Module.concat(module_parts)
          full_module -> Module.concat([full_module | rest])
        end
    end
  end

  defp filter_project_calls(calls, state) do
    calls
    |> Enum.uniq()
    |> Enum.reject(&should_ignore_module(&1, state.ignore_modules))
    |> Task.async_stream(fn {module, _function, _arity} = call ->
      if String.starts_with?(to_string(module), "Dynamic.") do
        call
      else
        case Cache.find_source_file_with_rg(module, state.project_dir) do
          nil -> nil
          _ -> call
        end
      end
    end)
    |> Stream.filter(&match?({:ok, call} when not is_nil(call), &1))
    |> Stream.map(fn {:ok, call} -> call end)
    |> Enum.to_list()
  end

  defp add_edges(state, {from_module, from_function, from_arity}, calls) do
    new_edges =
      Enum.reduce(calls, state.edges, fn {to_module, to_function, to_arity}, edges ->
        edge = {
          String.trim_leading("#{from_module}.#{from_function}/#{from_arity}", "Elixir."),
          String.trim_leading("#{to_module}.#{to_function}/#{to_arity}", "Elixir.")
        }

        [edge | edges]
      end)

    %{state | edges: new_edges}
  end

  defp should_ignore_module({m, f, a}, ignore_list) do
    signature = "#{m}.#{f}/#{a}"
    Enum.any?(ignore_list, &(signature =~ &1))
  end

  defp is_user_defined_function?(module, function, arity, module_definitions) do
    case Map.get(module_definitions, module) do
      nil -> false
      definitions -> Map.has_key?(definitions, {function, arity})
    end
  end
end
