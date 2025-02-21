defmodule Cracker.Cache do
  @moduledoc """
  Handles caching of module definitions, AST, and source file paths.
  """

  def with_tables(fun) do
    tables = create_tables()

    try do
      fun.(tables)
    after
      cleanup_tables(tables)
    end
  end

  defp create_tables do
    suffix = :erlang.unique_integer([:positive])

    tables = %{
      module_cache: :"module_definitions_cache_#{suffix}",
      ast_cache: :"ast_cache_#{suffix}",
      source_file_cache: :"source_file_cache_#{suffix}"
    }

    :ets.new(tables.module_cache, [:named_table, :set, :public])
    :ets.new(tables.ast_cache, [:named_table, :set, :public])
    :ets.new(tables.source_file_cache, [:named_table, :set, :public])

    tables
  end

  defp cleanup_tables(tables) do
    :ets.delete(tables.module_cache)
    :ets.delete(tables.ast_cache)
    :ets.delete(tables.source_file_cache)
  end

  def get_or_find_source_file(module_name, state) do
    cache_key = {:source_file, module_name}

    case :ets.lookup(state.tables.source_file_cache, cache_key) do
      [{^cache_key, path}] ->
        path

      [] ->
        path = find_source_file_with_rg(module_name, state.project_dir)
        :ets.insert(state.tables.source_file_cache, {cache_key, path})
        path
    end
  end

  def get_or_extract_module_definitions(file_path, module_name, state) do
    cache_key = {:module_defs, module_name}

    Process.get(cache_key) ||
      case :ets.lookup(state.tables.module_cache, cache_key) do
        [{^cache_key, result}] ->
          Process.put(cache_key, result)
          result

        [] ->
          result = extract_module_definitions(file_path, module_name)
          :ets.insert(state.tables.module_cache, {cache_key, result})
          Process.put(cache_key, result)
          result
      end
  end

  def find_source_file_with_rg(module_name, project_dir) do
    module_string = module_name |> Atom.to_string() |> String.trim_leading("Elixir.")
    pattern = "defmodule\\s+#{module_string}\\s+"

    case System.cmd("rg", ["--type", "elixir", "--files-with-matches", pattern, project_dir]) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> List.first()

      {_, _} ->
        nil
    end
  end

  def extract_module_definitions(file_path, module_name) do
    ast =
      file_path
      |> File.read!()
      |> Code.string_to_quoted!(columns: false)

    {_ast, acc} =
      Macro.prewalk(ast, {module_name, %{}}, fn
        {:defmodule, _, [{:__aliases__, _, module_parts}, _]} = node, {_, defs} ->
          {node, {Module.concat(module_parts), defs}}

        {def_type, _, [{name, _, args} = fun_head, _body]}, {current_module, defs}
        when def_type in [:def, :defp] ->
          arity = if is_list(args), do: length(args), else: 0
          new_defs = Map.update(defs, current_module, %{{name, arity} => true}, &Map.put(&1, {name, arity}, true))
          {fun_head, {current_module, new_defs}}

        node, acc ->
          {node, acc}
      end)

    {elem(acc, 1), ast}
  end
end
