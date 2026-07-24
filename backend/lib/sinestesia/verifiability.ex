defmodule Sinestesia.Verifiability do
  @moduledoc """
  Holds the most recent verifiable-inference receipt from the 0G Compute
  sidecar so the pipeline can attach it to the next image message and the show
  can display, live, that the Director prompt was computed by a TEE-sealed model
  on the 0G Compute Network (not a stand-in).

  Last-write-wins: the Director runs one turn at a time per performance, so the
  latest receipt corresponds to the prompt currently being rendered. A receipt
  looks like:

      %{
        "provider" => "0xf07240…",
        "model"    => "llama-3.3-70b-instruct",
        "chatId"   => "chatcmpl-…",
        "verified" => true,          # TEE signature checked
        "network"  => "0g-compute"
      }
  """
  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> nil end, name: __MODULE__)
  end

  @doc """
  Store the latest receipt (a map from the sidecar's `verification` field).

  Crash-safe: the badge is cosmetic, so if the Agent is momentarily down
  (restarting) we never let that stall the Director on a live show.
  """
  def put(receipt) do
    if Process.whereis(__MODULE__), do: Agent.update(__MODULE__, fn _ -> receipt end)
    :ok
  end

  @doc "The most recent receipt, or nil if none / 0G not in use."
  def last do
    if Process.whereis(__MODULE__), do: Agent.get(__MODULE__, & &1)
  end
end
