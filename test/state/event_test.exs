defmodule Kogen.State.EventTest do
  use ExUnit.Case, async: true

  alias Kogen.State
  alias Kogen.State.Event

  test "journal decoding preserves setup cache savings" do
    assert {:ok, %Event{event: "setup_reused", setup_key: "abc123", saved_wall_ms: 900}} =
             State.decode_event(
               ~s({"event":"setup_reused","setup_key":"abc123","saved_wall_ms":900})
             )
  end
end
