defmodule Mix.Tasks.Cracker do
  @moduledoc """
  Generates a function call graph in Mermaid format.

  ## Usage

      mix graph.function ModuleName.function_name/arity

  ## Examples

      mix crack MyApp.UserController.create/2
      mix crack.function "Elixir.MyApp.UserController.create/2"

  ## Configuration

  Add to your config/config.exs:

      config :function_grapher,
        ignore_modules: [
          "Enum",
          "String",
          "Phoenix.Controller"
        ]
  """

  use Mix.Task

  @shortdoc "Generates a function call graph"

  @impl Mix.Task
  def run(args) do
    case parse_args(args) do
      {:ok, mfa} ->
        case Cracker.verify_ripgrep_installed() do
          {:ok, _} ->
            generate_graph(mfa)
          {:error, message} ->
            Mix.raise(message)
        end
      {:error, message} ->
        Mix.raise(message)
    end
  end

  defp parse_args([mfa_string]) do
    case parse_mfa(mfa_string) do
      {:ok, mfa} -> {:ok, mfa}
      :error -> {:error, """
        Invalid MFA format. Expected format:
        ModuleName.function_name/arity or "Elixir.ModuleName.function_name/arity"

        Examples:
        - MyApp.UserController.create/2
        - "Elixir.MyApp.UserController.create/2"
        """}
    end
  end

  defp parse_args(_) do
    {:error, "Expected exactly one argument: ModuleName.function_name/arity"}
  end

  def parse_mfa(mfa_string) do
    # Remove quotes if present
    mfa_string = String.trim(mfa_string, "\"")

    case String.split(mfa_string, [".", "/"]) do
      parts when length(parts) >= 3 ->
        module_parts = Enum.take(parts, length(parts) - 2)
        [function_name, arity] = Enum.take(parts, -2)

        with {:ok, module} <- parse_module(module_parts),
             {:ok, function} <- parse_function(function_name),
             {:ok, arity} <- parse_arity(arity) do
          {:ok, {module, function, arity}}
        else
          {:error, _reason} ->
            :error
        end
      _ ->
        :error
    end
  end

  defp parse_module(module_parts) do
    try do
      module = Module.concat(module_parts)
      {:ok, module}
    rescue
      _ -> {:error, "bad module"}
    end
  end

  defp parse_function(function_name) do
    try do
      function = String.to_atom(function_name)
      {:ok, function}
    rescue
      _ -> {:error, "function not exist"}
    end
  end

  defp parse_arity(arity_string) do
    case Integer.parse(arity_string) do
      {arity, ""} when arity >= 0 -> {:ok, arity}
      _ -> {:error, "bad arity"}
    end
  end

  defp generate_graph(mfa) do
    # Get ignore_modules from config
    ignore_modules = Application.get_all_env(:function_grapher)
      |> Keyword.get(:ignore_modules, [])

    # Generate the graph
    graph_data = Cracker.generate_graph(
      mfa,
      File.cwd!(),
      ignore_modules: ignore_modules
                 )

    graph = Cracker.MermaidGenerator.generate(graph_data)
    IO.puts(graph)
  end

  # defp copy(text) do
  #   port = Port.open({:spawn, "pbcopy"}, [:binary])
  #   Port.command(port, text)
  #   Port.close(port)
  # end
end
