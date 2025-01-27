defmodule NervesHubLink.HTTPFwupStream do
  @moduledoc """
  Download and install a firmware update.
  """

  use GenServer

  require Logger

  @redirect_status_codes [301, 302, 303, 307, 308]
  @httpc_profile __MODULE__

  @doc """
  Start the downloader process

  A `callback` process should be passed

  Messages will be received in the shape:

  * `{:fwup_message, message}` - see the docs for
    [Fwup](https://hexdocs.pm/fwup/) for more info.
  * `{:http_error, {status_code, body}}`
  * `{:http_error, :timeout}`
  * `{:http_error, :too_many_redirects}`
  """
  @spec start_link(pid()) :: GenServer.on_start()
  def start_link(cb) do
    GenServer.start_link(__MODULE__, [cb])
  end

  @spec start(pid()) :: GenServer.on_start()
  def start(cb) do
    GenServer.start(__MODULE__, [cb])
  end

  @doc """
  Stop the downloader
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(pid) do
    GenServer.stop(pid)
  end

  @doc """
  Download and install the firmware at the specified URL
  """
  @spec get(GenServer.server(), String.t()) :: :ok
  def get(pid, url) do
    GenServer.call(pid, {:get, url}, :infinity)
  end

  @impl GenServer
  def init([cb]) do
    _ = start_httpc()

    devpath = Nerves.Runtime.KV.get("nerves_fw_devpath") || "/dev/mmcblk0"
    args = ["--apply", "--no-unmount", "-d", devpath, "--task", "upgrade"]

    fwup_public_keys = NervesHubLink.Certificate.fwup_public_keys()

    if fwup_public_keys == [] do
      Logger.error("No fwup public keys were configured for nerves_hub_link.")
      Logger.error("This means that firmware signatures are not being checked.")
      Logger.error("nerves_hub won't allow this in the future.")
    end

    args =
      Enum.reduce(fwup_public_keys, args, fn public_key, args ->
        args ++ ["--public-key", public_key]
      end)

    {:ok, fwup} = Fwup.stream(cb, args)

    {:ok,
     %{
       url: nil,
       callback: cb,
       caller: nil,
       number_of_redirects: 0,
       timeout: 60_000,
       fwup: fwup
     }}
  end

  @impl GenServer
  def terminate(:normal, state) do
    GenServer.stop(state.fwup, :normal)
    :inets.stop(:httpc, @httpc_profile)
    :noop
  end

  @impl GenServer
  def terminate({:error, reason}, state) do
    state.caller && GenServer.reply(state.caller, reason)
    state.callback && send(state.callback, reason)
    GenServer.stop(state.fwup, :normal)
    :inets.stop(:httpc, @httpc_profile)
  end

  @impl GenServer
  def handle_call({:get, url}, from, s) do
    _ = make_request(url)

    {:noreply, %{s | url: url, caller: from}}
  end

  @impl GenServer
  def handle_info({:http, {_, :stream_start, headers}}, s) do
    Logger.debug("Stream Start: #{inspect(headers)}")

    {:noreply, s}
  end

  def handle_info({:http, {_, :stream, data}}, s) do
    Fwup.send_chunk(s.fwup, data)
    {:noreply, s, s.timeout}
  end

  def handle_info({:http, {_, :stream_end, _headers}}, s) do
    Logger.debug("Stream End")
    GenServer.reply(s.caller, :ok)
    {:noreply, %{s | url: nil}}
  end

  def handle_info({:http, {_ref, {{_, status_code, _}, headers, body}}}, s)
      when status_code in @redirect_status_codes do
    Logger.debug("Redirect")

    case get_header(headers, 'location') do
      nil ->
        {:stop, {:http_error, {status_code, body}}, s}

      next_url ->
        if s.number_of_redirects < 5 do
          _ = make_request(next_url)
          {:noreply, %{s | number_of_redirects: s.number_of_redirects + 1}}
        else
          {:stop, {:error, {:http_error, :too_many_redirects}}, s}
        end
    end
  end

  def handle_info({:http, {_ref, {{_, status_code, _}, _headers, body}}}, s) do
    Logger.error("Error: #{status_code} #{inspect(body)}")
    {:stop, {:error, {:http_error, {status_code, body}}}, s}
  end

  def handle_info({:http, {_ref, {:error, error}}}, state) do
    Logger.error("HTTP Stream Error: #{inspect(error)}")
    {:stop, {:error, {:http_error, error}}, state}
  end

  def handle_info(:timeout, s) do
    Logger.error("Error: timeout")
    {:stop, {:error, {:http_error, :timeout}}, s}
  end

  defp start_httpc() do
    :inets.start(:httpc, profile: @httpc_profile)

    # Only one download is attempted. There is no need
    # for multiple sessions, keeping the connection up
    # after completion, etc.
    httpc_opts = [
      max_sessions: 1,
      max_keep_alive_length: 1,
      keep_alive_timeout: 0
    ]

    :httpc.set_options(httpc_opts, @httpc_profile)
  end

  defp make_request(url) do
    headers = [
      {'Content-Type', 'application/octet-stream'}
    ]

    http_opts = [connect_timeout: 30_000, timeout: :infinity, autoredirect: false]
    opts = [stream: :self, receiver: self(), sync: false]

    :httpc.request(
      :get,
      {to_charlist(url), headers},
      http_opts,
      opts,
      @httpc_profile
    )
  end

  def get_header(headers, key) do
    Enum.find_value(headers, fn {k, v} -> k == key && v end)
  end
end
