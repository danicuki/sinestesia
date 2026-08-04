defmodule Sinestesia.LyricsImport.LetrasSearchTest do
  use ExUnit.Case, async: true

  # The JSONP-parsing half of LetrasComBr.search/1, exercised against a
  # local stub serving a captured solr response — the live endpoint's exact
  # shape as of 2026-08-04 (callback wrapper, trailing newline, string ids,
  # a doc with no "url" key mixed in). The query-sanitizing half
  # ("Simon & Garfunkel" must not reach solr with the ampersand) is pinned
  # by asserting on the query the stub receives.

  @jsonp ~s|LetrasSug({"response":{"numFound":2,"start":0,"docs":[| <>
           ~s|{"art":"Simon & Garfunkel","dns":"simon-e-garfunkel","url":"36243"},| <>
           ~s|{"art":"Album entry","dns":"simon-e-garfunkel","urlal":"bridge-1970"},| <>
           ~s|{"art":"Simon & Garfunkel","dns":"simon-e-garfunkel","url":"36243"},| <>
           ~s|{"art":"Leona Lewis","dns":"leona-lewis","url":"1205062"}| <>
           ~s|]},"highlighting":{}})\n|

  setup do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    parent = self()

    spawn_link(fn ->
      {:ok, sock} = :gen_tcp.accept(listener)
      {:ok, req} = :gen_tcp.recv(sock, 0, 10_000)
      send(parent, {:request_line, req |> String.split("\r\n") |> hd()})

      resp =
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
          "content-length: #{byte_size(@jsonp)}\r\nconnection: close\r\n\r\n" <> @jsonp

      :gen_tcp.send(sock, resp)
      :gen_tcp.close(sock)
    end)

    %{port: port}
  end

  test "parses the wrapper, drops url-less docs, dedupes, sanitizes the query", %{port: port} do
    urls =
      Sinestesia.LyricsImport.LetrasComBr.search("Bridge Over & Troubled / Water",
        search_url: "http://127.0.0.1:#{port}/"
      )

    assert urls == [
             "https://www.letras.mus.br/simon-e-garfunkel/36243/",
             "https://www.letras.mus.br/leona-lewis/1205062/"
           ]

    assert_receive {:request_line, line}, 5_000
    refute line =~ "%26", "the ampersand must be stripped before solr, not encoded into it"
    refute line =~ "&q="
    assert line =~ "Bridge"
  end
end
