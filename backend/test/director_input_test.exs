defmodule Sinestesia.DirectorInputTest do
  @moduledoc """
  What the Director is allowed to see.

  Reproduces the failure from the 2026-07-25 Aquarela run: the Director fired on
  a three-word partial ("Num instante im") and never saw the rest of that line,
  so it painted "in an instant, everything changes" instead of a seagull.
  """
  use ExUnit.Case, async: true

  # Only the fields unsent_text/2 reads. Building the real GenServer state would
  # couple this test to every unrelated field in it.
  defp state(fields) do
    Map.merge(%{lyrics: [], lyrics_sent: 0, last_interims: %{}, last_text_at: %{}}, fields)
  end

  defp partial(state, provider, text, at) do
    state
    |> put_in([:last_interims, provider], text)
    |> put_in([:last_text_at, provider], at)
  end

  # ElevenLabs commits a segment: the partial becomes a final, and last_interims
  # still holds that same text until the next segment starts (see
  # update_text_state/5).
  defp commit(state, provider, text, at) do
    state
    |> Map.update!(:lyrics, &(&1 ++ [text]))
    |> partial(provider, text, at)
  end

  describe "lines committed while an image was rendering" do
    test "reach the Director on the next call instead of being dropped" do
      # The Director fires on the fragment that happened to be in flight.
      s = state(%{}) |> partial(:elevenlabs, "Num instante im", 1_000)
      assert Sinestesia.Pipeline.unsent_text(s) == "Num instante im"

      # It renders for ~3s. Meanwhile the line finishes and commits.
      s = commit(s, :elevenlabs, "Num instante imagino uma linda gaivota voar no céu", 4_000)

      # The old behaviour read only the interim, so the next call saw whatever
      # fragment had started after the commit and the seagull was lost.
      text = Sinestesia.Pipeline.unsent_text(s)
      assert text =~ "gaivota"
      assert text =~ "imagino"
    end

    test "several lines committed during one render all survive" do
      s =
        state(%{})
        |> commit(:elevenlabs, "E se faço chover com dois riscos", 1_000)
        |> commit(:elevenlabs, "tem um guarda-chuva", 2_000)

      text = Sinestesia.Pipeline.unsent_text(s)
      assert text =~ "chover"
      assert text =~ "guarda-chuva"
    end

    test "a committed line is handed over exactly once" do
      s = state(%{}) |> commit(:elevenlabs, "um pinguinho de tinta", 1_000)
      assert Sinestesia.Pipeline.unsent_text(s) =~ "pinguinho"

      # After the Director fires, maybe_trigger/1 advances the cursor.
      s = %{s | lyrics_sent: length(s.lyrics)}
      assert Sinestesia.Pipeline.unsent_text(s) == ""
    end

    test "the in-progress partial does not advance the cursor" do
      # Fired on a partial: the line hasn't committed, so nothing is consumed
      # and the full line must still arrive later.
      s = state(%{}) |> partial(:elevenlabs, "Contornando a imensa", 1_000)
      assert Sinestesia.Pipeline.unsent_text(s) == "Contornando a imensa"
      assert s.lyrics_sent == 0

      s = commit(s, :elevenlabs, "Contornando a imensa curva, norte-sul, vou com ela", 3_000)
      assert Sinestesia.Pipeline.unsent_text(s) =~ "norte-sul"
    end
  end

  describe "deduplication" do
    test "a just-committed line is not counted twice" do
      s =
        state(%{}) |> commit(:elevenlabs, "Numa folha qualquer eu desenho um sol amarelo", 1_000)

      text = Sinestesia.Pipeline.unsent_text(s)

      assert text == "Numa folha qualquer eu desenho um sol amarelo"
      refute text =~ ~r/amarelo.*amarelo/
    end

    test "an empty transcript yields nothing to send" do
      assert Sinestesia.Pipeline.unsent_text(state(%{})) == ""
      assert Sinestesia.Pipeline.unsent_text(state(%{}) |> partial(:elevenlabs, "   ", 1)) == ""
    end
  end

  describe "windowing" do
    test "catching up on commits gets a wider window than a bare partial" do
      long = Enum.map_join(1..40, " ", &"w#{&1}")

      partial_only = state(%{}) |> partial(:elevenlabs, long, 1_000)
      assert Sinestesia.Pipeline.unsent_text(partial_only) |> word_count() == 10

      # Committed material is unrecoverable if truncated, so it gets more room.
      committed = state(%{}) |> commit(:elevenlabs, long, 1_000)
      assert Sinestesia.Pipeline.unsent_text(committed) |> word_count() == 24
    end

    test "keeps the END of an over-long line, where the newest lyrics are" do
      s = state(%{}) |> partial(:elevenlabs, Enum.map_join(1..40, " ", &"w#{&1}"), 1_000)
      assert Sinestesia.Pipeline.unsent_text(s) |> String.ends_with?("w40")
    end
  end

  describe "multiple STT providers" do
    test "the most recent provider supplies the in-progress line" do
      s =
        state(%{})
        |> partial(:deepgram, "stale fragment", 1_000)
        |> partial(:elevenlabs, "fresher fragment", 2_000)

      assert Sinestesia.Pipeline.unsent_text(s) == "fresher fragment"
    end
  end

  defp word_count(text), do: text |> String.split(~r/\s+/, trim: true) |> length()
end
