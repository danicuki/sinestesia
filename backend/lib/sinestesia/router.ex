defmodule Sinestesia.Router do
  use Plug.Router

  plug(Plug.Logger, log: :debug)
  plug(:match)
  plug(:dispatch)

  get "/" do
    send_resp(conn, 200, "ok")
  end

  # What this box is actually running, right now. Same data as the boot banner,
  # for when the terminal has scrolled past it or the backend isn't yours.
  # Secrets report only whether they are set (see Sinestesia.Config.to_map/0).
  get "/config" do
    conn = fetch_query_params(conn)

    case conn.query_params["format"] do
      "text" ->
        conn
        |> put_resp_content_type("text/plain; charset=utf-8")
        |> send_resp(200, Sinestesia.Config.banner())

      _ ->
        conn
        |> put_resp_content_type("application/json; charset=utf-8")
        |> send_resp(200, Jason.encode!(Sinestesia.Config.to_map()))
    end
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
