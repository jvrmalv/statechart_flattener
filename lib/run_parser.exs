
Mix.install([
  {:statifier, "~> 1.9"}
])
defmodule ScxmlRunner do
  @moduledoc """
  Loads an SCXML file and parses it
  """
  def run(args) do
    case args do
      [file_path] ->
        parse_file(file_path)
      _ ->
        IO.puts("Usage: elixir run_parser.exs <path/to/machine.scxml>")
    end
  end

  defp parse_file(file_path) do
    IO.puts("Attempting to load: #{file_path}")

    case File.read(file_path) do
      {:ok, scxml_content} ->
        IO.puts("File loaded successfully. Starting Statify parsing...")
        parse_with_statify(scxml_content)

      {:error, reason} ->
        IO.puts(:stderr, "Error reading file: #{file_path}. Reason: #{reason}")
    end
  end

defp parse_with_statify(scxml_content) do
    # Assuming Statifier is available in your environment/mix setup
    case Statifier.parse(scxml_content) do
      {:ok, state_machine_spec, _warnings} ->
        IO.puts("\n✅ SCXML Parsed Successfully!")
        IO.puts("--- Parsed ---")
        # Print a small part of the resulting structure for confirmation
        IO.inspect(Map.take(state_machine_spec, [:initial, :states]))
        case Statifier.initialize(state_machine_spec) do
          {:ok, state_chart} ->

            IO.puts("\n✅ SCXML Initialized Successfully!")
            IO.puts("--- Initialized Statechart---")
            # Print a small part of the resulting structure for confirmation
            IO.inspect(state_chart)
          {:error, reason} ->
            IO.puts(:stderr, "\n❌ Error parsing SCXML:")
            IO.inspect(reason)
        end
      {:error, reason} ->
        IO.puts(:stderr, "\n❌ Error parsing SCXML:")
        IO.inspect(reason)
    end
  end
end

ScxmlRunner.run(System.argv())
