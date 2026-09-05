harness = System.get_env("COMPAT_YELIXER_HARNESS") || Path.expand("../deps/yelixer", __DIR__)
Code.require_file(Path.join(harness, "test/support/compat_oracle.exs"))

defmodule Yepochs.UnicodeRuntimeTest do
  use ExUnit.Case, async: false
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.Text
  alias Yelixer.Test.CompatOracle, as: O
  alias Yepochs.{Algorithm, Bridge, Rebase}

  @harness System.get_env("COMPAT_YELIXER_HARNESS") || Path.expand("../deps/yelixer", __DIR__)
  @cases Jason.decode!(File.read!(Path.join(@harness, "test/fixtures/unicode_cases.json")))

  setup do
    p = O.open(Path.join(@harness, "test/fixtures/yjs_diff_driver.mjs"))
    on_exit(fn -> if Port.info(p), do: Port.close(p) end)
    %{port: p}
  end

  test "reauthoring can delete just a combining mark at a scalar boundary", %{port: p} do
    O.reset(p, 200)
    O.rpc(p, %{cmd: "insert_text", pos: 0, text: "e\u{0301}A"})
    before = O.load(O.update(p), 100)
    O.rpc(p, %{cmd: "delete_text", pos: 1, len: 1})
    edited = O.load(O.update(p), 100)
    {:ok, snap} = Yepochs.snapshot(before, [])
    target = O.load(snap.update, 300)
    assert {:ok, result} = Rebase.rebase(before, edited, target, author: 500)
    O.reset(p, 600)
    O.apply(p, snap.update)
    O.apply(p, result.update)
    assert O.text(p) == "eA"
  end

  for f <- @cases do
    @f f
    test "#{f["name"]}: foreign snapshot and bidirectional insert/delete crossing", %{port: p} do
      s = @f["text"]
      n = @f["units"]
      O.reset(p, 200)
      O.rpc(p, %{cmd: "insert_text", text: "L" <> s <> "R", pos: 0})
      source = O.load(O.update(p), 100)
      assert {:ok, snap} = Yepochs.snapshot(source, [])
      assert Enum.sum(Enum.map(snap.derivation.spans, & &1.length)) == n + 2
      target = O.load(snap.update, 300)
      O.reset(p, 400)
      O.apply(p, snap.update)
      assert O.text(p) == "L" <> s <> "R"
      {:ok, bridge} = Bridge.attach(snap.derivation, "source", "snapshot", Algorithm.snapshot())
      edited = Text.insert(source, "content", n + 1, "!")
      delta = Encoding.encode_diff(edited, Doc.state_vector(source))

      assert {:ok, cross} =
               Yepochs.cross(bridge, delta, source, target,
                 from: :left,
                 author: 500,
                 receipt_ref: "forward"
               )

      assert cross.mode == :translated
      {:ok, target} = Encoding.apply_update(target, cross.update)
      O.apply(p, cross.update)
      assert O.text(p) == "L" <> s <> "!R"
      assert Text.to_string(O.reload(target), "content") == "L" <> s <> "!R"
      {:ok, bridge} = Bridge.extend(bridge, cross.bridge_delta)
      O.rpc(p, %{cmd: "delete_text", pos: 1, len: n})
      O.rpc(p, %{cmd: "insert_text", pos: 3, text: "$"})
      back = O.update(p, Doc.state_vector(target))

      assert {:ok, cross} =
               Yepochs.cross(bridge, back, target, edited,
                 from: :right,
                 author: 600,
                 receipt_ref: "backward"
               )

      {:ok, source} = Encoding.apply_update(edited, cross.update)
      assert Text.to_string(O.reload(source), "content") == "L!R$"
      O.reset(p, 700)
      O.apply(p, Encoding.encode_update(source))
      assert O.text(p) == "L!R$"
    end

    @f f
    test "#{f["name"]}: positional reauthoring converts its diff to UTF-16", %{port: p} do
      s = @f["text"]
      O.reset(p, 200)
      O.rpc(p, %{cmd: "insert_text", text: s <> "AB", pos: 0})
      before = O.load(O.update(p), 100)
      O.rpc(p, %{cmd: "delete_text", pos: @f["units"], len: 1})
      O.rpc(p, %{cmd: "insert_text", pos: @f["units"], text: "X"})
      edited = O.load(O.update(p), 100)
      {:ok, snapshot} = Yepochs.snapshot(before, [])
      target = O.load(snapshot.update, 300)
      assert {:ok, result} = Rebase.rebase(before, edited, target, author: 500)
      O.reset(p, 600)
      O.apply(p, snapshot.update)
      O.apply(p, result.update)
      assert O.text(p) == s <> "XB"
      {:ok, out} = Encoding.apply_update(target, result.update)
      assert Text.to_string(O.reload(out), "content") == s <> "XB"
    end
  end
end
