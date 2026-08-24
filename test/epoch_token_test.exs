defmodule Yepochs.EpochTokenTest do
  use ExUnit.Case, async: true

  alias Yepochs.Algorithm
  alias Yepochs.EpochToken
  alias Yepochs.Error

  @snapshot %Algorithm{id: "yepochs.snapshot", version: 3}

  test "matches every conformance vector" do
    assert {:ok, "566bd000927dfd335086438d47412c58736fcbcde21c372282bb684eb145f97a"} =
             EpochToken.mint(["commit:aaa"], ["epoch:E1"], @snapshot)

    assert {:ok, "aa96fa5ff052168bfb391da199c430582721d127a25f9b20a1bb2549b6f31f65"} =
             EpochToken.mint(["commit:bbb", "commit:aaa"], ["epoch:E1"], @snapshot)

    assert {:ok, "cbee36a3f7372ffb1fd4d1507c34fef0e58a4617cda773f455971d3b3fa6afaf"} =
             EpochToken.mint(
               ["commit:bbb", "commit:aaa"],
               ["epoch:E2", "epoch:E1"],
               @snapshot
             )

    assert {:ok, "cbee36a3f7372ffb1fd4d1507c34fef0e58a4617cda773f455971d3b3fa6afaf"} =
             EpochToken.mint(
               ["commit:aaa", "commit:bbb"],
               ["epoch:E1", "epoch:E2"],
               @snapshot
             )

    assert {:ok, "cbee36a3f7372ffb1fd4d1507c34fef0e58a4617cda773f455971d3b3fa6afaf"} =
             EpochToken.mint(
               ["commit:bbb", "commit:aaa"],
               ["epoch:E2", "epoch:E1", "epoch:E1"],
               @snapshot
             )

    assert {:ok, "7ae2487a5d98cd6d899d87a472bf5c067fd1ba2d1210e981516d5df756171909"} =
             EpochToken.mint(
               ["commit:aaa"],
               ["epoch:E1"],
               %Algorithm{id: "yepochs.snapshot", version: 2}
             )

    assert {:ok, "49d3762dbeeddb84e623d1b57976b50992177473ffa04fbd546336243e8f9269"} =
             EpochToken.mint(
               ["commit:aaa"],
               ["epoch:E1"],
               %Algorithm{id: "yepochs.other", version: 3}
             )

    assert {:ok, "8e97da39e3493790567d2be295a74e356f4e83429ef1f9dcf0742a183352c419"} =
             EpochToken.mint(["ab", "c"], ["x"], @snapshot)

    assert {:ok, "cd25c2e6b476ac44dca676cec091e2d76411cd180c0c85103ca204aa74dcf4d9"} =
             EpochToken.mint(["a", "bc"], ["x"], @snapshot)

    assert {:ok, "3584377094a115e688d66928b5d3a4f320cfd3e46dcfb80632364bcafd17bf85"} =
             EpochToken.mint([], ["epoch:E1"], @snapshot)
  end

  test "pre-sorted inputs equal unsorted inputs" do
    assert EpochToken.mint(
             ["commit:aaa", "commit:bbb"],
             ["epoch:E1", "epoch:E2"],
             @snapshot
           ) ==
             EpochToken.mint(
               ["commit:bbb", "commit:aaa"],
               ["epoch:E2", "epoch:E1"],
               @snapshot
             )
  end

  test "a duplicate source epoch equals the distinct source epoch set" do
    assert EpochToken.mint(["commit:aaa"], ["epoch:E1", "epoch:E1"], @snapshot) ==
             EpochToken.mint(["commit:aaa"], ["epoch:E1"], @snapshot)
  end

  test "algorithm version is bound into the token" do
    version_two = %Algorithm{@snapshot | version: 2}

    refute EpochToken.mint(["commit:aaa"], ["epoch:E1"], version_two) ==
             EpochToken.mint(["commit:aaa"], ["epoch:E1"], @snapshot)
  end

  test "algorithm id is bound into the token" do
    other = %Algorithm{@snapshot | id: "yepochs.other"}

    refute EpochToken.mint(["commit:aaa"], ["epoch:E1"], other) ==
             EpochToken.mint(["commit:aaa"], ["epoch:E1"], @snapshot)
  end

  test "length framing distinguishes different splits of the same bytes" do
    # Unframed concatenation collides here; this is why every string has a length prefix.
    refute EpochToken.mint(["ab", "c"], ["x"], @snapshot) ==
             EpochToken.mint(["a", "bc"], ["x"], @snapshot)
  end

  test "rejects empty refs" do
    assert_invalid_ref([""], ["epoch:E1"], [:parent_ids, 0])
    assert_invalid_ref(["commit:aaa"], [""], [:source_epochs, 0])
  end

  test "rejects refs longer than 1024 bytes" do
    too_long = String.duplicate("a", 1025)

    assert_invalid_ref([too_long], ["epoch:E1"], [:parent_ids, 0])
    assert_invalid_ref(["commit:aaa"], [too_long], [:source_epochs, 0])
  end

  test "rejects invalid UTF-8 refs" do
    invalid_utf8 = <<255>>

    assert_invalid_ref([invalid_utf8], ["epoch:E1"], [:parent_ids, 0])
    assert_invalid_ref(["commit:aaa"], [invalid_utf8], [:source_epochs, 0])
  end

  test "rejects non-binary ref elements" do
    assert_invalid_ref([:not_a_binary], ["epoch:E1"], [:parent_ids, 0])
    assert_invalid_ref(["commit:aaa"], [123], [:source_epochs, 0])
  end

  test "accepts refs exactly 1024 bytes long" do
    max_length_ref = String.duplicate("a", 1024)

    assert {:ok, token} = EpochToken.mint([max_length_ref], [max_length_ref], @snapshot)
    assert byte_size(token) == 64
  end

  defp assert_invalid_ref(parent_ids, source_epochs, path) do
    assert {:error, %Error{code: :invalid_epoch_ref, phase: :snapshot, path: ^path}} =
             EpochToken.mint(parent_ids, source_epochs, @snapshot)
  end
end
