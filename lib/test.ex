defmodule Test do
  def run() do
    "Hello, World!"
    |> String.capitalize()
    |> String.trim_leading(" ")
    |> trans(1)
  end

  def trans(message, num) do
    IO.puts("Message: #{message} #{num}")
  end
end
