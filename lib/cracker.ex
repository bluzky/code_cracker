defmodule Cracker do
  @moduledoc """
  Analyzes Elixir code to generate a function call graph starting from a specified entry point.
  Outputs the graph in Mermaid format for visualization.
  Uses automatic ETS caching that cleans up after analysis.

  # Example usage
  defmodule Example do
  @moduledoc false
  def run do
    # First verify ripgrep is installed
    case Cracker.verify_ripgrep_installed() do
      {:ok, _} ->
        graph_data =
          Cracker.generate_graph({OpolloChat.Iris, :auto_reply, 3}, "/Users/bluzky/onpoint/opollo/",
            ignore_modules: [
              "OpolloOrderStatus",
              "OrderStatus",
              "Nested",
              ".changeset",
              "QueryBuilder",
              ".t/0",
              "Utils.",
              "Status",
              "Repo",
              "FromType"
            ]
          )

        graph = Cracker.MermaidGenerator.generate(graph_data)
        copy(graph)
        IO.puts("Text copied to clipboard!")
        # Write to file
        # File.write!("function_graph.mmd", graph)
        :ok

      {:error, message} ->
        IO.puts(message)
        :error
    end
  end

  defp copy(text) do
    port = Port.open({:spawn, "pbcopy"}, [:binary])
    Port.command(port, text)
    Port.close(port)
  end
  end

  """

  alias Cracker.Analyzer
  alias Cracker.Cache

  @default_opts [
    ignore_modules: [],
    line: nil
  ]

  def generate_graph(mfa, project_dir, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)

    Cache.with_tables(fn tables ->
      initial_state = %{
        visited: MapSet.new(),
        edges: [],
        project_dir: project_dir,
        ignore_modules: opts[:ignore_modules],
        tables: tables,
        module_definitions: %{},
        line: opts[:line]
      }

      state = Analyzer.analyze_function(mfa, initial_state)

      state.edges
      |> Enum.reverse()
      |> Enum.uniq()
    end)
  end

  def verify_ripgrep_installed do
    case System.find_executable("rg") do
      nil ->
        {:error,
         """
         Ripgrep (rg) is not installed. Please install it:

         - macOS: brew install ripgrep
         - Ubuntu/Debian: sudo apt-get install ripgrep
         - Windows: choco install ripgrep
         """}

      path ->
        {:ok, "Ripgrep found at: #{path}"}
    end
  end
end
