defmodule Phoenix.PubSub.NatsConsumer do
  use GenServer
  alias Nats.Client
  alias Phoenix.PubSub.Nats
  require Logger

  def start_link(conn_pool, topic, pid, node_ref, link) do
    GenServer.start_link(__MODULE__, [conn_pool, topic, pid, node_ref, link])
  end

  def start(conn_pool, topic, pid, node_ref, link) do
    GenServer.start(__MODULE__, [conn_pool, topic, pid, node_ref, link])
  end

  def init([conn_pool, topic, pid, node_ref, link]) do
    Process.flag(:trap_exit, true)

    if link, do: Process.link(pid)

    case Nats.with_conn(conn_pool, fn conn ->
          ref = Client.sub(conn, self(), topic)
          Process.monitor(conn)
          {:ok, conn, ref}
        end) do
      {:ok, conn, ref} ->
        {:ok, %{conn: conn, pid: pid, sub_ref: ref, node_ref: node_ref}}
      {:error, :disconnected} ->
        {:stop, :disconnected}
    end
  end

  def stop(pid) do
    GenServer.call(pid, :stop)
  end

  def handle_call(:stop, _from, %{conn: conn, sub_ref: ref} = _state) do
    Client.unsub(conn, ref)
  end

  def handle_info({:msg, {_sid, _pid}, _subject, _reply, payload}, state) do
    {remote_node_ref, from_pid, msg} = :erlang.binary_to_term(payload)
    if from_pid == :none or remote_node_ref != state.node_ref or from_pid != state.pid do
      send(state.pid, msg)
    end
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, %{pid: pid} = state) do
    # Subscriber died. link: true
    {:stop, {:shutdown, reason}, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    {:stop, {:shutdown, reason}, state}
  end

  def terminate(_reason, state) do
    try do
      Client.unsub(state.conn, state.sub_ref)
    catch
      _, _ -> :ok
    end
  end

end
