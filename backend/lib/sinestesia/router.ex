defmodule Sinestesia.Router do
  use Plug.Router

  plug(Plug.Logger, log: :debug)
  plug(:match)
  plug(:dispatch)

  get "/" do
    send_resp(conn, 200, "ok")
  end

  get "/ws/audio" do
    conn
    |> WebSockAdapter.upgrade(Sinestesia.AudioSocket, %{}, timeout: 60_000)
    |> halt()
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
