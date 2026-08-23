defmodule Yepochs.FixtureCoverageTest do
  @moduledoc """
  ⭐ **A requirement that no test enforces is indistinguishable from an absent
  one** — and one that IS enforced, but whose enforcing test cannot be located,
  is the next thing to it.

  Spec r3 §28.2 lists 28 mandatory fixtures. Every one of them was in fact
  covered before this file existed, but only **13 of 28 could be traced by
  number**; the rest required reading the suite and guessing at wording. ⛔ That
  is how §28.1's *"mixed source client IDs"* requirement — which the suite DOES
  enforce — failed to reach `test/totality_test.exs`, whose corpus was degenerate
  for exactly the reason §28.1 exists to prevent.

  This test reads the spec, extracts the numbered fixture list, and requires each
  number to be claimed in the suite by a `§28.2 fixture N` marker — or recorded
  by number in `@unsatisfied` with a reason.

  ⚠️ **It reads the SPEC, not a hard-coded count.** Adding a fixture to §28.2
  fails this test until it is either covered or deliberately recorded, which is
  the whole point: the list cannot grow silently past the suite.
  """
  use ExUnit.Case, async: true

  @spec_path "docs/proposals/2026-08-23-yepochs-spec-r3.md"

  # ⛔ Fixtures deliberately NOT satisfied here, recorded rather than omitted.
  @unsatisfied %{
    26 =>
      "destination admission is the caller's concern; this library owns no writer. " <>
        "Recorded in test/conformance_test.exs."
  }

  defp spec_fixture_numbers do
    body = File.read!(@spec_path)

    [_, section] = String.split(body, "### 28.2 New mandatory fixtures", parts: 2)
    [list, _] = String.split(section, "\n### ", parts: 2)

    ~r/^(\d+)\.\s/m
    |> Regex.scan(list)
    |> Enum.map(fn [_, n] -> String.to_integer(n) end)
  end

  defp marked_numbers do
    "test/**/*.exs"
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      ~r/fixture (\d+)/
      |> Regex.scan(File.read!(path))
      |> Enum.map(fn [_, n] -> String.to_integer(n) end)
    end)
    |> MapSet.new()
  end

  test "the spec's fixture list is contiguous from 1, so nothing was lost in renumbering" do
    numbers = spec_fixture_numbers()

    assert numbers == Enum.to_list(1..length(numbers)),
           "§28.2's numbering is not 1..n — a renumbering dropped or duplicated an entry: " <>
             inspect(numbers)
  end

  test "every §28.2 fixture is either covered by a marked test or recorded as unsatisfied" do
    marked = marked_numbers()

    unaccounted =
      spec_fixture_numbers()
      |> Enum.reject(&(&1 in marked or Map.has_key?(@unsatisfied, &1)))

    assert unaccounted == [],
           "§28.2 fixtures with neither a `fixture N` marker nor an @unsatisfied entry: " <>
             inspect(unaccounted)
  end

  test "nothing claims a fixture number the spec does not define" do
    # ⚠️ The other direction, and it is not symmetric decoration: a marker for a
    # fixture that no longer exists means a test is anchored to a requirement
    # that moved, which is precisely how a suite drifts from its spec.
    defined = MapSet.new(spec_fixture_numbers())

    stray = marked_numbers() |> Enum.reject(&(&1 in defined)) |> Enum.sort()

    assert stray == [],
           "markers reference fixture numbers §28.2 does not define: #{inspect(stray)}"
  end

  test "every @unsatisfied entry names a real fixture and gives a reason" do
    defined = MapSet.new(spec_fixture_numbers())

    for {number, reason} <- @unsatisfied do
      assert number in defined,
             "@unsatisfied names fixture #{number}, which §28.2 does not define"

      assert is_binary(reason) and byte_size(reason) > 20, "fixture #{number} needs a real reason"
    end
  end

  test "the spec file this reads actually exists and is the one the library claims" do
    # ⭐ Positive control. Every assertion above passes vacuously if the split on
    # the section heading yields an empty list — a missing or renamed spec would
    # look exactly like a fully-covered suite.
    assert File.exists?(@spec_path)

    numbers = spec_fixture_numbers()
    assert length(numbers) >= 20, "only #{length(numbers)} fixtures parsed — the reader is blind"

    assert File.read!("lib/yepochs.ex") =~ Path.basename(@spec_path),
           "the library's moduledoc cites a different spec revision than this test audits"
  end
end
