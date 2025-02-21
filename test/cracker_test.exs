defmodule CrackerTest do
  use ExUnit.Case
  doctest Cracker

  test "greets the world" do
    assert Cracker.hello() == :world
  end
end
