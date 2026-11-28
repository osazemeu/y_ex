defmodule Yex.DepthCapTest do
  # Nesting deeper than the caps used to overflow the scheduler stack and kill the
  # VM (SIGBUS) instead of failing. Every refusal case here takes the suite down
  # with its cap removed, and every at-cap case runs on the dirty NIF variant too,
  # whose scheduler stack is the smallest.
  use ExUnit.Case, async: true

  alias Yex.{
    Doc,
    MapPrelim,
    XmlElement,
    XmlElementPrelim,
    XmlFragment,
    XmlFragmentPrelim,
    XmlTextPrelim
  }

  # yrs' Any cap, also the term cap: the deepest value serde_json still parses, so a
  # v1 embed or format value written at it reloads from the doc's own state.
  @any_cap 127
  # yrs' shared-type cap (root = 0).
  @type_cap 128

  # A v1 update from client 1: root map "m", key "v" set to `any` (Any content).
  defp any_update(any_bytes), do: <<1, 1, 1, 0, 0x28, 1, 1, "m", 1, "v", 1>> <> any_bytes <> <<0>>

  # `levels` nested one-element arrays around a null, in the v1 Any encoding.
  defp nested_arrays(levels), do: :binary.copy(<<117, 1>>, levels) <> <<126>>

  defp nested_list(levels), do: Enum.reduce(1..levels, nil, fn _, inner -> [inner] end)

  defp list_depth([inner]), do: 1 + list_depth(inner)
  defp list_depth(nil), do: 0

  defp apply_dirty(doc, update), do: Yex.Nif.apply_update_v1_dirty(doc, nil, update)

  # A doc whose root map "m" holds `levels` nested maps under key "c", built one
  # level per local write (local writes do not pass yrs' integrate cap).
  defp nested_maps_state(levels) do
    doc = Doc.new()
    root = Doc.get_map(doc, "m")

    Doc.transaction(doc, fn ->
      Enum.reduce(1..levels, root, fn _, parent ->
        Yex.Map.set_and_get(parent, "c", MapPrelim.from(%{}))
      end)
    end)

    Yex.encode_state_as_update!(doc)
  end

  defp map_depth(%{"c" => inner}), do: 1 + map_depth(inner)
  defp map_depth(_leaf), do: 0

  describe "an Any value in an update" do
    test "nested 10,000 levels is refused as malformed, on both schedulers" do
      update = any_update(nested_arrays(10_000))
      assert {:error, {:encoding_exception, message}} = Yex.apply_update(Doc.new(), update)
      assert message =~ "nested deeper than #{@any_cap}"
      assert {:error, {:encoding_exception, _}} = apply_dirty(Doc.new(), update)
      assert {:error, {:encoding_exception, _}} = Doc.update_gaps(Doc.new(), update)
    end

    test "nested at the cap applies and reads back, on both schedulers" do
      update = any_update(nested_arrays(@any_cap))

      for apply <- [&Yex.apply_update/2, &apply_dirty/2] do
        doc = Doc.new()
        assert :ok = apply.(doc, update)
        assert %{"v" => value} = doc |> Doc.get_map("m") |> Yex.Map.to_json()
        assert list_depth(value) == @any_cap
        assert %{"v" => _} = Yex.Nif.map_to_json_dirty(Doc.get_map(doc, "m"), nil)
      end
    end
  end

  describe "a shared type nested in an update" do
    test "30,000 levels deep is refused, and what integrated stays readable" do
      state = nested_maps_state(30_000)

      for apply <- [&Yex.apply_update/2, &apply_dirty/2] do
        doc = Doc.new()
        assert {:error, :nesting_too_deep} = apply.(doc, state)
        map = Doc.get_map(doc, "m")
        assert map |> Yex.Map.to_json() |> map_depth() == @type_cap
        assert map |> Yex.Nif.map_to_json_dirty(nil) |> map_depth() == @type_cap

        # deleting the chain collects it without overflowing
        :ok = Yex.Map.delete(map, "c")
        assert Yex.Map.to_json(map) == %{}
      end
    end

    test "at the cap applies on both schedulers" do
      state = nested_maps_state(@type_cap)

      for apply <- [&Yex.apply_update/2, &apply_dirty/2] do
        doc = Doc.new()
        assert :ok = apply.(doc, state)

        assert doc |> Doc.get_map("m") |> Yex.Nif.map_to_json_dirty(nil) |> map_depth() ==
                 @type_cap
      end
    end
  end

  describe "a term written into a doc" do
    test "a plain map or list nested 2,000 levels raises instead of killing the VM" do
      map = Doc.new() |> Doc.get_map("m")
      deep_map = Enum.reduce(1..2_000, %{}, fn _, inner -> %{"c" => inner} end)

      assert_raise ArgumentError, ~r/nested deeper than #{@any_cap}/, fn ->
        Yex.Map.set(map, "v", deep_map)
      end

      assert_raise ArgumentError, ~r/nested deeper than #{@any_cap}/, fn ->
        Yex.Map.set(map, "v", nested_list(2_000))
      end

      assert Yex.Map.to_json(map) == %{}
    end

    test "2,000 nested MapPrelims or XmlElementPrelims raise instead of killing the VM" do
      doc = Doc.new()
      map = Doc.get_map(doc, "m")

      deep_prelim =
        Enum.reduce(1..2_000, MapPrelim.from(%{}), fn _, inner ->
          MapPrelim.from(%{"c" => inner})
        end)

      deep_xml =
        Enum.reduce(1..2_000, XmlElementPrelim.new("p", [XmlTextPrelim.from("x")]), fn _, inner ->
          XmlElementPrelim.new("blockquote", [inner])
        end)

      assert_raise ArgumentError, ~r/nested deeper than #{@any_cap}/, fn ->
        Yex.Map.set(map, "v", deep_prelim)
      end

      assert_raise ArgumentError, ~r/nested deeper than #{@any_cap}/, fn ->
        Yex.Map.set(map, "x", XmlFragmentPrelim.new([deep_xml]))
      end

      assert_raise ArgumentError, ~r/nested deeper than #{@any_cap}/, fn ->
        Yex.XmlFragment.push(Doc.get_xml_fragment(doc, "f"), deep_xml)
      end

      assert Yex.Map.to_json(map) == %{}
    end

    test "terms at the cap are written, and a refusal does not leak into the next call" do
      map = Doc.new() |> Doc.get_map("m")
      deep_map = Enum.reduce(1..(@any_cap - 1), %{}, fn _, inner -> %{"c" => inner} end)

      prelims =
        Enum.reduce(1..(@any_cap - 1), MapPrelim.from(%{}), fn _, inner ->
          MapPrelim.from(%{"c" => inner})
        end)

      assert_raise ArgumentError, fn -> Yex.Map.set(map, "z", nested_list(@any_cap + 1)) end
      assert :ok = Yex.Map.set(map, "a", deep_map)
      assert :ok = Yex.Map.set(map, "l", nested_list(@any_cap))
      assert :ok = Yex.Map.set(map, "p", prelims)

      json = Yex.Map.to_json(map)
      assert map_depth(json["a"]) == @any_cap - 1
      assert list_depth(json["l"]) == @any_cap
      assert map_depth(json["p"]) == @any_cap - 1
    end
  end

  describe "the worst honest content at both caps" do
    # Types nested to the cap whose leaf holds a cap-deep Any: every recursive op on the
    # dirty variants, whose scheduler stacks are the smallest.
    test "nested maps survive dirty apply, dirty to_json, dirty encode and delete" do
      doc = Doc.new()
      root = Doc.get_map(doc, "m")

      Doc.transaction(doc, fn ->
        leaf =
          Enum.reduce(1..@type_cap, root, fn _, parent ->
            Yex.Map.set_and_get(parent, "c", MapPrelim.from(%{}))
          end)

        :ok = Yex.Map.set(leaf, "a", nested_list(@any_cap))
      end)

      {:ok, update} = Yex.Nif.encode_state_as_update_v1_dirty(doc, nil, nil)
      fresh = Doc.new()
      assert :ok = apply_dirty(fresh, update)
      map = Doc.get_map(fresh, "m")
      json = Yex.Nif.map_to_json_dirty(map, nil)
      assert map_depth(json) == @type_cap
      assert {:ok, _} = Yex.Nif.encode_state_as_update_v1_dirty(fresh, nil, nil)

      :ok = Yex.Map.delete(map, "c")
      assert Yex.Map.to_json(map) == %{}
    end

    test "an XML chain at the cap reloads and prints" do
      doc = Doc.new()
      fragment = Doc.get_xml_fragment(doc, "f")

      Doc.transaction(doc, fn ->
        first = XmlFragment.push_and_get(fragment, XmlElementPrelim.empty("e"))

        innermost =
          Enum.reduce(2..(@type_cap - 1)//1, first, fn _, parent ->
            XmlElement.push_and_get(parent, XmlElementPrelim.empty("e"))
          end)

        :ok = XmlElement.insert_attribute(innermost, "a", nested_list(@any_cap))
        XmlElement.push(innermost, XmlTextPrelim.from("deep"))
      end)

      update = Yex.encode_state_as_update!(doc)

      for apply <- [&Yex.apply_update/2, &apply_dirty/2] do
        fresh = Doc.new()
        assert :ok = apply.(fresh, update)
        printed = fresh |> Doc.get_xml_fragment("f") |> XmlFragment.to_string()
        assert printed =~ "deep"
        assert printed == XmlFragment.to_string(fragment)
      end
    end
  end

  describe "text delta attributes" do
    test "nested past the cap raise instead of being dropped" do
      text = Doc.new() |> Doc.get_text("t")
      deep = nested_list(200)

      assert_raise ArgumentError, ~r/nested deeper than #{@any_cap}/, fn ->
        Yex.Text.apply_delta(text, [%{"insert" => "x", "attributes" => %{"f" => deep}}])
      end

      :ok = Yex.Text.insert(text, 0, "ab")

      assert_raise ArgumentError, ~r/nested deeper than #{@any_cap}/, fn ->
        Yex.Text.apply_delta(text, [%{"retain" => 1, "attributes" => %{"f" => deep}}])
      end

      assert Yex.Text.to_delta(text) == [%{insert: "ab"}]
    end

    test "at the cap are kept" do
      text = Doc.new() |> Doc.get_text("t")
      value = nested_list(@any_cap - 1)
      :ok = Yex.Text.apply_delta(text, [%{"insert" => "x", "attributes" => %{"f" => value}}])
      assert [%{insert: "x", attributes: %{"f" => ^value}}] = Yex.Text.to_delta(text)
    end
  end
end
