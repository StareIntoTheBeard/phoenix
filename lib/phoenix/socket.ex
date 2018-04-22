defmodule Phoenix.Socket do
  # TODO: Rewrite docs

  @moduledoc ~S"""
  Defines a socket and its state.

  `Phoenix.Socket` is used as a module for establishing and maintaining
  the socket state via the `Phoenix.Socket` struct.

  Once connected to a socket, incoming and outgoing events are routed to
  channels. The incoming client data is routed to channels via transports.
  It is the responsibility of the socket to tie transports and channels
  together.

  By default, Phoenix supports both websockets and longpoll transports.
  For example:

      transport :websocket, Phoenix.Transports.WebSocket

  The command above means incoming socket connections can be made via
  the WebSocket transport. Events are routed by topic to channels:

      channel "room:lobby", MyApp.LobbyChannel

  See `Phoenix.Channel` for more information on channels. Check each
  transport module to find the options specific to each transport.

  ## Socket Behaviour

  Socket handlers are mounted in Endpoints and must define two callbacks:

    * `connect/2` - receives the socket params and authenticates the connection.
      Must return a `Phoenix.Socket` struct, often with custom assigns.
    * `id/1` - receives the socket returned by `connect/2` and returns the
      id of this connection as a string. The `id` is used to identify socket
      connections, often to a particular user, allowing us to force disconnections.
      For sockets requiring no authentication, `nil` can be returned.

  ## Examples

      defmodule MyApp.UserSocket do
        use Phoenix.Socket

        transport :websocket, Phoenix.Transports.WebSocket
        channel "room:*", MyApp.RoomChannel

        def connect(params, socket) do
          {:ok, assign(socket, :user_id, params["user_id"])}
        end

        def id(socket), do: "users_socket:#{socket.assigns.user_id}"
      end

      # Disconnect all user's socket connections and their multiplexed channels
      MyApp.Endpoint.broadcast("users_socket:" <> user.id, "disconnect", %{})

  ## Socket fields

    * `id` - The string id of the socket
    * `assigns` - The map of socket assigns, default: `%{}`
    * `channel` - The current channel module
    * `channel_pid` - The channel pid
    * `endpoint` - The endpoint module where this socket originated, for example: `MyApp.Endpoint`
    * `handler` - The socket module where this socket originated, for example: `MyApp.UserSocket`
    * `joined` - If the socket has effectively joined the channel
    * `join_ref` - The ref sent by the client when joining
    * `ref` - The latest ref sent by the client
    * `pubsub_server` - The registered name of the socket's pubsub server
    * `topic` - The string topic, for example `"room:123"`
    * `transport` - An identifier for the transport, used for logging
    * `transport_pid` - The pid of the socket's transport process
    * `serializer` - The serializer for socket messages

  ## Custom transports

  See the `Phoenix.Socket.Transport` documentation for more information on
  writing your own transports.
  """

  require Logger
  alias Phoenix.Socket
  alias Phoenix.Socket.{Broadcast, Message, Reply}

  @doc """
  Receives the socket params and authenticates the connection.

  ## Socket params and assigns

  Socket params are passed from the client and can
  be used to verify and authenticate a user. After
  verification, you can put default assigns into
  the socket that will be set for all channels, ie

      {:ok, assign(socket, :user_id, verified_user_id)}

  To deny connection, return `:error`.

  See `Phoenix.Token` documentation for examples in
  performing token verification on connect.
  """
  @callback connect(params :: map, Socket.t) :: {:ok, Socket.t} | :error

  @doc ~S"""
  Identifies the socket connection.

  Socket IDs are topics that allow you to identify all sockets for a given user:

      def id(socket), do: "users_socket:#{socket.assigns.user_id}"

  Would allow you to broadcast a "disconnect" event and terminate
  all active sockets and channels for a given user:

      MyApp.Endpoint.broadcast("users_socket:" <> user.id, "disconnect", %{})

  Returning `nil` makes this socket anonymous.
  """
  @callback id(Socket.t) :: String.t | nil

  defmodule InvalidMessageError do
    @moduledoc """
    Raised when the socket message is invalid.
    """
    defexception [:message]
  end

  defstruct assigns: %{},
            channel: nil,
            channel_pid: nil,
            endpoint: nil,
            handler: nil,
            id: nil,
            joined: false,
            join_ref: nil,
            private: %{},
            pubsub_server: nil,
            ref: nil,
            serializer: nil,
            topic: nil,
            transport: nil,
            transport_pid: nil

  @type t :: %Socket{
          assigns: map,
          channel: atom,
          channel_pid: pid,
          endpoint: atom,
          handler: atom,
          id: nil,
          joined: boolean,
          ref: term,
          private: %{},
          pubsub_server: atom,
          serializer: atom,
          topic: String.t,
          transport: atom,
          transport_pid: pid,
        }

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      ## User API

      import Phoenix.Socket
      @behaviour Phoenix.Socket
      @before_compile Phoenix.Socket
      Module.register_attribute(__MODULE__, :phoenix_channels, accumulate: true)
      @phoenix_transports %{}

      ## Callbacks

      @behaviour Phoenix.Socket.Transport

      @doc false
      def child_spec(_) do
        Phoenix.Socket.__child_spec__(__MODULE__, unquote(Macro.escape(opts)))
      end

      @doc false
      def connect(map), do: Phoenix.Socket.__connect__(__MODULE__, map)

      @doc false
      def init(state), do: Phoenix.Socket.__init__(state)

      @doc false
      def handle_in(message, state), do: Phoenix.Socket.__in__(message, state)

      @doc false
      def handle_info(message, state), do: Phoenix.Socket.__info__(message, state)

      @doc false
      def terminate(reason, state), do: Phoenix.Socket.__terminate__(reason, state)
    end
  end

  ## CALLBACKS IMPLEMENTATION

  def __child_spec__(handler, opts) do
    import Supervisor.Spec
    worker_opts = [shutdown: Keyword.get(opts, :shutdown, 5_000), restart: :temporary]
    worker = worker(Phoenix.Channel.Server, [], worker_opts)
    supervisor_opts = [strategy: :simple_one_for_one, name: handler]
    supervisor(Supervisor, [[worker], supervisor_opts], id: handler)
  end

  def __connect__(handler, map) do
    %{
      endpoint: endpoint,
      serializer: serializer,
      transport: transport,
      params: params
    } = map

    # The information in the Phoenix.Socket goes to userland and channels.
    socket = %Socket{
      handler: handler,
      endpoint: endpoint,
      pubsub_server: endpoint.__pubsub_server__,
      serializer: serializer,
      transport: transport
    }

    # The information in the state is kept only inside the socket process.
    state = %{
      channels: %{},
      channels_inverse: %{}
    }

    case handler.connect(params, socket) do
      {:ok, %Socket{} = socket} ->
        case handler.id(socket) do
          nil ->
            {:ok, {state, socket}}

          id when is_binary(id) ->
            {:ok, {state, %{socket | id: id}}}

          invalid ->
            Logger.error "#{inspect handler}.id/1 returned invalid identifier #{inspect invalid}. " <>
                         "Expected nil or a string."
            :error
        end

      :error ->
        :error

      invalid ->
        Logger.error "#{inspect handler}.connect/2 returned invalid value #{inspect invalid}. " <>
                     "Expected {:ok, socket} or :error"
        :error
    end
  end

  def __init__({state, %{id: id, endpoint: endpoint} = socket}) do
    _ = id && endpoint.subscribe(id, link: true)
    {:ok, {state, %{socket | transport_pid: self()}}}
  end

  def __in__({payload, opts}, {state, socket}) do
    %{topic: topic} = message = socket.serializer.decode!(payload, opts)
    handle_in(Map.get(state.channels, topic), message, state, socket)
  end

  def __info__({:DOWN, ref, _, pid, reason}, {state, socket}) do
    case state.channels_inverse do
      %{^pid => {topic, join_ref}} ->
        state = delete_channel(state, pid, topic, ref)
        {:reply, encode_on_exit(socket, topic, join_ref, reason), {state, socket}}

      %{} ->
        {:ok, {state, socket}}
    end
  end

  def __info__({:graceful_exit, pid, %Phoenix.Socket.Message{} = message}, {state, socket}) do
    state =
      case state.channels_inverse do
        %{^pid => {topic, _join_ref}} ->
          {^pid, monitor_ref} = Map.fetch!(state.channels, topic)
          delete_channel(state, pid, topic, monitor_ref)

        %{} ->
          state
      end

    {:reply, encode_reply(socket, message), {state, socket}}
  end

  def __info__(%Broadcast{event: "disconnect"}, state) do
    {:stop, state}
  end

  def __info__({:socket_push, opcode, payload}, state) do
    {:reply, {opcode, payload}, state}
  end

  def __info__(:garbage_collect, state) do
    :erlang.garbage_collect(self())
    {:ok, state}
  end

  def __info__(_, state) do
    {:ok, state}
  end

  def __terminate__(_reason, {%{channels_inverse: channels_inverse}, _socket}) do
    Phoenix.Channel.Server.close(Map.keys(channels_inverse))
    :ok
  end

  defp handle_in(_, %{ref: ref, topic: "phoenix", event: "heartbeat"}, state, socket) do
    reply = %Reply{
      ref: ref,
      topic: "phoenix",
      status: :ok,
      payload: %{}
    }

    {:reply, encode_reply(socket, reply), {state, socket}}
  end

  defp handle_in(nil, %{event: "phx_join", topic: topic, ref: ref} = message, state, socket) do
    case socket.handler.__channel__(topic) do
      {channel, opts} ->
        case Phoenix.Channel.Server.join(socket, channel, message, opts) do
          {:ok, reply, pid} ->
            reply = %Reply{join_ref: ref, ref: ref, topic: topic, status: :ok, payload: reply}
            state = put_channel(state, pid, topic, ref)
            {:reply, encode_reply(socket, reply), {state, socket}}

          {:error, reply} ->
            reply = %Reply{join_ref: ref, ref: ref, topic: topic, status: :error, payload: reply}
            {:reply, encode_reply(socket, reply), {state, socket}}
        end

      _ ->
        {:reply, encode_ignore(socket, message), {state, socket}}
    end
  end

  defp handle_in({pid, ref}, %{event: "phx_join", topic: topic} = message, state, socket) do
    Logger.debug fn ->
      "Duplicate channel join for topic \"#{topic}\" in #{inspect(socket.handler)}. " <>
        "Closing existing channel for new join."
    end

    :ok = Phoenix.Channel.Server.close([pid])
    handle_in(nil, message, delete_channel(state, pid, topic, ref), socket)
  end

  defp handle_in({pid, _ref}, message, state, socket) do
    send(pid, message)
    {:ok, {state, socket}}
  end

  defp handle_in(nil, message, state, socket) do
    {:reply, encode_ignore(socket, message), {state, socket}}
  end

  defp put_channel(state, pid, topic, join_ref) do
    %{channels: channels, channels_inverse: channels_inverse} = state
    monitor_ref = Process.monitor(pid)

    %{
      state |
        channels: Map.put(channels, topic, {pid, monitor_ref}),
        channels_inverse: Map.put(channels_inverse, pid, {topic, join_ref})
    }
  end

  defp delete_channel(state, pid, topic, monitor_ref) do
    %{channels: channels, channels_inverse: channels_inverse} = state
    Process.demonitor(monitor_ref, [:flush])

    %{
      state |
        channels: Map.delete(channels, topic),
        channels_inverse: Map.delete(channels_inverse, pid)
    }
  end

  defp encode_on_exit(socket, topic, ref, _reason) do
    message = %Message{join_ref: ref, ref: ref, topic: topic, event: "phx_error", payload: %{}}
    encode_reply(socket, message)
  end

  defp encode_ignore(%{handler: handler} = socket, %{ref: ref, topic: topic}) do
    Logger.warn fn -> "Ignoring unmatched topic \"#{topic}\" in #{inspect(handler)}" end
    reply = %Reply{ref: ref, topic: topic, status: :error, payload: %{reason: "unmatched topic"}}
    encode_reply(socket, reply)
  end

  defp encode_reply(%{serializer: serializer}, message) do
    case serializer.encode!(message) do
      # TODO: Deprecate or accept me
      {:socket_push, opcode, payload} ->
        {opcode, payload}

      {_opcode, _payload} = tuple ->
        tuple
    end
  end

  ## USER API

  defmacro __before_compile__(env) do
    transports = Module.get_attribute(env.module, :phoenix_transports)
    channels   = Module.get_attribute(env.module, :phoenix_channels)

    transport_defs =
      for {name, {mod, conf}} <- transports do
        quote do
          def __transport__(unquote(name)) do
            {unquote(mod), unquote(Macro.escape(conf))}
          end
        end
      end

    channel_defs =
      for {topic_pattern, module, opts} <- channels do
        topic_pattern
        |> to_topic_match()
        |> defchannel(module, opts)
      end

    quote do
      def __transports__, do: unquote(Macro.escape(transports))
      unquote(transport_defs)
      unquote(channel_defs)
      def __channel__(_topic, _transport), do: nil
    end
  end

  defp to_topic_match(topic_pattern) do
    case String.split(topic_pattern, "*") do
      [prefix, ""] -> quote do: <<unquote(prefix) <> _rest>>
      [bare_topic] -> bare_topic
      _            -> raise ArgumentError, "channels using splat patterns must end with *"
    end
  end

  defp defchannel(topic_match, channel_module, opts) do
    quote do
      def __channel__(unquote(topic_match)), do: unquote({channel_module, Macro.escape(opts)})
    end
  end

  @doc """
  Adds key/value pair to socket assigns.

  ## Examples

      iex> socket.assigns[:token]
      nil
      iex> socket = assign(socket, :token, "bar")
      iex> socket.assigns[:token]
      "bar"

  """
  def assign(socket = %Socket{}, key, value) do
    put_in socket.assigns[key], value
  end

  @doc """
  Defines a channel matching the given topic and transports.

    * `topic_pattern` - The string pattern, for example "room:*", "users:*", "system"
    * `module` - The channel module handler, for example `MyApp.RoomChannel`
    * `opts` - The optional list of options, see below

  ## Options

    * `:assigns` - the map of socket assigns to merge into the socket on join.

  ## Examples

      channel "topic1:*", MyChannel

  ## Topic Patterns

  The `channel` macro accepts topic patterns in two flavors. A splat argument
  can be provided as the last character to indicate a "topic:subtopic" match. If
  a plain string is provided, only that topic will match the channel handler.
  Most use-cases will use the "topic:*" pattern to allow more versatile topic
  scoping.

  See `Phoenix.Channel` for more information
  """
  defmacro channel(topic_pattern, module, opts \\ []) do
    # Tear the alias to simply store the root in the AST.
    # This will make Elixir unable to track the dependency
    # between endpoint <-> socket and avoid recompiling the
    # endpoint (alongside the whole project) whenever the
    # socket changes.
    module = tear_alias(module)

    quote do
      @phoenix_channels {unquote(topic_pattern), unquote(module), unquote(opts)}
    end
  end

  defp tear_alias({:__aliases__, meta, [h|t]}) do
    alias = {:__aliases__, meta, [h]}
    quote do
      Module.concat([unquote(alias)|unquote(t)])
    end
  end
  defp tear_alias(other), do: other

  # TODO: Deprecate custom transports

  @doc """
  Defines a transport with configuration.

  ## Examples

      # customize default `:websocket` transport options
      transport :websocket, Phoenix.Transports.WebSocket,
        timeout: 10_000

      # define separate transport, using websocket handler
      transport :websocket_slow_clients, Phoenix.Transports.WebSocket,
        timeout: 60_000

  """
  defmacro transport(name, module, config \\ []) do
    quote do
      @phoenix_transports Phoenix.Socket.__transport__(
        @phoenix_transports, unquote(name), unquote(module), unquote(config))
    end
  end

  @doc false
  def __transport__(transports, name, module, user_conf) do
    defaults = module.default_config()

    conf =
      user_conf
      |> normalize_serializer_conf(name, module, defaults[:serializer] || [])
      |> merge_defaults(defaults)

    Map.update(transports, name, {module, conf}, fn {dup_module, _} ->
      raise ArgumentError,
        "duplicate transports (#{inspect dup_module} and #{inspect module}) defined for #{inspect name}."
    end)
  end
  defp merge_defaults(conf, defaults), do: Keyword.merge(defaults, conf)

  defp normalize_serializer_conf(conf, name, transport_mod, default) do
    update_in(conf[:serializer], fn
      nil ->
        precompile_serializers(default)

      Phoenix.Transports.LongPollSerializer = serializer ->
        warn_serializer_deprecation(name, transport_mod, serializer)
        precompile_serializers(default)

      Phoenix.Transports.WebSocketSerializer = serializer ->
        warn_serializer_deprecation(name, transport_mod, serializer)
        precompile_serializers(default)

      [_ | _] = serializer ->
        precompile_serializers(serializer)

      serializer when is_atom(serializer) ->
        warn_serializer_deprecation(name, transport_mod, serializer)
        precompile_serializers([{serializer, "~> 1.0.0"}])
    end)
  end

  defp warn_serializer_deprecation(name, transport_mod, serializer) do
    IO.warn """
    passing a serializer module to the transport macro is deprecated.
    Use a list with version requirements instead. For example:

        transport :#{name}, #{inspect transport_mod},
          serializer: [{#{inspect serializer}, "~> 1.0.0"}]
    """
  end

  defp precompile_serializers(serializers) do
    for {module, requirement} <- serializers do
      case Version.parse_requirement(requirement) do
        {:ok, requirement} -> {module, requirement}
        :error -> Version.match?("1.0.0", requirement)
      end
    end
  end
end
