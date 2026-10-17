defmodule StatechartFlattenerTest do
  use ExUnit.Case

  defp assert_m4_transitions_fixed(states) do
    base_of = fn state_id -> state_id |> String.split("__") |> List.first() end
    leaf_bases = states |> Enum.map(&base_of.(&1["state"])) |> MapSet.new()

    assert MapSet.member?(leaf_bases, "modes_Automatic_Light_Sensing_Dark")

    for s <- states do
      src_base = base_of.(s["state"])

      for t <- s["transitions"] do
        tgt_base = base_of.(t["target"])

        case {src_base, t["input"]} do
          {"modes_Automatic_Light_Sensing_Getting_Dark", "Getting Dark_t_1_timeEvent_0"} ->
            assert tgt_base == "modes_Automatic_Light_Sensing_Dark"

          {"modes_Automatic_Light_Sensing_Getting_Dark", "luminosity.bright"} ->
            assert tgt_base == "modes_Automatic_Light_Sensing_Bright"

          {"modes_Automatic_Light_Sensing_Getting_Bright", "Getting Bright_t_1_timeEvent_0"} ->
            assert tgt_base == "modes_Automatic_Light_Sensing_Bright"

          {"modes_Automatic_Light_Sensing_Getting_Bright", "luminosity.dark"} ->
            assert tgt_base == "modes_Automatic_Light_Sensing_Dark"

          _ ->
            :ok
        end
      end
    end
  end

  test "M4 ICTSS flattened JSON has 87 states, 283 transitions, Dark reachable, and fixed transitions" do
    json_path =
      Path.join([
        __DIR__,
        "..",
        "lib",
        "generated_jsons",
        "_04_LightAndMotionSensingLightSwitch_flattened.json"
      ])

    data = json_path |> File.read!() |> JSON.decode!()
    states = data["states"]
    total_transitions = Enum.reduce(states, 0, fn s, acc -> acc + length(s["transitions"]) end)

    assert length(states) == 87
    assert total_transitions == 283
    assert_m4_transitions_fixed(states)
  end

  test "M4 scxml_flattener_full JSON (shallow_history_test_full) resolves Dark and underscore transitions" do
    json_path = Path.join([__DIR__, "..", "lib", "shallow_history_test_full.json"])
    data = json_path |> File.read!() |> JSON.decode!()
    states = data["states"]

    assert length(states) == 31
    assert_m4_transitions_fixed(states)
  end
end
