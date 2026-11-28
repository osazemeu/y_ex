defmodule Yex.DepthCapTest do
  # Nesting deeper than the caps used to overflow the scheduler stack and kill the
  # VM (SIGBUS) instead of failing. Every refusal case here takes the suite down
  # with its cap removed, and every at-cap case runs on the dirty NIF variant too,
  # whose scheduler stack is the smallest.
  use ExUnit.Case, async: true

  alias Yex.{
    ArrayPrelim,
    Doc,
    MapPrelim,
    TextPrelim,
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

  # A v1 update from client 1 whose root map "m" holds `levels` nested maps under key
  # "c", written by hand: local writes stop at the type cap, so a chain past it can only
  # arrive as an update. Each struct is a Type item (info 7 | 0x20 for its parent key, no
  # origins), parented by the root name for the first and by the previous item's ID after
  # that, holding a YMap (type ref 1). The delete set is empty.
  defp nested_maps_state(levels) do
    structs =
      for clock <- 0..(levels - 1)//1, into: <<>> do
        parent = if clock == 0, do: <<1, 1, "m">>, else: <<0, 1>> <> varuint(clock - 1)
        <<0x27>> <> parent <> <<1, "c", 1>>
      end

    <<1>> <> varuint(levels) <> <<1, 0>> <> structs <> <<0>>
  end

  defp varuint(n) when n < 0x80, do: <<n>>
  defp varuint(n), do: <<0x80 + Bitwise.band(n, 0x7F)>> <> varuint(Bitwise.bsr(n, 7))

  # The same chain built one local write at a time, from client 1.
  defp local_nested_maps_state(levels) do
    doc = Doc.with_options(%Doc.Options{client_id: 1})
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

  describe "a hand-encoded chain" do
    test "is byte-equal to the chain built locally, at 10 levels" do
      assert nested_maps_state(10) == local_nested_maps_state(10)
    end
  end

  describe "a local insert under a nested parent" do
    # `depth` levels below root "m": a chain of maps, then `container` at the last level.
    defp container_at(depth, container) do
      doc = Doc.new()
      root = Doc.get_map(doc, "m")

      parent =
        Enum.reduce(1..(depth - 1)//1, root, fn _, parent ->
          Yex.Map.set_and_get(parent, "c", MapPrelim.from(%{}))
        end)

      {doc, Yex.Map.set_and_get(parent, "x", container)}
    end

    # `levels` nested MapPrelims, the innermost empty.
    defp map_prelim(levels),
      do:
        Enum.reduce(2..levels//1, MapPrelim.from(%{}), fn _, inner ->
          MapPrelim.from(%{"c" => inner})
        end)

    defp xml_prelim(levels),
      do:
        Enum.reduce(2..levels//1, XmlElementPrelim.empty("e"), fn _, inner ->
          XmlElementPrelim.new("e", [inner])
        end)

    # Every insert NIF, with the container it inserts into and a value `levels` deep.
    defp insert_calls(levels) do
      map = map_prelim(levels)
      xml = xml_prelim(levels)
      delta = [%{"insert" => map}]
      attr = %{"b" => true}

      [
        map_set: {MapPrelim.from(%{}), &Yex.Nif.map_set(&1, nil, "k", map)},
        array_insert: {ArrayPrelim.from([]), &Yex.Nif.array_insert(&1, nil, 0, map)},
        array_insert_and_get:
          {ArrayPrelim.from([]), &Yex.Nif.array_insert_and_get(&1, nil, 0, map)},
        text_insert_embed: {TextPrelim.from(""), &Yex.Nif.text_insert_embed(&1, nil, 0, map)},
        text_insert_embed_with_attributes:
          {TextPrelim.from(""), &Yex.Nif.text_insert_embed_with_attributes(&1, nil, 0, map, attr)},
        text_apply_delta: {TextPrelim.from(""), &Yex.Nif.text_apply_delta(&1, nil, delta)},
        xml_fragment_insert:
          {XmlFragmentPrelim.new([]), &Yex.Nif.xml_fragment_insert(&1, nil, 0, xml)},
        xml_fragment_insert_and_get:
          {XmlFragmentPrelim.new([]), &Yex.Nif.xml_fragment_insert_and_get(&1, nil, 0, xml)},
        xml_element_insert:
          {XmlElementPrelim.empty("p"), &Yex.Nif.xml_element_insert(&1, nil, 0, xml)},
        xml_element_insert_and_get:
          {XmlElementPrelim.empty("p"), &Yex.Nif.xml_element_insert_and_get(&1, nil, 0, xml)},
        xml_element_insert_attribute:
          {XmlElementPrelim.empty("p"), &Yex.Nif.xml_element_insert_attribute(&1, nil, "a", map)},
        xml_text_insert_embed:
          {XmlTextPrelim.from(""), &Yex.Nif.xml_text_insert_embed(&1, nil, 0, map)},
        xml_text_insert_embed_with_attributes:
          {XmlTextPrelim.from(""),
           &Yex.Nif.xml_text_insert_embed_with_attributes(&1, nil, 0, map, attr)},
        xml_text_apply_delta:
          {XmlTextPrelim.from(""), &Yex.Nif.xml_text_apply_delta(&1, nil, delta)},
        xml_text_insert_attribute:
          {XmlTextPrelim.from(""), &Yex.Nif.xml_text_insert_attribute(&1, nil, "a", map)}
      ]
    end

    test "raises for every insert NIF when parent and prelim pass the cap, writing nothing" do
      # parent depth 100 + prelim 29 = 129
      for {name, {container, call}} <- insert_calls(29) do
        {doc, parent} = container_at(100, container)
        before = Yex.encode_state_vector!(doc)

        message =
          try do
            call.(parent)
            nil
          rescue
            error in ArgumentError -> error.message
          end

        assert is_binary(message) and message =~ "deeper than #{@type_cap} levels",
               "#{name} did not raise: #{inspect(message)}"

        assert Yex.encode_state_vector!(doc) == before, "#{name} wrote"
      end
    end

    test "at the cap every insert NIF writes a state a fresh doc applies" do
      # parent depth 100 + prelim 28 = 128
      for {name, {container, call}} <- insert_calls(28) do
        {doc, parent} = container_at(100, container)
        call.(parent)
        state = Yex.encode_state_as_update!(doc)

        for apply <- [&Yex.apply_update/2, &apply_dirty/2] do
          assert :ok = apply.(Doc.new(), state), "#{name} did not reload"
        end
      end
    end

    test "one level per call stops at the cap, and the chain reloads" do
      doc = Doc.new()
      root = Doc.get_map(doc, "m")

      deepest =
        Enum.reduce(1..@type_cap, root, fn _, parent ->
          Yex.Map.set_and_get(parent, "c", MapPrelim.from(%{}))
        end)

      before = Yex.encode_state_vector!(doc)

      assert_raise ArgumentError, ~r/deeper than #{@type_cap} levels/, fn ->
        Yex.Map.set(deepest, "c", MapPrelim.from(%{}))
      end

      assert Yex.encode_state_vector!(doc) == before
      fresh = Doc.new()
      assert :ok = Yex.apply_update(fresh, Yex.encode_state_as_update!(doc))
      assert fresh |> Doc.get_map("m") |> Yex.Map.to_json() |> map_depth() == @type_cap
    end

    test "an Any value is not counted, however deep the parent" do
      {doc, deepest} = container_at(@type_cap, MapPrelim.from(%{}))
      deep_map = Enum.reduce(1..(@any_cap - 1), %{}, fn _, inner -> %{"c" => inner} end)

      assert :ok = Yex.Map.set(deepest, "a", deep_map)
      assert :ok = Yex.Map.set(deepest, "l", nested_list(@any_cap))
      assert_raise ArgumentError, fn -> Yex.Map.set(deepest, "p", MapPrelim.from(%{})) end

      assert :ok = Yex.apply_update(Doc.new(), Yex.encode_state_as_update!(doc))
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
