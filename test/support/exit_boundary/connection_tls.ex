defmodule AshOnetime.Test.ExitBoundary.ConnectionTls do
  @moduledoc false
  alias AshOnetime.Test.ExitBoundary.Compiled
  alias AshOnetime.Test.ExitBoundary.NativeTransport

  @hello_retry_random <<207, 33, 173, 116, 229, 154, 97, 17, 190, 29, 140, 2, 30, 101, 184, 145,
                        194, 162, 17, 22, 122, 187, 140, 94, 7, 158, 9, 226, 200, 168, 51, 156>>

  # RFC 7919 constants from pinned OTP 29.1.2 ssl_dh_groups.
  @ffdhe_primes %{
    ffdhe2048:
      0xFFFFFFFFFFFFFFFFADF85458A2BB4A9AAFDC5620273D3CF1D8B9C583CE2D3695A9E13641146433FBCC939DCE249B3EF97D2FE363630C75D8F681B202AEC4617AD3DF1ED5D5FD65612433F51F5F066ED0856365553DED1AF3B557135E7F57C935984F0C70E0E68B77E2A689DAF3EFE8721DF158A136ADE73530ACCA4F483A797ABC0AB182B324FB61D108A94BB2C8E3FBB96ADAB760D7F4681D4F42A3DE394DF4AE56EDE76372BB190B07A7C8EE0A6D709E02FCE1CDF7E2ECC03404CD28342F619172FE9CE98583FF8E4F1232EEF28183C3FE3B1B4C6FAD733BB5FCBC2EC22005C58EF1837D1683B2C6F34A26C1B2EFFA886B423861285C97FFFFFFFFFFFFFFFF,
    ffdhe3072:
      0xFFFFFFFFFFFFFFFFADF85458A2BB4A9AAFDC5620273D3CF1D8B9C583CE2D3695A9E13641146433FBCC939DCE249B3EF97D2FE363630C75D8F681B202AEC4617AD3DF1ED5D5FD65612433F51F5F066ED0856365553DED1AF3B557135E7F57C935984F0C70E0E68B77E2A689DAF3EFE8721DF158A136ADE73530ACCA4F483A797ABC0AB182B324FB61D108A94BB2C8E3FBB96ADAB760D7F4681D4F42A3DE394DF4AE56EDE76372BB190B07A7C8EE0A6D709E02FCE1CDF7E2ECC03404CD28342F619172FE9CE98583FF8E4F1232EEF28183C3FE3B1B4C6FAD733BB5FCBC2EC22005C58EF1837D1683B2C6F34A26C1B2EFFA886B4238611FCFDCDE355B3B6519035BBC34F4DEF99C023861B46FC9D6E6C9077AD91D2691F7F7EE598CB0FAC186D91CAEFE130985139270B4130C93BC437944F4FD4452E2D74DD364F2E21E71F54BFF5CAE82AB9C9DF69EE86D2BC522363A0DABC521979B0DEADA1DBF9A42D5C4484E0ABCD06BFA53DDEF3C1B20EE3FD59D7C25E41D2B66C62E37FFFFFFFFFFFFFFFF,
    ffdhe4096:
      0xFFFFFFFFFFFFFFFFADF85458A2BB4A9AAFDC5620273D3CF1D8B9C583CE2D3695A9E13641146433FBCC939DCE249B3EF97D2FE363630C75D8F681B202AEC4617AD3DF1ED5D5FD65612433F51F5F066ED0856365553DED1AF3B557135E7F57C935984F0C70E0E68B77E2A689DAF3EFE8721DF158A136ADE73530ACCA4F483A797ABC0AB182B324FB61D108A94BB2C8E3FBB96ADAB760D7F4681D4F42A3DE394DF4AE56EDE76372BB190B07A7C8EE0A6D709E02FCE1CDF7E2ECC03404CD28342F619172FE9CE98583FF8E4F1232EEF28183C3FE3B1B4C6FAD733BB5FCBC2EC22005C58EF1837D1683B2C6F34A26C1B2EFFA886B4238611FCFDCDE355B3B6519035BBC34F4DEF99C023861B46FC9D6E6C9077AD91D2691F7F7EE598CB0FAC186D91CAEFE130985139270B4130C93BC437944F4FD4452E2D74DD364F2E21E71F54BFF5CAE82AB9C9DF69EE86D2BC522363A0DABC521979B0DEADA1DBF9A42D5C4484E0ABCD06BFA53DDEF3C1B20EE3FD59D7C25E41D2B669E1EF16E6F52C3164DF4FB7930E9E4E58857B6AC7D5F42D69F6D187763CF1D5503400487F55BA57E31CC7A7135C886EFB4318AED6A1E012D9E6832A907600A918130C46DC778F971AD0038092999A333CB8B7A1A1DB93D7140003C2A4ECEA9F98D0ACC0A8291CDCEC97DCF8EC9B55A7F88A46B4DB5A851F44182E1C68A007E5E655F6AFFFFFFFFFFFFFFFF,
    ffdhe6144:
      0xFFFFFFFFFFFFFFFFADF85458A2BB4A9AAFDC5620273D3CF1D8B9C583CE2D3695A9E13641146433FBCC939DCE249B3EF97D2FE363630C75D8F681B202AEC4617AD3DF1ED5D5FD65612433F51F5F066ED0856365553DED1AF3B557135E7F57C935984F0C70E0E68B77E2A689DAF3EFE8721DF158A136ADE73530ACCA4F483A797ABC0AB182B324FB61D108A94BB2C8E3FBB96ADAB760D7F4681D4F42A3DE394DF4AE56EDE76372BB190B07A7C8EE0A6D709E02FCE1CDF7E2ECC03404CD28342F619172FE9CE98583FF8E4F1232EEF28183C3FE3B1B4C6FAD733BB5FCBC2EC22005C58EF1837D1683B2C6F34A26C1B2EFFA886B4238611FCFDCDE355B3B6519035BBC34F4DEF99C023861B46FC9D6E6C9077AD91D2691F7F7EE598CB0FAC186D91CAEFE130985139270B4130C93BC437944F4FD4452E2D74DD364F2E21E71F54BFF5CAE82AB9C9DF69EE86D2BC522363A0DABC521979B0DEADA1DBF9A42D5C4484E0ABCD06BFA53DDEF3C1B20EE3FD59D7C25E41D2B669E1EF16E6F52C3164DF4FB7930E9E4E58857B6AC7D5F42D69F6D187763CF1D5503400487F55BA57E31CC7A7135C886EFB4318AED6A1E012D9E6832A907600A918130C46DC778F971AD0038092999A333CB8B7A1A1DB93D7140003C2A4ECEA9F98D0ACC0A8291CDCEC97DCF8EC9B55A7F88A46B4DB5A851F44182E1C68A007E5E0DD9020BFD64B645036C7A4E677D2C38532A3A23BA4442CAF53EA63BB454329B7624C8917BDD64B1C0FD4CB38E8C334C701C3ACDAD0657FCCFEC719B1F5C3E4E46041F388147FB4CFDB477A52471F7A9A96910B855322EDB6340D8A00EF092350511E30ABEC1FFF9E3A26E7FB29F8C183023C3587E38DA0077D9B4763E4E4B94B2BBC194C6651E77CAF992EEAAC0232A281BF6B3A739C1226116820AE8DB5847A67CBEF9C9091B462D538CD72B03746AE77F5E62292C311562A846505DC82DB854338AE49F5235C95B91178CCF2DD5CACEF403EC9D1810C6272B045B3B71F9DC6B80D63FDD4A8E9ADB1E6962A69526D43161C1A41D570D7938DAD4A40E329CD0E40E65FFFFFFFFFFFFFFFF,
    ffdhe8192:
      0xFFFFFFFFFFFFFFFFADF85458A2BB4A9AAFDC5620273D3CF1D8B9C583CE2D3695A9E13641146433FBCC939DCE249B3EF97D2FE363630C75D8F681B202AEC4617AD3DF1ED5D5FD65612433F51F5F066ED0856365553DED1AF3B557135E7F57C935984F0C70E0E68B77E2A689DAF3EFE8721DF158A136ADE73530ACCA4F483A797ABC0AB182B324FB61D108A94BB2C8E3FBB96ADAB760D7F4681D4F42A3DE394DF4AE56EDE76372BB190B07A7C8EE0A6D709E02FCE1CDF7E2ECC03404CD28342F619172FE9CE98583FF8E4F1232EEF28183C3FE3B1B4C6FAD733BB5FCBC2EC22005C58EF1837D1683B2C6F34A26C1B2EFFA886B4238611FCFDCDE355B3B6519035BBC34F4DEF99C023861B46FC9D6E6C9077AD91D2691F7F7EE598CB0FAC186D91CAEFE130985139270B4130C93BC437944F4FD4452E2D74DD364F2E21E71F54BFF5CAE82AB9C9DF69EE86D2BC522363A0DABC521979B0DEADA1DBF9A42D5C4484E0ABCD06BFA53DDEF3C1B20EE3FD59D7C25E41D2B669E1EF16E6F52C3164DF4FB7930E9E4E58857B6AC7D5F42D69F6D187763CF1D5503400487F55BA57E31CC7A7135C886EFB4318AED6A1E012D9E6832A907600A918130C46DC778F971AD0038092999A333CB8B7A1A1DB93D7140003C2A4ECEA9F98D0ACC0A8291CDCEC97DCF8EC9B55A7F88A46B4DB5A851F44182E1C68A007E5E0DD9020BFD64B645036C7A4E677D2C38532A3A23BA4442CAF53EA63BB454329B7624C8917BDD64B1C0FD4CB38E8C334C701C3ACDAD0657FCCFEC719B1F5C3E4E46041F388147FB4CFDB477A52471F7A9A96910B855322EDB6340D8A00EF092350511E30ABEC1FFF9E3A26E7FB29F8C183023C3587E38DA0077D9B4763E4E4B94B2BBC194C6651E77CAF992EEAAC0232A281BF6B3A739C1226116820AE8DB5847A67CBEF9C9091B462D538CD72B03746AE77F5E62292C311562A846505DC82DB854338AE49F5235C95B91178CCF2DD5CACEF403EC9D1810C6272B045B3B71F9DC6B80D63FDD4A8E9ADB1E6962A69526D43161C1A41D570D7938DAD4A40E329CCFF46AAA36AD004CF600C8381E425A31D951AE64FDB23FCEC9509D43687FEB69EDD1CC5E0B8CC3BDF64B10EF86B63142A3AB8829555B2F747C932665CB2C0F1CC01BD70229388839D2AF05E454504AC78B7582822846C0BA35C35F5C59160CC046FD8251541FC68C9C86B022BB7099876A460E7451A8A93109703FEE1C217E6C3826E52C51AA691E0E423CFC99E9E31650C1217B624816CDAD9A95F9D5B8019488D9C0A0A1FE3075A577E23183F81D4A3F2FA4571EFC8CE0BA8A4FE8B6855DFE72B0A66EDED2FBABFBE58A30FAFABE1C5D71A87E2F741EF8C1FE86FEA6BBFDE530677F0D97D11D49F7A8443D0822E506A9F4614E011E2A94838FF88CD68C8BB7C5C6424CFFFFFFFFFFFFFFFF
  }

  # Wire enumerations from RFC 8446 and the pinned OTP 29.1.2 headers.
  @handshake_groups %{
    23 => :secp256r1,
    24 => :secp384r1,
    25 => :secp521r1,
    29 => :x25519,
    30 => :x448,
    31 => :brainpoolP256r1tls13,
    32 => :brainpoolP384r1tls13,
    33 => :brainpoolP512r1tls13,
    256 => :ffdhe2048,
    257 => :ffdhe3072,
    258 => :ffdhe4096,
    259 => :ffdhe6144,
    260 => :ffdhe8192,
    512 => :mlkem512,
    513 => :mlkem768,
    514 => :mlkem1024,
    4587 => :secp256r1mlkem768,
    4588 => :x25519mlkem768,
    4589 => :secp384r1mlkem1024
  }

  @handshake_signatures %{
    513 => :rsa_pkcs1_sha1,
    515 => :ecdsa_sha1,
    1025 => :rsa_pkcs1_sha256,
    1027 => :ecdsa_secp256r1_sha256,
    1281 => :rsa_pkcs1_sha384,
    1283 => :ecdsa_secp384r1_sha384,
    1537 => :rsa_pkcs1_sha512,
    1539 => :ecdsa_secp521r1_sha512,
    2052 => :rsa_pss_rsae_sha256,
    2053 => :rsa_pss_rsae_sha384,
    2054 => :rsa_pss_rsae_sha512,
    2055 => :eddsa_ed25519,
    2056 => :eddsa_ed448,
    2057 => :rsa_pss_pss_sha256,
    2058 => :rsa_pss_pss_sha384,
    2059 => :rsa_pss_pss_sha512,
    2074 => :ecdsa_brainpoolP256r1tls13_sha256,
    2075 => :ecdsa_brainpoolP384r1tls13_sha384,
    2076 => :ecdsa_brainpoolP512r1tls13_sha512,
    2308 => :mldsa44,
    2309 => :mldsa65,
    2310 => :mldsa87,
    2321 => :slh_dsa_sha2_128s,
    2322 => :slh_dsa_sha2_128f,
    2323 => :slh_dsa_sha2_192s,
    2324 => :slh_dsa_sha2_192f,
    2325 => :slh_dsa_sha2_256s,
    2326 => :slh_dsa_sha2_256f,
    2327 => :slh_dsa_shake_128s,
    2328 => :slh_dsa_shake_128f,
    2329 => :slh_dsa_shake_192s,
    2330 => :slh_dsa_shake_192f,
    2331 => :slh_dsa_shake_256s,
    2332 => :slh_dsa_shake_256f
  }

  @handshake_curve_oids %{
    1 => {1, 3, 132, 0, 1},
    2 => {1, 3, 132, 0, 2},
    3 => {1, 3, 132, 0, 15},
    4 => {1, 3, 132, 0, 24},
    5 => {1, 3, 132, 0, 25},
    6 => {1, 3, 132, 0, 26},
    7 => {1, 3, 132, 0, 27},
    8 => {1, 3, 132, 0, 3},
    9 => {1, 3, 132, 0, 16},
    10 => {1, 3, 132, 0, 17},
    11 => {1, 3, 132, 0, 36},
    12 => {1, 3, 132, 0, 37},
    13 => {1, 3, 132, 0, 38},
    14 => {1, 3, 132, 0, 39},
    15 => {1, 3, 132, 0, 9},
    16 => {1, 3, 132, 0, 8},
    17 => {1, 3, 132, 0, 30},
    18 => {1, 3, 132, 0, 31},
    19 => {1, 2, 840, 10045, 3, 1, 1},
    20 => {1, 3, 132, 0, 32},
    21 => {1, 3, 132, 0, 33},
    22 => {1, 3, 132, 0, 10},
    23 => {1, 2, 840, 10045, 3, 1, 7},
    24 => {1, 3, 132, 0, 34},
    25 => {1, 3, 132, 0, 35},
    26 => {1, 3, 36, 3, 3, 2, 8, 1, 1, 7},
    27 => {1, 3, 36, 3, 3, 2, 8, 1, 1, 11},
    28 => {1, 3, 36, 3, 3, 2, 8, 1, 1, 13},
    29 => {1, 3, 101, 110},
    30 => {1, 3, 101, 111}
  }

  # Local formatter metadata must be frozen while a native owner mutant is
  # loaded. Its expected identity comes from that owner's independent BEAM.
  def freeze_debug(events, binding) do
    formatters =
      for %{event: {_, :call, {:sys, :handle_debug, [_, formatter, _, _]}}} <- events,
          is_function(formatter),
          do: formatter

    observations = Map.new(formatters, &{&1, formatter_observation(&1)})

    identity =
      if formatters != [], do: Compiled.identity(:gen_statem, :print_event, 3), else: nil

    binding
    |> Map.put(:debug_observations, observations)
    |> Map.put(:debug_formatter, {:compiled_formatter, identity, []})
  end

  defp formatter_observation(formatter) do
    info = Map.new(Function.info(formatter))

    if info.type == :local do
      identity = {info.module, info.name, info.arity, info.new_uniq, info.index}
      {:compiled_formatter, identity, info.env}
    else
      {:external_formatter, info.module, info.name, info.arity}
    end
  end

  # The SSL socket stays opaque. Match its public endpoint pair to the unique
  # live TCP port and retain the port's actual connected owner before observation.
  def bind(socket) do
    {:ok, local} = :ssl.sockname(socket)
    {:ok, peer} = :ssl.peername(socket)

    [port] =
      for port <- Port.list(),
          Port.info(port, :name) == {:name, ~c"tcp_inet"},
          :inet.sockname(port) == {:ok, local},
          :inet.peername(port) == {:ok, peer},
          do: port

    {:connected, owner} = Port.info(port, :connected)
    {:ok, [active: active]} = :inet.getopts(port, [:active])
    {:links, links} = Process.info(owner, :links)
    linked = process_origins(links)

    [supervisor] =
      for %{pid: pid, mfa: {:supervisor, :tls_dyn_connection_sup, 1}} <- linked, do: pid

    children = :supervisor.which_children(supervisor)
    {:receiver, ^owner, :worker, _modules} = List.keyfind(children, :receiver, 0)
    {:sender, sender, :worker, [:tls_sender]} = List.keyfind(children, :sender, 0)
    {states, machines} = machine_states([owner, sender])

    %{
      socket: socket,
      port: port,
      owner: owner,
      local: local,
      peer: peer,
      supervisor: supervisor,
      sender: sender,
      transport: %{port: port, active: active, owner: owner},
      states: states,
      machines: machines,
      processes: process_origins([owner, sender, supervisor])
    }
  end

  defp machine_states(pids) do
    session = :trace.session_create(:ash_onetime_tls_machine_history, self(), [])

    try do
      for mfa <- [{:gen_statem, :system_get_state, 1}, {:gen_statem, :system_continue, 3}] do
        :trace.function(session, mfa, [{:_, [], [{:exception_trace}]}], [:local])
      end

      for pid <- pids do
        1 = :trace.process(session, pid, true, [:call, :strict_monotonic_timestamp])
      end

      states = Map.new(pids, &{&1, :sys.get_state(&1)})
      fence = :trace.delivered(session, :all)

      receive do
        {:trace_delivered, :all, ^fence} -> :ok
      after
        5_000 -> raise "native TLS machine history fence did not arrive"
      end

      machines = Map.new(pids, &{&1, machine_origin(&1, Map.fetch!(states, &1))})
      {states, machines}
    after
      :trace.session_destroy(session)
    end
  end

  defp machine_origin(pid, public_state) do
    {params, state, stamp} =
      receive do
        {:trace_ts, ^pid, :call, {:gen_statem, :system_get_state, [{params, state}]}, stamp} ->
          {params, state, stamp}
      after
        0 -> raise "native TLS machine origin was not captured"
      end

    ^public_state = elem(state, 1)

    receive do
      {:trace_ts, ^pid, :return_from, {:gen_statem, :system_get_state, 1}, {:ok, ^public_state},
       returned}
      when returned > stamp ->
        receive do
          {:trace_ts, ^pid, :call,
           {:gen_statem, :system_continue, [_parent, debug, {^params, ^state}]}, continued}
          when continued > returned ->
            %{
              params: params,
              state: state,
              debug: debug,
              origin: {:historical_tls_machine, pid, stamp},
              debug_origin: {:historical_tls_debug, pid, continued}
            }
        after
          5_000 -> raise "native TLS machine debug origin was not captured"
        end
    after
      0 -> raise "native TLS machine public-state copy was not captured"
    end
  end

  defp process_origins(pids) do
    for pid <- Enum.uniq(pids), is_pid(pid) do
      mfa =
        case :proc_lib.translate_initial_call(pid) do
          {module, function, arity}
          when is_atom(module) and is_atom(function) and is_integer(arity) ->
            {module, function, arity}

          _ ->
            :unknown_initial_call
        end

      %{pid: pid, mfa: mfa}
    end
  end

  # Pool workers predate a caller's observation. Bind their public socket and
  # native machine roots before arming, and trace their actual callbacks as
  # persistent services rather than waiting for shared processes to exit.
  def pooled_services do
    sockets =
      for table <- :ets.all(),
          :ets.info(table, :name) == DBConnection.Holder,
          {:conn, _owner, Postgrex.Protocol, %{sock: {:ssl, socket}}, _, _, _, _} <-
            :ets.lookup(table, :conn),
          do: socket

    bindings = Enum.map(Enum.uniq(sockets), &bind/1)

    services =
      for binding <- bindings,
          {worker, pid} <- [receiver: binding.owner, sender: binding.sender],
          into: %{} do
        root = Map.fetch!(binding.machines, pid)
        :state_functions = elem(root.params, 1)
        [module | _] = elem(root.params, 4)
        {state, _data} = Map.fetch!(binding.states, pid)

        {{:tls_worker, binding.port, worker},
         %{
           kind: :state_machine,
           pid: pid,
           port: binding.port,
           owner: binding.owner,
           sender: binding.sender,
           worker: worker,
           callback: {module, state, 3}
         }}
      end

    %{bindings: bindings, services: services}
  end

  def validate(binding) do
    local = :ssl.sockname(binding.socket)
    peer = :ssl.peername(binding.socket)
    transport_local = :inet.sockname(binding.port)
    transport_peer = :inet.peername(binding.port)
    owner = Port.info(binding.port, :connected)
    local_matches? = local == transport_local and local == {:ok, binding.local}

    []
    |> mismatch(:tls_local_endpoint, local_matches?)
    |> mismatch(:tls_peer_endpoint, peer == transport_peer and peer == {:ok, binding.peer})
    |> mismatch(:tls_transport_owner, owner == {:connected, binding.owner})
    |> mismatch(:tls_connection_workers, connection_workers?(binding))
  end

  defp connection_workers?(binding) do
    children = :supervisor.which_children(binding.supervisor)

    match?(
      {:receiver, owner, :worker, _} when owner == binding.owner,
      List.keyfind(children, :receiver, 0)
    ) and List.keyfind(children, :sender, 0) == {:sender, binding.sender, :worker, [:tls_sender]}
  catch
    :exit, _reason -> false
  end

  # Born workers acquire their roots at their native entry, never at a later
  # system-state read. A public socket is a copy of this exact constructor.
  def births(indexed) do
    pairs = NativeTransport.pairs(indexed.events)

    connects =
      for {_index, pair} <- pairs,
          {_, :call, {:ssl, :connect, [port, _options, _timeout]}} <- [pair.source.event],
          is_port(port),
          {_, :return_from, _, {:ok, _socket}} <- [pair.returned.event],
          do: pair

    Enum.reduce(connects, %{bindings: [], errors: []}, fn connect, result ->
      case birth_binding(indexed.events, pairs, connect) do
        {:ok, binding} ->
          %{result | bindings: result.bindings ++ [binding]}

        :error ->
          error = %{
            index: connect.source.index,
            at: Map.take(connect.source, [:mfa, :role, :stack]),
            rule: :tls_birth_origin,
            actual: :unbound_constructor_chain,
            expected: :same_native_socket_workers_and_entries
          }

          %{result | errors: result.errors ++ [error]}
      end
    end)
  end

  defp birth_binding(events, pairs, connect) do
    {caller, :call, {:ssl, :connect, [port, _options, _timeout]}} = connect.source.event
    {_, :return_from, _, {:ok, socket}} = connect.returned.event
    interval = birth_calls(pairs, connect.source.index, connect.returned.index)

    with [tcp] <- Enum.filter(Map.values(pairs), &birth_tcp?(&1, caller, port)),
         true <- tcp.returned.index < connect.source.index,
         [constructed] <- Enum.filter(interval, &birth_socket?(&1, port, socket)),
         {receiver, :call,
          {:tls_socket, :socket,
           [[receiver, sender], :gen_tcp, ^port, :tls_gen_connection, table, _trackers]}} <-
           constructed.source.event,
         [created] <-
           Enum.filter(interval, &birth_constructor?(&1, receiver, sender, table, port)),
         {^receiver, :call,
          {constructor, :initial_state,
           [:client, ^sender, ^table, host, remote_port, ^port, options, ^caller, callbacks]}} <-
           created.source.event,
         {^receiver, :return_from, _, initial} <- created.returned.event,
         [table_origin] <- Enum.filter(interval, &birth_table?(&1, receiver, table)),
         true <- table_origin.returned.index < created.source.index,
         true <- created.source.index < constructed.source.index,
         true <- constructed.returned.index < created.returned.index,
         true <-
           birth_initial?(
             initial,
             {table, host, remote_port, port, options, callbacks, socket, sender}
           ),
         client = birth_client(options),
         true <- constructor == elem(client, 1),
         true <- birth_client_init?(events, created, elem(client, 0)),
         [configured] <- Enum.filter(interval, &birth_configuration?(&1, receiver, initial)),
         true <- created.returned.index < configured.source.index,
         [entry] <- birth_entries(events, receiver, elem(client, 0), :initial_hello),
         before_entry = Enum.filter(interval, &(&1.returned.index < entry.index)),
         {:ok, entered, initialization_origin} <-
           birth_client_state(before_entry, receiver, elem(client, 0), configured),
         true <- Enum.at(elem(elem(entry.event, 2), 2), 6) === entered,
         {^receiver, :call, {_, _, [supervisor | _]}} <- entry.event,
         true <- configured.returned.index < entry.index,
         [tree] <- Enum.filter(interval, &birth_supervisor?(&1, supervisor)),
         [sender_init] <- Enum.filter(interval, &(&1.source.mfa == {:tls_sender, :init, 1})),
         {^sender, :return_from, _, {:ok, :init, sender_data}} <- sender_init.returned.event,
         true <- sender_data === initial_sender_data(),
         [sender_entry] <- birth_entries(events, sender, :tls_sender, :init, sender_data),
         {^sender, :call, {_, _, [^supervisor | _]}} <- sender_entry.event,
         true <- sender_init.returned.index < sender_entry.index,
         true <-
           birth_spawn?(events, supervisor, receiver) and birth_spawn?(events, supervisor, sender),
         true <- tree.source.index < entry.index,
         [factory] <-
           Enum.filter(
             interval,
             &birth_factory?(&1, caller, host, remote_port, port, options, callbacks)
           ),
         true <-
           factory.source.index < created.source.index and entry.index < factory.returned.index,
         true <- birth_options?(interval, receiver, factory, options, created),
         {:ok, options_receipt} <-
           birth_options_receipt(events, tree, factory, receiver, supervisor),
         [handoff] <- Enum.filter(interval, &birth_handoff?(&1, caller, port, receiver)),
         true <- constructed.returned.index < handoff.source.index,
         {:ok, receiver_machine} <- birth_machine(interval, entry, elem(client, 0), entered),
         {:ok, sender_machine} <- birth_machine(interval, sender_entry, :tls_sender, sender_data) do
      {:ok,
       %{
         socket: socket,
         port: port,
         owner: receiver,
         sender: sender,
         supervisor: supervisor,
         upgrade_index: connect.source.index,
         transport: %{port: port, active: false, owner: receiver},
         states: %{receiver => {:initial_hello, entered}, sender => {:init, sender_data}},
         machines: %{receiver => receiver_machine, sender => sender_machine},
         initialization_origin: initialization_origin,
         receipts: [options_receipt.index],
         born?: true
       }}
    else
      _ -> :error
    end
  end

  defp birth_calls(pairs, first, last) do
    for {_index, pair} <- pairs,
        pair.source.index > first and pair.returned.index < last,
        do: pair
  end

  # OTP's sender init/1 constructs these constants before any receiver message.
  # Its checked return cannot choose the root used to validate later copies.
  defp initial_sender_data do
    environment = List.to_tuple([:env | List.duplicate(:undefined, 12)] ++ [0])
    {:data, environment, %{}, :undefined, :undefined}
  end

  defp birth_socket?(pair, port, socket) do
    match?(
      {_, :call, {:tls_socket, :socket, [[_, _], :gen_tcp, ^port, :tls_gen_connection, _, _]}},
      pair.source.event
    ) and match?({_, :return_from, _, ^socket}, pair.returned.event)
  end

  defp birth_tcp?(pair, caller, port) do
    case {pair.source.event, pair.returned.event} do
      {{^caller, :call, {:gen_tcp, :connect, [_, _, options, _]}},
       {^caller, :return_from, _, {:ok, ^port}}} ->
        Keyword.fetch(options, :active) == {:ok, false}

      _ ->
        false
    end
  end

  defp birth_constructor?(pair, receiver, sender, table, port) do
    pair.source.mfa in [
      {:tls_gen_connection_1_3, :initial_state, 9},
      {:tls_dtls_gen_connection, :initial_state, 9}
    ] and
      match?(
        {^receiver, :call, {_, _, [:client, ^sender, ^table, _, _, ^port, _, _, _]}},
        pair.source.event
      )
  end

  defp birth_table?(pair, receiver, table),
    do:
      pair.source.event == {receiver, :call, {:ets, :new, [:tls_socket, []]}} and
        pair.returned.event == {receiver, :return_from, {:ets, :new, 2}, table}

  defp birth_client(options) do
    if Map.fetch!(elem(options, 0), :versions) == [{3, 4}],
      do: {:tls_client_connection_1_3, :tls_gen_connection_1_3},
      else: {:tls_client_connection, :tls_dtls_gen_connection}
  end

  defp birth_initial?(
         initial,
         {table, host, remote_port, port, options, callbacks, socket, sender}
       )
       when is_tuple(initial) and tuple_size(initial) == 13 do
    environment = elem(initial, 2)

    Enum.all?(
      [
        {elem(initial, 0), :state},
        {elem(initial, 1), table},
        {elem(initial, 4), elem(options, 0)},
        {elem(initial, 5), elem(options, 1)},
        {elem(environment, 1), :client},
        {elem(environment, 2), socket},
        {elem(environment, 3), elem(callbacks, 0)},
        {elem(environment, 4), :tls_gen_connection},
        {elem(environment, 9), host},
        {elem(environment, 10), remote_port},
        {elem(environment, 11), port},
        {Map.fetch!(elem(initial, 7), :sender), sender}
      ],
      fn {actual, expected} -> actual === expected end
    )
  end

  defp birth_initial?(_initial, _context), do: false

  defp birth_client_init?(events, created, client) do
    {pid, :call, {_, _, arguments}} = created.source.event

    Enum.any?(events, fn source ->
      source.event == {pid, :call, {client, :init, [arguments]}} and
        source.index < created.source.index
    end)
  end

  defp birth_configuration?(pair, receiver, initial),
    do:
      pair.source.event ==
        {receiver, :call,
         {:ssl_gen_statem, :init_ssl_config, [elem(initial, 4), :client, initial]}}

  defp birth_client_state(_calls, _receiver, :tls_client_connection_1_3, configured) do
    {_, :return_from, _, state} = configured.returned.event
    {:ok, state, configured.returned.index}
  end

  defp birth_client_state(calls, receiver, :tls_client_connection, configured) do
    {_, :return_from, _, state} = configured.returned.event
    environment = elem(state, 2)
    alternatives = elem(elem(state, 3), 7)

    with [certificates] <-
           Enum.filter(
             calls,
             &(&1.source.event ==
                 {receiver, :call, {:ssl_certificate, :available_cert_key_pairs, [alternatives]}})
           ),
         {_, :return_from, _, certificate_pairs} <- certificates.returned.event,
         [selection] <-
           Enum.filter(calls, fn pair ->
             pair.source.event ==
               {receiver, :call,
                {:ssl_session, :client_select_session,
                 [
                   {elem(environment, 9), elem(environment, 10), elem(state, 4)},
                   elem(environment, 13),
                   elem(environment, 14),
                   elem(state, 8),
                   certificate_pairs
                 ]}}
           end),
         true <- configured.returned.index < certificates.source.index,
         true <- certificates.returned.index < selection.source.index,
         {_, :return_from, _, session} <- selection.returned.event do
      {:ok, put_elem(state, 8, session), selection.returned.index}
    else
      _ -> :error
    end
  end

  defp birth_entries(events, pid, module, name, data) do
    for %{
          event:
            {^pid, :call,
             {:gen_statem, :enter, [_, [], ^module, ^pid, :infinity, ^name, ^data, []]}}
        } = source <- events,
        do: source
  end

  defp birth_entries(events, pid, module, name) do
    for %{
          event:
            {^pid, :call, {:gen_statem, :enter, [_, [], ^module, ^pid, :infinity, ^name, _, []]}}
        } = source <- events,
        do: source
  end

  defp birth_supervisor?(pair, supervisor),
    do:
      pair.source.mfa == {:tls_dyn_connection_sup, :start_link, 2} and
        match?({_, :return_from, _, {:ok, ^supervisor}}, pair.returned.event)

  defp birth_spawn?(events, parent, child),
    do: Enum.any?(events, &match?(%{event: {^parent, :spawn, ^child, _}}, &1))

  defp birth_factory?(pair, caller, host, remote_port, port, options, callbacks) do
    case pair.source.event do
      {^caller, :call,
       {:tls_gen_connection, :start_fsm,
        [^host, ^remote_port, ^port, {ssl, _emulated, trackers}, ^caller, ^callbacks, _]}} ->
        ssl === elem(options, 0) and trackers === elem(options, 2)

      _ ->
        false
    end
  end

  defp birth_options?(calls, receiver, factory, options, created) do
    {_, :call, {_, _, [_, _, _, {_ssl, emulated, _trackers} | _]}} = factory.source.event
    initial = {:socket_options, :list, 0, 0, 0, true}
    expected = :tls_socket.emulated_socket_options(emulated, initial)

    case Enum.filter(calls, fn pair ->
           pair.source.event ==
             {receiver, :call, {:tls_socket, :emulated_socket_options, [emulated, initial]}} and
             factory.source.index < pair.source.index and
             pair.returned.index < created.source.index
         end) do
      [%{returned: %{event: {_, :return_from, _, ^expected}}}] ->
        elem(options, 1) === expected

      _ ->
        false
    end
  end

  defp birth_options_receipt(events, tree, factory, receiver, supervisor) do
    {caller, :call, {_, _, [host, port, socket, options, caller, callbacks, _timeout]}} =
      factory.source.event

    sender = tree.source.pid
    arguments = [:client, supervisor, host, port, socket, options, caller, callbacks]
    message = {sender, :options, arguments}

    sends = Enum.filter(events, &(&1.event == {sender, :send, message, receiver}))
    receives = Enum.filter(events, &(&1.event == {receiver, :receive, message}))

    with [sent] <- sends,
         [received] <- receives,
         [initial] <-
           Enum.filter(
             events,
             &(&1.event == {receiver, :call, {:ssl_gen_statem, :init, [sender]}})
           ),
         [initialized] <-
           Enum.filter(
             events,
             &(&1.event == {receiver, :call, {:ssl_gen_statem, :init_statem, [arguments]}})
           ),
         true <- sent.index < received.index,
         true <- initial.index < received.index and received.index < initialized.index do
      {:ok, received}
    else
      _ -> :error
    end
  end

  defp birth_handoff?(pair, caller, port, receiver),
    do:
      pair.source.event == {caller, :call, {:gen_tcp, :controlling_process, [port, receiver]}} and
        pair.returned.event == {caller, :return_from, {:gen_tcp, :controlling_process, 2}, :ok}

  defp birth_machine(calls, entry, module, data) do
    pid = entry.pid
    {^pid, :call, {_, _, [parent, [], ^module, ^pid, :infinity, name, ^data, []]}} = entry.event
    before = {:params, :state_functions, false, parent, [:gen_statem], pid, :infinity}

    params =
      {:params, :state_functions, module == :tls_client_connection_1_3, parent, [module], pid,
       :infinity}

    with [mode] <-
           Enum.filter(
             calls,
             &(&1.source.event ==
                 {pid, :call, {:gen_statem, :get_callback_mode, [before, [module]]}})
           ),
         true <- entry.index < mode.source.index,
         {^pid, :return_from, _, ^params} <- mode.returned.event do
      {:ok,
       %{
         params: params,
         state: {:state, {name, data}, [], %{}, [], false},
         debug: [],
         origin: {:tls_birth_machine, mode.returned.index},
         debug_origin: {:tls_birth_debug, entry.index},
         birth_index: mode.returned.index
       }}
    else
      _ -> :error
    end
  end

  # Only the public SSL send/recv arguments and returns are PostgreSQL bytes.
  # Encrypted port data never enters the framing or protocol association machine.
  # This ledger grants no event allowance; native interior/copy qualification and
  # the main comparator's consumption remain separate obligations.
  def build(indexed, binding) do
    bindings = if is_list(binding), do: binding, else: [binding]
    families = Enum.flat_map(bindings, &Map.get(&1, :families, [&1]))
    sockets = Map.new(bindings, &{&1.socket, &1})

    transport =
      Map.get_lazy(indexed, :native_transport, fn ->
        NativeTransport.build(indexed, %{}, Enum.map(families, & &1.transport))
      end)

    pairs = transport.pairs

    state =
      Enum.reduce(indexed.events, %{pairs: pairs, writes: [], reads: [], errors: []}, fn
        %{event: {_, :call, {:ssl, :send, [socket, data]}}} = source, state ->
          case Map.fetch(sockets, socket) do
            {:ok, binding} -> write(state, source, binding.port, IO.iodata_to_binary(data))
            :error -> tls_failure(state, source, :tls_socket_source)
          end

        %{event: {_, :call, {:ssl, :recv, [socket, length, timeout]}}} = source, state ->
          case Map.fetch(sockets, socket) do
            {:ok, binding} -> read(state, source, binding.port, length, timeout)
            :error -> tls_failure(state, source, :tls_socket_source)
          end

        %{event: {_, :call, {:ssl, function, _arguments}}} = source, state
        when function in [:send, :recv] ->
          tls_failure(state, source, :tls_socket_source)

        _, state ->
          state
      end)

    helper =
      Enum.reduce(families, %{terms: [], errors: []}, fn family, combined ->
        helper = sender_copies(indexed.events, pairs, family)
        %{terms: helper.terms ++ combined.terms, errors: helper.errors ++ combined.errors}
      end)

    binding =
      bindings
      |> hd()
      |> Map.put(:families, families)
      |> Map.put(
        :debug_observations,
        Enum.reduce(bindings, %{}, &Map.merge(&2, Map.get(&1, :debug_observations, %{})))
      )

    workers = worker_states(indexed.events, pairs, binding, helper.terms, transport)

    %{
      pairs: pairs,
      writes: Enum.reverse(state.writes),
      reads: Enum.reverse(state.reads),
      active: [],
      historical: %{},
      tls_bindings: bindings,
      transport: transport,
      terms: Enum.reverse(helper.terms) ++ Enum.reverse(workers.terms),
      errors:
        Enum.reverse(state.errors) ++
          transport.errors ++
          Enum.reverse(helper.errors) ++
          Enum.reverse(workers.errors)
    }
  end

  @worker_inputs %{
    {:tls_sender, :init, 3} => 2,
    {:tls_sender, :handshake, 3} => 2,
    {:tls_sender, :connection, 3} => 2,
    {:tls_sender, :async_wait, 3} => 2,
    {:tls_sender, :death_row, 3} => 2,
    {:tls_sender, :send_application_data, 4} => 3,
    {:tls_sender, :send_or_buffer, 5} => 4,
    {:tls_sender, :hibernate_after, 3} => 1,
    {:tls_sender, :send_tls_alert, 2} => 1,
    {:tls_sender, :handle_common, 4} => 3,
    {:tls_client_connection, :initial_hello, 3} => 2,
    {:tls_client_connection, :config_error, 3} => 2,
    {:tls_client_connection, :hello, 3} => 2,
    {:tls_client_connection, :user_hello, 3} => 2,
    {:tls_client_connection, :abbreviated, 3} => 2,
    {:tls_client_connection, :wait_stapling, 3} => 2,
    {:tls_client_connection, :certify, 3} => 2,
    {:tls_client_connection, :cipher, 3} => 2,
    {:tls_client_connection, :connection, 3} => 2,
    {:tls_client_connection, :downgrade, 3} => 2,
    {:tls_client_connection_1_3, :initial_hello, 3} => 2,
    {:tls_client_connection_1_3, :config_error, 3} => 2,
    {:tls_client_connection_1_3, :user_hello, 3} => 2,
    {:tls_client_connection_1_3, :start, 3} => 2,
    {:tls_client_connection_1_3, :wait_sh, 3} => 2,
    {:tls_client_connection_1_3, :hello_middlebox_assert, 3} => 2,
    {:tls_client_connection_1_3, :hello_retry_middlebox_assert, 3} => 2,
    {:tls_client_connection_1_3, :wait_ee, 3} => 2,
    {:tls_client_connection_1_3, :wait_cert_cr, 3} => 2,
    {:tls_client_connection_1_3, :wait_cert, 3} => 2,
    {:tls_client_connection_1_3, :wait_cv, 3} => 2,
    {:tls_client_connection_1_3, :wait_finished, 3} => 2,
    {:tls_client_connection_1_3, :connection, 3} => 2,
    {:tls_client_connection_1_3, :downgrade, 3} => 2,
    {:tls_gen_connection_1_3, :connection, 3} => 2,
    {:tls_gen_connection, :gen_info, 3} => 2,
    {:tls_gen_connection, :next_event, 3} => 2,
    {:tls_gen_connection, :next_event, 4} => 2,
    {:tls_gen_connection, :next_record, 2} => 1,
    {:tls_gen_connection, :next_record, 3} => 2,
    {:tls_gen_connection, :next_record, 5} => 0,
    {:tls_gen_connection, :next_record, 7} => 0,
    {:tls_gen_connection, :next_record_done, 4} => 0,
    {:tls_gen_connection, :handle_protocol_record, 3} => 2,
    {:ssl_gen_statem, :connection, 3} => 2,
    {:ssl_gen_statem, :handle_common_event, 4} => 3,
    {:ssl_gen_statem, :handle_info, 3} => 2,
    {:ssl_gen_statem, :passive_receive, 3} => 0,
    {:ssl_gen_statem, :read_application_data, 2} => 1,
    {:ssl_gen_statem, :hibernate_after, 3} => 1
  }
  @loop_state_functions [
    :loop,
    :loop_hibernate,
    :loop_wakeup,
    :loop_msg,
    :loop_msg_event,
    :loop_event,
    :loop_state_callback,
    :loop_state_callback_result,
    :loop_actions,
    :loop_actions_list,
    :loop_actions_reply,
    :loop_actions_next_event,
    :loop_state_enter,
    :loop_state_change,
    :loop_state_transition,
    :loop_keep_state,
    :loop_next_events,
    :loop_timeouts,
    :loop_timeouts_cancel,
    :loop_timeouts_register,
    :loop_timeouts_update,
    :loop_t0q,
    :loop_done
  ]
  @loop_next_functions [
    :loop_actions,
    :loop_actions_list,
    :loop_actions_reply,
    :loop_actions_next_event,
    :loop_state_enter,
    :loop_state_change,
    :loop_state_transition,
    :loop_keep_state,
    :loop_next_events,
    :loop_timeouts,
    :loop_timeouts_cancel,
    :loop_timeouts_register,
    :loop_timeouts_update
  ]

  defp pair_occurrences(pairs) do
    pairs
    |> Map.values()
    |> Enum.sort_by(& &1.source.index)
    |> Enum.group_by(&{&1.source.pid, &1.source.mfa})
  end

  # Native sys:get_state roots precede observation. Gen_statem retains its old
  # StateData while a callback's next StateData is carried separately; only
  # loop_done (or the stopping branch) commits that independently built version.
  defp worker_states(events, pairs, binding, covered, transport) do
    families = Map.get(binding, :families, [binding])

    owners =
      for family <- families,
          not Map.get(family, :born?, false),
          {pid, {name, data}} <- family.states,
          into: %{} do
        version = %{name: name, data: data, origin: {:historical_tls, pid}}
        {pid, %{version: version, family: family}}
      end

    initial = %{
      owners: owners,
      birth_candidates:
        families
        |> Enum.filter(&Map.get(&1, :born?, false))
        |> Enum.flat_map(&[&1.owner, &1.sender])
        |> MapSet.new(),
      born_workers: MapSet.new(),
      births:
        for(
          family <- families,
          Map.get(family, :born?, false),
          {pid, machine} <- family.machines,
          do: {machine.birth_index, {pid, family, machine}}
        )
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1)),
      pending: %{},
      frames: %{},
      received: %{},
      machine_queues: %{},
      machine_states: Map.new(owners, fn {pid, owner} -> {pid, owner.family.machines[pid]} end),
      machine_callbacks: %{},
      callback_results: %{},
      module_changes: %{},
      machine_zero: %{},
      machine_programs: %{},
      machine_debug: %{},
      debug_frames: %{},
      debug_required: %{},
      debug_observations: Map.get(binding, :debug_observations, %{}),
      debug_formatter: Map.get(binding, :debug_formatter, :missing_debug_formatter),
      direct_replies: %{},
      write_updates: %{},
      machine_received: %{},
      messages: %{},
      encoded: %{},
      parsed: %{},
      handshake_rest: %{},
      handshake_packets: %{},
      terms: [],
      errors: [],
      pairs: pairs,
      pair_index: pair_occurrences(pairs),
      transport: transport,
      events: events,
      records: %{},
      returns: Map.new(pairs, fn {index, pair} -> {pair.returned.index, index} end),
      covered: MapSet.new(covered, &{&1.index, &1.path})
    }

    receipts =
      (transport.writes ++ transport.reads ++ transport.options)
      |> Enum.flat_map(& &1.indexes)
      |> MapSet.new()
      |> MapSet.union(call_receipts(events, pairs))
      |> MapSet.union(MapSet.new(Enum.flat_map(families, &Map.get(&1, :receipts, []))))

    debug =
      Map.new(owners, fn {pid, owner} ->
        root = owner.family.machines[pid]

        {pid,
         %{value: expected_debug(root.debug, initial.debug_formatter), origin: root.debug_origin}}
      end)

    initial = initial |> Map.put(:receipts, receipts) |> Map.put(:machine_debug, debug)

    state = Enum.reduce(events, initial, &worker_owner_event/2)

    Enum.reduce(state.debug_required, state, fn {_pid, source}, state ->
      tls_failure(state, source, :tls_machine_debug_required)
    end)
  end

  defp worker_owner_event(source, state) do
    state = worker_spawn(source, state)

    state =
      Enum.reduce(Map.get(state.births, source.index, []), state, &worker_birth(&1, source, &2))

    cond do
      Map.has_key?(state.owners, source.pid) ->
        worker_event(source, state)

      elem(source.event, 1) == :receive and MapSet.member?(state.born_workers, source.pid) ->
        worker_event(source, state)

      true ->
        state
    end
  end

  defp worker_spawn(%{event: {_, :spawn, child, _}}, state) do
    if MapSet.member?(state.birth_candidates, child),
      do: %{state | born_workers: MapSet.put(state.born_workers, child)},
      else: state
  end

  defp worker_spawn(_source, state), do: state

  defp worker_birth({pid, family, machine}, source, state) do
    {name, data} = elem(machine.state, 1)
    version = %{name: name, data: data, origin: machine.origin}

    state =
      state
      |> put_in([:owners, pid], %{version: version, family: family})
      |> put_in([:machine_states, pid], machine)
      |> put_in([:machine_debug, pid], %{value: [], origin: machine.debug_origin})

    context =
      program_context(state, source, [{:internal, :init_state}], false, machine.birth_index)
      |> Map.put(:call_enter, true)
      |> Map.put(:actions, [{:postpone, false}])

    put_in(state.machine_programs[pid], context)
  end

  defp worker_event(%{event: {pid, :receive, message}} = source, state) do
    if MapSet.member?(state.receipts, source.index) do
      state
    else
      queue = Map.get(state.received, pid, :queue.new())
      put_in(state.received[pid], :queue.in(%{source: source, message: message}, queue))
    end
  end

  defp worker_event(%{event: {_, :call, {:gen_statem, function, arguments}}} = source, state),
    do: loop_copy(state, source, function, arguments)

  defp worker_event(%{event: {_, :call, {:sys, function, arguments}}} = source, state)
       when function in [:handle_debug, :nlog_put],
       do: debug_call(state, source, function, arguments)

  defp worker_event(%{event: {_, :call, {module, function, arguments}}} = source, state) do
    case Map.fetch(@worker_inputs, source.mfa) do
      {:ok, position} -> worker_call(state, source, arguments, position)
      :error -> record_call(state, source, module, function, arguments)
    end
  end

  defp worker_event(%{event: {_, :return_from, _, result}} = source, state),
    do:
      state
      |> debug_return(source)
      |> active_option_return(source)
      |> worker_return(source, result)

  defp worker_event(%{event: {_, :exception_from, _, _exception}} = source, state) do
    call = Map.get(state.returns, source.index)

    case Map.pop(state.records, call) do
      {%{kind: :handshake_exception, result: expected, input: input}, records} ->
        state
        |> Map.put(:records, records)
        |> handshake_copy(source, [3], expected, input.origin)

      {%{kind: :handshakes}, records} ->
        state
        |> Map.put(:records, records)
        |> tls_failure(source, :tls_handshake_copy)

      _ ->
        state
    end
  end

  defp worker_event(%{event: {pid, :exit, _reason}}, state) do
    state
    |> Map.update!(:handshake_rest, &Map.delete(&1, pid))
    |> Map.update!(:handshake_packets, &Map.delete(&1, pid))
    |> Map.update!(:module_changes, &Map.delete(&1, pid))
  end

  defp worker_event(_source, state), do: state

  defp loop_copy(state, source, function, arguments) do
    state = loop_commit(state, source.pid, function)
    state = machine_commit(state, source, function)
    version = state.owners[source.pid].version
    next = Map.get(state.pending, source.pid, version)

    state =
      state
      |> machine_metadata(source, function, arguments, version)
      |> loop_current_copy(source, function, version)
      |> loop_next_copy(source, function, version, next)
      |> loop_result_copy(source, function, arguments, next)

    state = if function == :loop_msg, do: loop_message(state, source, arguments), else: state
    machine_program(state, source, function, arguments)
  end

  # Temporary registers belong to the program that constructs them. The cursor
  # advances from the earlier message, callback return and native timer returns;
  # no checked helper argument is used to advance it.
  defp machine_program(state, source, function, arguments)
       when function in @loop_state_functions or
              function in [:reply_then_terminate, :do_reply_then_terminate, :terminate] do
    debug = Map.fetch!(state.machine_debug, source.pid)
    debug_position = if function in @loop_state_functions, do: 1, else: 4

    context = Map.get(state.machine_programs, source.pid)
    {state, context} = program_before(state, source, function, context)

    case program_fields(function, length(arguments), context, state, source) do
      {:ok, fields} ->
        fields = Enum.map(fields, fn {path, expected} -> {path, expected, context.origin} end)
        fields = [{debug_position, debug.value, debug.origin} | fields]

        state =
          fields
          |> Enum.sort_by(fn {path, _expected, _origin} -> List.wrap(path) end)
          |> Enum.reduce(state, fn {path, expected, origin}, state ->
            program_field(state, source, {path, expected, origin}, debug_position)
          end)

        state = require_debug(state, source, function, length(arguments), context)
        state = program_callback_result(state, source, function, context)
        {state, context} = program_after(state, source, function, length(arguments), context)
        put_in(state.machine_programs[source.pid], context)

      :error ->
        tls_failure(state, source, :tls_machine_program_origin)
    end
  end

  defp machine_program(state, source, :sys_debug, arguments),
    do: debug_call(state, source, :sys_debug, arguments)

  defp machine_program(state, source, :get_callback_mode, _arguments) do
    case state.machine_programs[source.pid] do
      %{module_action: %{before: before, modules: modules, result: result} = change} ->
        state
        |> program_term(source, [2, 2, 0], before, change.origin)
        |> program_term(source, [2, 2, 1], modules, change.origin)
        |> put_in([:records, source.index], %{
          kind: :callback_mode,
          result: result,
          change: change
        })

      _ ->
        tls_failure(state, source, :tls_callback_module_origin)
    end
  end

  defp machine_program(state, source, :terminate_sys_debug, _arguments) do
    root = state.owners[source.pid].family.machines[source.pid]
    context = Map.fetch!(state.machine_programs, source.pid)
    debug = Map.fetch!(state.machine_debug, source.pid)
    {_class, reason} = context.stop

    state
    |> program_term(source, [2, 2, 0], debug.value, debug.origin, &observed_debug(&1, state))
    |> program_term(source, [2, 2, 1], root.params, root.origin)
    |> program_term(source, [2, 2, 2], elem(context.data, 0), context.origin)
    |> program_term(source, [2, 2, 3], reason, context.origin)
    |> require_debug(source, :terminate_sys_debug, 4, context)
  end

  defp machine_program(state, source, :reply, _arguments) do
    action? =
      case source.stack do
        [{:gen_statem, function, _} | _] ->
          function in [:loop_actions_reply, :do_reply_then_terminate]

        _ ->
          false
      end

    expected =
      if action? do
        case state.machine_programs[source.pid] do
          %{reply: {from, reply}, origin: origin} -> {:ok, from, reply, origin}
          _ -> :error
        end
      else
        direct_reply(state, source)
      end

    case expected do
      {:ok, from, reply, origin} ->
        state
        |> program_term(source, [2, 2, 0], from, origin)
        |> program_term(source, [2, 2, 1], reply, origin)
        |> Map.update!(:direct_replies, &Map.delete(&1, source.pid))

      :error ->
        tls_failure(state, source, :tls_machine_program_reply_origin)
    end
  end

  defp machine_program(state, _source, _function, _arguments), do: state

  defp program_field(state, source, {path, expected, origin}, debug_position) do
    transform =
      if path == debug_position,
        do: &observed_debug(&1, state),
        else: &Function.identity/1

    program_term(state, source, [2, 2 | List.wrap(path)], expected, origin, transform)
  end

  defp debug_call(state, source, function, _arguments) do
    case debug_frame(state, source, function) do
      {:ok, frame} ->
        state = consume_debug(state, source, function)

        state =
          frame.arguments
          |> Enum.with_index()
          |> Enum.reduce(state, fn {expected, position}, state ->
            transform = debug_transform(frame.kind, position, state)

            program_term(
              state,
              source,
              [2, 2, position],
              expected,
              frame.origin,
              transform
            )
          end)

        frame = Map.put(frame, :mfa, source.mfa)
        frames = Map.get(state.debug_frames, source.pid, [])
        put_in(state.debug_frames[source.pid], [frame | frames])

      :error ->
        tls_failure(state, source, :tls_machine_debug_origin)
    end
  end

  defp require_debug(state, source, function, arity, context) do
    required? =
      function in [
        :loop_msg_event,
        :loop_actions_reply,
        :loop_actions_next_event,
        :loop_state_transition,
        :terminate_sys_debug
      ] or (function == :loop_timeouts_register and arity == 17) or
        (function == :do_reply_then_terminate and context.replies != [])

    if required? and state.machine_debug[source.pid].value != [] do
      state =
        case Map.get(state.debug_required, source.pid) do
          nil -> state
          previous -> tls_failure(state, previous, :tls_machine_debug_required)
        end

      put_in(state.debug_required[source.pid], source)
    else
      state
    end
  end

  defp consume_debug(state, source, :sys_debug) do
    parent = List.first(source.stack)

    case Map.get(state.debug_required, source.pid) do
      %{mfa: ^parent} ->
        Map.update!(state, :debug_required, &Map.delete(&1, source.pid))

      _ ->
        tls_failure(state, source, :tls_machine_debug_origin)
    end
  end

  defp consume_debug(state, _source, _function), do: state

  defp debug_frame(state, source, :sys_debug) do
    root = state.owners[source.pid].family.machines[source.pid]
    debug = Map.fetch!(state.machine_debug, source.pid)
    context = Map.get(state.machine_programs, source.pid)
    extra = elem(root.params, 5)

    with {:ok, event} <- debug_event(state, source, context),
         {:ok, result} <- advance_debug(debug.value, event, extra, state.debug_formatter) do
      {:ok,
       %{
         kind: :sys_debug,
         debug: debug.value,
         event: event,
         extra: extra,
         arguments: [debug.value, extra, event],
         result: result,
         origin: debug.origin
       }}
    end
  end

  defp debug_frame(state, source, :handle_debug) do
    with [parent | _] <- Map.get(state.debug_frames, source.pid, []),
         {:ok, debug} <- debug_tail(parent),
         {:ok, result} <- advance_debug(debug, parent.event, parent.extra, state.debug_formatter) do
      {:ok,
       %{
         parent
         | kind: :handle_debug,
           debug: debug,
           arguments: [debug, state.debug_formatter, parent.extra, parent.event],
           result: result
       }}
    else
      _ -> :error
    end
  end

  defp debug_frame(state, source, :nlog_put) do
    case Map.get(state.debug_frames, source.pid, []) do
      [%{kind: :handle_debug, debug: [{:log, log} | _]} = parent | _] ->
        item = {parent.event, parent.extra, state.debug_formatter}

        {:ok, %{parent | kind: :nlog_put, arguments: [item, log], result: advance_log(item, log)}}

      _ ->
        :error
    end
  end

  defp debug_tail(%{kind: :sys_debug, debug: debug}), do: {:ok, debug}
  defp debug_tail(%{kind: :handle_debug, debug: [_ | tail]}), do: {:ok, tail}
  defp debug_tail(_parent), do: :error

  defp debug_transform(:sys_debug, 0, state), do: &observed_debug(&1, state)
  defp debug_transform(:handle_debug, 0, state), do: &observed_debug(&1, state)

  defp debug_transform(:handle_debug, 1, state),
    do: &Map.get(state.debug_observations, &1, :unobserved_debug_formatter)

  defp debug_transform(:nlog_put, 0, state),
    do: &debug_item(&1, fn formatter -> Map.get(state.debug_observations, formatter) end)

  defp debug_transform(:nlog_put, 1, state),
    do: &debug_log(&1, fn formatter -> Map.get(state.debug_observations, formatter) end)

  defp debug_transform(_kind, _position, _state), do: &Function.identity/1

  defp debug_return(state, source) do
    case Map.get(state.debug_frames, source.pid, []) do
      [%{mfa: mfa} = frame | rest] when mfa == source.mfa ->
        transform =
          if frame.kind == :nlog_put,
            do: debug_transform(:nlog_put, 1, state),
            else: &observed_debug(&1, state)

        state = program_term(state, source, [3], frame.result, frame.origin, transform)
        state = put_in(state.debug_frames[source.pid], rest)

        if frame.kind == :sys_debug,
          do:
            put_in(state.machine_debug[source.pid], %{
              value: frame.result,
              origin: {:native_debug_return, source.index}
            }),
          else: state

      _ ->
        state
    end
  end

  defp debug_event(state, source, context) when is_map(context) do
    case List.first(source.stack) do
      {:gen_statem, :loop_msg_event, _} ->
        queue = Map.fetch!(state.machine_queues, source.pid)
        {:ok, {:in, hd(queue.events), state.owners[source.pid].version.name}}

      {:gen_statem, function, _}
      when function in [:loop_actions_reply, :do_reply_then_terminate] ->
        {from, reply} = context.reply
        {:ok, {:out, reply, from}}

      {:gen_statem, :loop_actions_next_event, _} ->
        {:ok, {:in, hd(context.next), elem(context.data, 0)}}

      {:gen_statem, :loop_state_transition, _} ->
        old_name = state.machine_states[source.pid].state |> elem(1) |> elem(0)
        kind = if context.postpone, do: :postpone, else: :consume
        {:ok, {kind, hd(context.q), old_name, elem(context.data, 0)}}

      {:gen_statem, :loop_timeouts_register, _} ->
        {:ok, {:start_timer, context.timeout, elem(context.data, 0)}}

      {:gen_statem, :terminate_sys_debug, _} ->
        {_class, reason} = context.stop
        {:ok, {:terminate, reason, elem(context.data, 0)}}

      _ ->
        :error
    end
  end

  defp debug_event(_state, _source, _context), do: :error

  defp expected_debug(debug, formatter), do: map_debug(debug, fn _actual -> formatter end)

  defp observed_debug(debug, state),
    do: map_debug(debug, &Map.get(state.debug_observations, &1, :unobserved_debug_formatter))

  defp map_debug(debug, formatter) when is_list(debug) do
    Enum.map(debug, fn
      {:log, log} -> {:log, debug_log(log, formatter)}
      option -> option
    end)
  end

  defp map_debug(debug, _formatter), do: debug

  defp debug_log([reverse | forward], formatter) when is_list(reverse),
    do: [
      Enum.map(reverse, &debug_item(&1, formatter))
      | Enum.map(forward, &debug_item(&1, formatter))
    ]

  defp debug_log([remaining | reverse], formatter) when is_integer(remaining),
    do: [remaining | Enum.map(reverse, &debug_item(&1, formatter))]

  defp debug_log(log, _formatter), do: log
  defp debug_item({event, extra, fun}, formatter), do: {event, extra, formatter.(fun)}
  defp debug_item(item, _formatter), do: item

  defp advance_debug(debug, event, extra, formatter) do
    Enum.reduce_while(debug, {:ok, []}, fn
      {:log, log}, {:ok, result} ->
        {:cont, {:ok, result ++ [{:log, advance_log({event, extra, formatter}, log)}]}}

      _option, _result ->
        {:halt, :error}
    end)
  end

  # OTP's ring representation has a filling countdown, then reverse/forward
  # queues. Preserve its exact representation as well as every retained entry.
  defp advance_log(item, [reverse | [_oldest | forward]]) when is_list(reverse),
    do: [[item | reverse] | forward]

  defp advance_log(item, [reverse]) when is_list(reverse) do
    [_oldest | forward] = Enum.reverse(reverse, [item])
    [[] | forward]
  end

  defp advance_log(item, [1 | reverse]), do: [[item | reverse]]
  defp advance_log(item, [remaining | reverse]), do: [remaining - 1, item | reverse]

  defp direct_reply(state, source) do
    case state.direct_replies[source.pid] do
      %{from: from, reply: reply, origin: origin, last: last} when source.index < last ->
        {:ok, from, reply, origin}

      _ ->
        receiver_reply(state, source)
    end
  end

  defp receiver_reply(state, source) do
    with [frame | _] <- Map.get(state.frames, source.pid, []),
         {:ok, version, plaintext} <- receiver_buffer(state, source.pid, frame),
         {:socket_options, :binary, packet, _max_packet, 0, false} <- elem(version.data, 5),
         true <- packet in [0, :raw],
         recv <- elem(version.data, 9),
         from <- elem(recv, 1),
         required <- elem(recv, 2),
         true <- from != :undefined and is_integer(required) and required >= 0,
         {front, size, rear} <- elem(version.data, 12),
         true <- size + byte_size(plaintext) > 0 do
      {front, rear, bytes} = queued_binary(front, [plaintext | rear])
      count = if required == 0, do: byte_size(bytes), else: required
      available = IO.iodata_to_binary([bytes, front, Enum.reverse(rear)])

      if count <= byte_size(available),
        do: {:ok, from, {:ok, binary_part(available, 0, count)}, version.origin},
        else: :error
    else
      _ -> :error
    end
  end

  defp receiver_buffer(
         state,
         pid,
         %{source: %{mfa: {:ssl_gen_statem, :read_application_data, 2}}, input: version}
       ) do
    case Map.get(state.parsed, pid) do
      nil -> :error
      parsed -> application_record_buffer(parsed, version)
    end
  end

  # passive_receive/3 calls the private four-argument reader directly. It
  # consumes the independently modeled queue without adding decrypted bytes.
  defp receiver_buffer(
         _state,
         _pid,
         %{source: %{mfa: {:ssl_gen_statem, :passive_receive, 3}}, input: version}
       ),
       do: {:ok, version, <<>>}

  defp receiver_buffer(_state, _pid, _frame), do: :error

  defp program_before(state, source, :loop_event, _context) do
    queue = state.machine_queues[source.pid]
    {state, program_context(state, source, queue.events, queue.hibernate, queue.origin)}
  end

  defp program_before(state, source, :loop_msg, nil),
    do: {state, program_context(state, source, [], false, source.index)}

  defp program_before(state, source, :loop_state_callback_result, context) when is_map(context) do
    case state.machine_callbacks[source.pid] do
      %{source: callback, result: result} ->
        {state, %{context | result: result, timer_index: callback.index, origin: callback.index}}

      _ ->
        {tls_failure(state, source, :tls_machine_program_callback_origin), context}
    end
  end

  defp program_before(state, source, function, context)
       when function in [:loop_next_events, :loop_timeouts] and is_map(context) do
    {state, context} = program_cancellations(state, source, context)
    program_pending_timer(state, source, context)
  end

  defp program_before(state, source, :loop_timeouts_register, context) when is_map(context) do
    case context.timeout_ref do
      nil ->
        {type, time, _message, options} = context.timeout
        function = if time == 0, do: :make_ref, else: :start_timer
        arguments = if time == 0, do: [], else: [time, source.pid, type, options]
        {state, ref, context} = program_timer_return(state, source, context, function, arguments)
        zero = if time == 0, do: [{type, ref} | context.zero], else: context.zero
        {state, %{context | timeout_ref: ref, zero: zero}}

      _ref ->
        {state, context}
    end
  end

  defp program_before(state, _source, _function, context), do: {state, context}

  defp program_context(state, source, events, hibernate, origin) do
    root = state.machine_states[source.pid]

    %{
      origin: origin,
      q: events,
      events: [],
      data: elem(root.state, 1),
      callback_event: List.first(events),
      next: [],
      hibernate: hibernate,
      timeouts: [],
      postpone: false,
      call_enter: false,
      state_call: true,
      actions: [],
      action: nil,
      reply: nil,
      result: nil,
      timers: elem(root.state, 3),
      postponed: elem(root.state, 2),
      seen: %{},
      zero: [],
      timeout: nil,
      timeout_ref: nil,
      timer_index: source.index,
      pending_timer: nil,
      cancels: [],
      stop: nil,
      replies: [],
      module_action: nil
    }
  end

  defp program_fields(function, arity, _context, _state, _source)
       when {function, arity} in [
              {:loop, 3},
              {:loop_hibernate, 3},
              {:loop_wakeup, 3},
              {:loop_msg, 4},
              {:loop_msg_event, 4},
              {:loop_msg_event, 5},
              {:loop_event, 5},
              {:loop_t0q, 5}
            ],
       do: {:ok, []}

  defp program_fields(:loop_state_callback, 7, context, _state, _source) when is_map(context),
    do:
      {:ok,
       [
         {3, context.q},
         {[4, 0], elem(context.data, 0)},
         {5, context.callback_event},
         {6, context.hibernate}
       ]}

  defp program_fields(function, 11, context, _state, _source)
       when function in [:loop_state_callback, :loop_state_callback_result] and is_map(context) do
    fields = program_prefix(context, context.q, context.postpone)
    fields = fields ++ [{9, context.state_call}]

    if function == :loop_state_callback,
      do: {:ok, fields ++ [{10, context.callback_event}]},
      else: {:ok, fields}
  end

  defp program_fields(:loop_actions, 10, context, _state, _source) when is_map(context),
    do: {:ok, program_prefix(context, context.q, context.postpone) ++ [{9, context.call_enter}]}

  defp program_fields(function, arity, context, _state, _source)
       when function in [
              :loop_actions,
              :loop_actions_list,
              :loop_actions_reply,
              :loop_actions_next_event
            ] and
              arity in [12, 13, 14] and is_map(context) do
    base =
      program_prefix(context, context.q, context.postpone) ++
        [{9, context.call_enter}, {10, context.state_call}, {11, context.actions}]

    case program_action_fields(function, arity, context) do
      :error -> :error
      fields -> {:ok, base ++ fields}
    end
  end

  defp program_fields(function, arity, context, _state, _source)
       when function in [
              :loop_state_enter,
              :loop_state_transition,
              :loop_keep_state,
              :loop_state_change
            ] and
              arity in [8, 9] and is_map(context) do
    events =
      if function in [:loop_state_enter, :loop_state_transition],
        do: context.q,
        else: context.events

    final =
      if function in [:loop_state_enter, :loop_state_transition],
        do: context.postpone,
        else: context.postponed

    fields = program_prefix(context, events, final)

    if arity == 8,
      do: {:ok, Enum.reject(fields, fn {path, _} -> path == 8 end)},
      else: {:ok, fields}
  end

  defp program_fields(:loop_next_events, 10, context, _state, _source) when is_map(context),
    do: {:ok, program_prefix(context, context.events, context.postponed) ++ [{9, context.timers}]}

  defp program_fields(function, arity, context, _state, _source)
       when function in [
              :loop_timeouts,
              :loop_timeouts_register,
              :loop_timeouts_cancel,
              :loop_timeouts_update
            ] and
              is_map(context) do
    base =
      program_prefix(context, context.events, context.postponed) ++
        [{9, context.timers}, {10, context.seen}, {11, context.zero}]

    extra = program_timeout_fields(function, arity, context)

    if extra == :error, do: :error, else: {:ok, base ++ extra}
  end

  defp program_fields(:loop_done, 5, context, _state, _source) when is_map(context),
    do: {:ok, [{3, context.events}, {4, context.next}]}

  defp program_fields(:loop_done, 4, context, _state, _source) when is_map(context),
    do: {:ok, [{3, context.q}]}

  defp program_fields(function, arity, context, state, source)
       when function in [:reply_then_terminate, :do_reply_then_terminate, :terminate] and
              is_map(context) do
    case program_stop(state, source, context) do
      {:ok, class, reason, stack, replies, q} ->
        fields = [{0, class}, {1, reason}, {2, stack}, {6, q}]
        if arity == 8, do: {:ok, fields ++ [{7, replies}]}, else: {:ok, fields}

      :error ->
        :error
    end
  end

  defp program_fields(_function, _arity, _context, _state, _source), do: :error

  defp program_action_fields(:loop_actions_list, 13, context), do: [{12, context.action}]

  defp program_action_fields(:loop_actions_reply, 14, %{reply: {from, reply}}),
    do: [{12, from}, {13, reply}]

  defp program_action_fields(:loop_actions_next_event, 14, %{action: {:next_event, type, content}}),
       do: [{12, type}, {13, content}]

  defp program_action_fields(function, 12, _context)
       when function in [:loop_actions, :loop_actions_list],
       do: []

  defp program_action_fields(_function, _arity, _context), do: :error

  defp program_timeout_fields(:loop_timeouts, 12, _context), do: []

  defp program_timeout_fields(:loop_timeouts, 16, %{timeout: {type, time, message, options}}),
    do: [{12, type}, {13, time}, {14, message}, {15, options}]

  defp program_timeout_fields(:loop_timeouts_register, 17, context) do
    {type, time, message, options} = context.timeout
    [{12, type}, {13, time}, {14, message}, {15, options}, {16, context.timeout_ref}]
  end

  defp program_timeout_fields(:loop_timeouts_register, 15, context) do
    {type, _time, message, _options} = context.timeout
    [{12, type}, {13, context.timeout_ref}, {14, message}]
  end

  defp program_timeout_fields(:loop_timeouts_cancel, 13, %{timeout: {type, _, _, _}}),
    do: [{12, type}]

  defp program_timeout_fields(:loop_timeouts_update, 14, %{timeout: {type, _, message, _}}),
    do: [{12, type}, {13, message}]

  defp program_timeout_fields(_function, _arity, _context), do: :error

  defp program_prefix(context, events, postponed),
    do: [
      {3, events},
      {[4, 0], elem(context.data, 0)},
      {5, context.next},
      {6, context.hibernate},
      {7, context.timeouts},
      {8, postponed}
    ]

  defp program_callback_result(state, source, :loop_state_callback_result, context) do
    actual = native_term(source.event, [2, 2, 10])
    callback = Map.fetch!(state.machine_callbacks, source.pid)
    {_, :return_from, _, returned} = callback.source.event

    # This argument is a copy of the preceding native return. Its constructor
    # is checked at that return; context.result independently drives the
    # expected transition, actions and subsequent machine state.
    case {actual, returned, result_data_path(returned)} do
      {actual, expected, [data]}
      when is_tuple(actual) and is_tuple(expected) and
             tuple_size(actual) == tuple_size(expected) and elem(actual, 0) == elem(expected, 0) ->
        Enum.reduce(0..(tuple_size(expected) - 1), state, fn
          ^data, state ->
            state

          position, state ->
            program_term(
              state,
              source,
              [2, 2, 10, position],
              elem(expected, position),
              context.origin
            )
        end)

      _ ->
        program_term(state, source, [2, 2, 10], returned, context.origin)
    end
  end

  defp program_callback_result(state, _source, _function, _context), do: state

  defp program_after(state, source, :loop_state_callback_result, _arity, context) do
    {name, data} = context.data

    case transition_result(context.result, name, data) do
      {:ok, next_name, next_data, _actions} ->
        repeat? =
          elem_if_tuple(context.result, 0) in [:repeat_state, :repeat_state_and_data] or
            context.result == :repeat_state_and_data

        context = %{
          context
          | data: {next_name, next_data},
            actions: program_actions(context.result),
            call_enter: repeat? or next_name !== name
        }

        {state, context}

      :error ->
        case program_stop_result(context.result, context) do
          {:ok, context} -> {state, context}
          :error -> {tls_failure(state, source, :tls_machine_program_result_origin), context}
        end
    end
  end

  # OTP inlines loop_state_enter/9 into loop_actions/10. Its decision comes
  # from the modeled CallEnter and current Params, before the callback inputs.
  defp program_after(state, source, function, arity, context)
       when {function, arity} in [{:loop_state_enter, 9}, {:loop_actions, 10}] do
    root = state.machine_states[source.pid]

    if function == :loop_state_enter or (context.call_enter and elem(root.params, 2)) do
      previous = root.state |> elem(1) |> elem(0)
      event = {:enter, previous}
      state = put_in(state.messages[source.pid], %{value: event, origin: context.origin})
      {state, %{context | state_call: false, callback_event: event}}
    else
      {state, context}
    end
  end

  defp program_after(state, _source, :loop_actions, 12, context),
    do: {state, %{context | actions: native_list(context.actions)}}

  defp program_after(state, source, :loop_msg, _arity, context) do
    parent = elem(state.owners[source.pid].family.machines[source.pid].params, 3)

    case state.machine_received[source.pid] do
      %{value: {:EXIT, ^parent, reason}, origin: origin} ->
        {state, %{context | stop: {:exit, reason}, q: [], origin: origin}}

      _ ->
        {state, context}
    end
  end

  defp program_after(state, source, :loop_actions_list, 12, %{actions: [action | rest]} = context) do
    context = %{context | actions: rest, action: action}

    case action do
      :hibernate ->
        {state, %{context | hibernate: true}}

      {:hibernate, value} when is_boolean(value) ->
        {state, %{context | hibernate: value}}

      :postpone ->
        {state, %{context | postpone: true}}

      {:postpone, value} when is_boolean(value) ->
        {state, %{context | postpone: value}}

      {:reply, from, reply} ->
        {state, %{context | reply: {from, reply}}}

      {:next_event, _type, _content} ->
        {state, context}

      {:change_callback_module, module} when is_atom(module) ->
        program_callback_module(state, source, context, module)

      _ ->
        program_timeout_action(state, source, context, action)
    end
  end

  defp program_after(state, source, :loop_actions_list, 13, context) do
    case timeout_action(context.action) do
      {:ok, timeout} -> {state, %{context | timeouts: [timeout | context.timeouts]}}
      :error -> {tls_failure(state, source, :tls_machine_program_timeout_origin), context}
    end
  end

  defp program_after(state, _source, :loop_actions_next_event, 14, context) do
    {:next_event, type, content} = context.action
    {state, %{context | next: [{type, content} | context.next]}}
  end

  defp program_after(state, source, :loop_state_transition, 9, context) do
    [event | events] = context.q
    root = state.machine_states[source.pid]
    postponed = if context.postpone, do: [event | elem(root.state, 2)], else: elem(root.state, 2)
    {state, %{context | events: events, postponed: postponed}}
  end

  defp program_after(state, _source, :loop_keep_state, 9, context),
    do: {state, %{context | cancels: [:timeout]}}

  defp program_after(state, _source, :loop_state_change, 9, context),
    do:
      {state,
       %{context | events: Enum.reverse(context.postponed) ++ context.events, postponed: []}}

  defp program_after(state, _source, :loop_state_change, 8, context),
    do: {state, %{context | cancels: [:state_timeout, :timeout]}}

  defp program_after(state, _source, :loop_timeouts, 12, %{timeouts: [timeout | rest]} = context) do
    type = elem(timeout, 0)
    context = %{context | timeouts: rest}

    if Map.has_key?(context.seen, type),
      do: {state, context},
      else: {state, %{context | timeout: timeout_tuple(timeout), timeout_ref: nil}}
  end

  defp program_after(state, _source, :loop_timeouts_register, 15, context),
    do: {state, %{context | pending_timer: :register}}

  defp program_after(state, _source, :loop_timeouts_cancel, 13, context),
    do: {state, %{context | pending_timer: :cancel}}

  defp program_after(state, _source, :loop_timeouts_update, 14, context),
    do: {state, %{context | pending_timer: :update}}

  defp program_after(state, _source, :loop_done, 5, context),
    do: {state, %{context | q: Enum.reverse(context.next) ++ context.events}}

  defp program_after(state, _source, :reply_then_terminate, 8, context),
    do: {state, %{context | replies: native_list(context.replies)}}

  defp program_after(
         state,
         _source,
         :do_reply_then_terminate,
         8,
         %{replies: [{:reply, from, reply} | rest]} = context
       ),
       do: {state, %{context | reply: {from, reply}, replies: rest}}

  defp program_after(state, _source, _function, _arity, context), do: {state, context}

  defp program_timeout_action(state, source, context, action) do
    if timeout_action(action) == :error,
      do: {tls_failure(state, source, :tls_machine_program_action_origin), context},
      else: {state, context}
  end

  defp program_callback_module(state, source, context, module) do
    before = state.machine_states[source.pid].params
    modules = [module | tl(elem(before, 4))]

    case tls_callback_mode(module) do
      {:ok, _mode, enter?} when context.state_call ->
        result =
          before
          |> put_elem(1, :state_functions)
          |> put_elem(2, enter?)
          |> put_elem(4, modules)

        change = %{
          before: before,
          modules: modules,
          result: result,
          origin: context.origin,
          action: context.action
        }

        {state, %{context | module_action: change}}

      _ ->
        {tls_failure(state, source, :tls_callback_module_origin), context}
    end
  end

  defp program_stop_result({:stop_and_reply, reason, replies, next_data}, context) do
    {name, _data} = context.data
    {:ok, %{context | data: {name, next_data}, stop: {:exit, reason}, replies: replies}}
  end

  defp program_stop_result({:stop_and_reply, reason, replies}, context),
    do: {:ok, %{context | stop: {:exit, reason}, replies: replies}}

  defp program_stop_result({:stop, reason, next_data}, context) do
    {name, _data} = context.data
    {:ok, %{context | data: {name, next_data}, stop: {:exit, reason}}}
  end

  defp program_stop_result({:stop, reason}, context),
    do: {:ok, %{context | stop: {:exit, reason}}}

  defp program_stop_result(:stop, context), do: {:ok, %{context | stop: {:exit, :normal}}}
  defp program_stop_result(_result, _context), do: :error

  defp timeout_action({type, time, message, options}) do
    options = native_list(options)

    case Enum.reduce_while(options, false, fn
           {:abs, value}, _ when is_boolean(value) -> {:cont, value}
           _, _ -> {:halt, :error}
         end) do
      true -> {:ok, {type, time, message, options}}
      false -> {:ok, {type, time, message}}
      :error -> :error
    end
  end

  defp timeout_action({type, time, message}), do: {:ok, {type, time, message}}
  defp timeout_action({type, :cancel}), do: {:ok, {type, :infinity, :undefined}}

  defp timeout_action(time) when is_integer(time) or time == :infinity,
    do: {:ok, {:timeout, time, time}}

  defp timeout_action(_action), do: :error

  defp timeout_tuple({type, time, message}), do: {type, time, message, []}
  defp timeout_tuple(timeout), do: timeout
  defp program_actions({:next_state, _name, _data, actions}), do: actions

  defp program_actions({tag, _data, actions}) when tag in [:keep_state, :repeat_state],
    do: actions

  defp program_actions({tag, actions}) when tag in [:keep_state_and_data, :repeat_state_and_data],
    do: actions

  defp program_actions(_result), do: []
  defp native_list(value) when is_list(value), do: value
  defp native_list(value), do: [value]
  defp elem_if_tuple(value, position) when is_tuple(value), do: elem(value, position)
  defp elem_if_tuple(_value, _position), do: nil

  defp program_cancellations(state, source, context) do
    Enum.reduce(context.cancels, {state, %{context | cancels: []}}, fn type, {state, context} ->
      program_cancel_timer(state, source, context, type)
    end)
  end

  defp program_cancel_timer(state, source, context, type) do
    case context.timers[type] do
      {ref, _message} ->
        {state, result, context} =
          program_timer_return(state, source, context, :cancel_timer, [ref])

        timers = Map.delete(context.timers, type)
        timers = if result == false, do: Map.put(timers, ref, []), else: timers
        {state, %{context | timers: timers}}

      nil ->
        {state, context}
    end
  end

  defp program_pending_timer(state, _source, %{pending_timer: nil} = context),
    do: {state, context}

  defp program_pending_timer(state, source, context) do
    {type, _time, message, _options} = context.timeout

    {state, context} =
      case context.pending_timer do
        :cancel ->
          program_cancel_timer(state, source, context, type)

        :register ->
          {state, context} = program_cancel_timer(state, source, context, type)

          {state,
           %{context | timers: Map.put(context.timers, type, {context.timeout_ref, message})}}

        :update ->
          case context.timers[type] do
            {ref, _old} ->
              {state, %{context | timers: Map.put(context.timers, type, {ref, message})}}

            nil ->
              {state, ref, context} = program_timer_return(state, source, context, :make_ref, [])

              {state,
               %{
                 context
                 | timers: Map.put(context.timers, type, {ref, message}),
                   zero: [{type, ref} | context.zero]
               }}
          end
      end

    {state, %{context | seen: Map.put(context.seen, type, true), pending_timer: nil}}
  end

  defp program_timer_return(state, source, context, function, arguments) do
    case machine_timer_pairs(state, source, context.timer_index) do
      [pair | _] ->
        {_, :return_from, _, result} = pair.returned.event

        state =
          tls_exact(
            state,
            pair.source,
            :tls_machine_timer_program,
            pair.source.event,
            {source.pid, :call, {:erlang, function, arguments}}
          )

        {state, result, %{context | timer_index: pair.returned.index}}

      [] ->
        {tls_failure(state, source, :tls_machine_program_timer_origin), :missing_native_timer,
         context}
    end
  end

  defp program_stop(state, source, context) do
    stack =
      state.pair_index
      |> Map.get({source.pid, {:erlang, :process_info, 2}}, [])
      |> Enum.filter(fn pair ->
        pair.source.pid == source.pid and pair.source.index > context.origin and
          pair.returned.index < source.index and
          pair.source.event ==
            {source.pid, :call, {:erlang, :process_info, [source.pid, :current_stacktrace]}}
      end)
      |> Enum.max_by(& &1.returned.index, fn -> nil end)

    case {context.stop, stack} do
      {{class, reason},
       %{returned: %{event: {_, :return_from, _, {:current_stacktrace, frames}}}}} ->
        {:ok, class, reason, frames, context.replies, context.q}

      _ ->
        :error
    end
  end

  defp program_term(state, source, path, expected, origin) do
    program_term(state, source, path, expected, origin, &Function.identity/1)
  end

  defp program_term(state, source, path, expected, origin, transform) do
    actual = source.event |> native_term(path) |> transform.()
    state = tls_exact(state, source, :tls_machine_program_copy, actual, expected)
    state = tls_error_path(state, source, path, :tls_machine_program_copy)

    copy = %{index: source.index, path: path, origin: origin}
    Map.update!(state, :terms, &[copy | &1])
  end

  defp machine_metadata(state, source, function, arguments, version) do
    root = state.machine_states[source.pid]

    state =
      cond do
        function in @loop_state_functions ->
          state
          |> machine_term(source, [2, 2, 0], root.params, root.origin)
          |> machine_state(source, 2, version)

        function in [:reply_then_terminate, :do_reply_then_terminate, :terminate] ->
          state
          |> machine_term(source, [2, 2, 3], root.params, root.origin)
          |> machine_state(source, 5, version)

        true ->
          state
      end

    machine_queue(state, source, function, arguments)
  end

  defp machine_state(state, source, position, version) do
    root = state.machine_states[source.pid]
    state = machine_term(state, source, [2, 2, position, 1, 0], version.name, version.origin)

    Enum.reduce([0, 2, 3, 4, 5], state, fn field, state ->
      machine_term(state, source, [2, 2, position, field], elem(root.state, field), root.origin)
    end)
  end

  defp machine_queue(state, source, :loop_msg_event, arguments) do
    case Map.get(state.messages, source.pid) do
      %{value: event, origin: origin} = message when origin < source.index ->
        hibernate = Map.get(message, :hibernate, false)
        state = machine_term(state, source, [2, 2, 3], event, {:tls_message, origin})
        state = machine_term(state, source, [2, 2, 4], hibernate, {:tls_message, origin})
        queue = %{events: [event], hibernate: hibernate, origin: origin, fresh?: true}
        put_in(state.machine_queues[source.pid], queue)

      _ ->
        _ = arguments
        tls_failure(state, source, :tls_machine_queue_origin)
    end
  end

  defp machine_queue(state, source, :loop_event, _arguments) do
    case Map.get(state.machine_queues, source.pid) do
      %{events: events, hibernate: hibernate, origin: origin, fresh?: true} = queue ->
        state
        |> machine_term(source, [2, 2, 3], events, {:tls_queue, origin})
        |> machine_term(source, [2, 2, 4], hibernate, {:tls_queue, origin})
        |> put_in([:machine_queues, source.pid], %{queue | fresh?: false})
        |> put_in([:messages, source.pid], %{value: hd(events), origin: origin})

      _ ->
        tls_failure(state, source, :tls_machine_queue_origin)
    end
  end

  defp machine_queue(state, source, :loop_t0q, _arguments) do
    root = state.machine_states[source.pid]

    cursor =
      Map.get(state.machine_zero, source.pid, %{
        timers: elem(root.state, 3),
        events: elem(root.state, 4)
      })

    state = machine_term(state, source, [2, 2, 3], cursor.timers, root.origin)
    state = machine_term(state, source, [2, 2, 4], cursor.events, root.origin)
    machine_zero(state, source, root, cursor)
  end

  defp machine_queue(state, _source, _function, _arguments), do: state

  defp machine_zero(state, source, root, %{events: []} = cursor) do
    expected = root.state |> put_elem(3, cursor.timers) |> put_elem(4, [])

    state
    |> put_in([:machine_states, source.pid], %{root | state: expected, origin: source.index})
    |> Map.update!(:machine_zero, &Map.delete(&1, source.pid))
  end

  defp machine_zero(state, source, root, %{events: [{type, ref} | rest]} = cursor) do
    case Map.get(cursor.timers, type) do
      {^ref, message} ->
        expected = root.state |> put_elem(3, Map.delete(cursor.timers, type)) |> put_elem(4, rest)
        event = %{value: {type, message}, origin: source.index, hibernate: elem(root.state, 5)}

        state
        |> put_in([:machine_states, source.pid], %{root | state: expected, origin: source.index})
        |> put_in([:messages, source.pid], event)
        |> Map.update!(:machine_zero, &Map.delete(&1, source.pid))

      _ ->
        if Map.has_key?(cursor.timers, ref) do
          cursor = %{cursor | timers: Map.delete(cursor.timers, ref), events: rest}
          put_in(state.machine_zero[source.pid], cursor)
        else
          tls_failure(state, source, :tls_machine_zero_origin)
        end
    end
  end

  defp machine_term(state, source, path, expected, origin) do
    actual = native_term(source.event, path)
    state = tls_exact(state, source, :tls_machine_copy, actual, expected)

    state = tls_error_path(state, source, path, :tls_machine_copy)

    copy = %{index: source.index, path: path, origin: origin}
    Map.update!(state, :terms, &[copy | &1])
  end

  defp tls_error_path(
         %{errors: [%{index: index, rule: rule} = error | rest]} = state,
         %{index: index},
         path,
         rule
       ) do
    if Map.has_key?(error, :path),
      do: state,
      else: %{state | errors: [Map.put(error, :path, path) | rest]}
  end

  defp tls_error_path(state, _source, _path, _rule), do: state

  defp machine_commit(state, source, function)
       when function in [:loop_done, :reply_then_terminate, :do_reply_then_terminate, :terminate] do
    case Map.get(state.machine_callbacks, source.pid) do
      %{fresh?: true} = callback ->
        state = put_in(state.machine_callbacks[source.pid], %{callback | fresh?: false})

        callback = %{
          callback
          | source: Map.get(callback, :root_source, callback.source),
            result: Map.get(callback, :root_result, callback.result)
        }

        commit_callback(state, source, function, callback)

      _ ->
        state
    end
  end

  defp machine_commit(state, _source, _function), do: state

  defp commit_callback(state, source, :loop_done, callback) do
    root = state.machine_states[source.pid]
    queue = state.machine_queues[source.pid]
    {name, data} = elem(root.state, 1)

    case transition_result(callback.result, name, data) do
      {:ok, next_name, next_data, actions} ->
        transition = transition_actions(root.state, queue, next_name, next_data, actions)
        commit_transition(state, source, callback, root, transition)

      :error ->
        tls_failure(state, source, :tls_machine_result_origin)
    end
  end

  defp commit_callback(state, source, _function, callback) do
    root = state.machine_states[source.pid]
    version = state.owners[source.pid].version
    hibernate = state.machine_queues[source.pid].hibernate
    expected = root.state |> put_elem(1, {version.name, version.data}) |> put_elem(5, hibernate)

    put_in(state.machine_states[source.pid], %{
      root
      | state: expected,
        origin: callback.source.index
    })
  end

  defp transition_result({:next_state, name, data}, _name, _data), do: {:ok, name, data, []}

  defp transition_result({:next_state, name, data, actions}, _name, _data),
    do: {:ok, name, data, native_list(actions)}

  defp transition_result({:keep_state, data}, name, _data), do: {:ok, name, data, []}

  defp transition_result({:keep_state, data, actions}, name, _data),
    do: {:ok, name, data, native_list(actions)}

  defp transition_result(:keep_state_and_data, name, data), do: {:ok, name, data, []}

  defp transition_result({:keep_state_and_data, actions}, name, data),
    do: {:ok, name, data, native_list(actions)}

  defp transition_result({:repeat_state, data}, name, _data), do: {:ok, name, data, []}

  defp transition_result({:repeat_state, data, actions}, name, _data),
    do: {:ok, name, data, native_list(actions)}

  defp transition_result(:repeat_state_and_data, name, data), do: {:ok, name, data, []}

  defp transition_result({:repeat_state_and_data, actions}, name, data),
    do: {:ok, name, data, native_list(actions)}

  defp transition_result(_result, _name, _data), do: :error

  defp transition_actions(old, queue, name, data, actions) do
    initial = %{
      state: put_elem(old, 1, {name, data}),
      hibernate: queue.hibernate,
      postpone: false,
      next: [],
      timeouts: [],
      modules: [],
      unknown: []
    }

    transition = Enum.reduce(actions, initial, &transition_action/2)
    [event | rest] = queue.events
    postponed = if transition.postpone, do: [event | elem(old, 2)], else: elem(old, 2)
    changed? = name !== elem(elem(old, 1), 0)
    events = if changed?, do: Enum.reverse(postponed) ++ rest, else: rest
    postponed = if changed?, do: [], else: postponed
    next = transition.state |> put_elem(2, postponed) |> put_elem(5, transition.hibernate)

    Map.merge(transition, %{state: next, events: transition.next ++ events, changed?: changed?})
  end

  defp transition_action(:hibernate, state), do: %{state | hibernate: true}

  defp transition_action({:hibernate, value}, state) when is_boolean(value),
    do: %{state | hibernate: value}

  defp transition_action(:postpone, state), do: %{state | postpone: true}

  defp transition_action({:postpone, value}, state) when is_boolean(value),
    do: %{state | postpone: value}

  defp transition_action({:reply, _from, _reply}, state), do: state

  defp transition_action({:next_event, type, content}, state),
    do: %{state | next: state.next ++ [{type, content}]}

  defp transition_action({:change_callback_module, module} = action, state) when is_atom(module),
    do: %{state | modules: state.modules ++ [action]}

  defp transition_action({type, time, message}, state),
    do: %{state | timeouts: [{type, time, message, []} | state.timeouts]}

  defp transition_action({type, time, message, options} = action, state) do
    case timeout_action({type, time, message, options}) do
      {:ok, timeout} -> %{state | timeouts: [timeout_tuple(timeout) | state.timeouts]}
      :error -> %{state | unknown: [action | state.unknown]}
    end
  end

  defp transition_action({type, :cancel}, state),
    do: %{state | timeouts: [{type, :infinity, :undefined, []} | state.timeouts]}

  defp transition_action(value, state) when is_integer(value) or value == :infinity,
    do: %{state | timeouts: [{:timeout, value, value, []} | state.timeouts]}

  defp transition_action(action, state), do: %{state | unknown: [action | state.unknown]}

  defp commit_transition(state, source, callback, root, transition) do
    state = tls_exact(state, source, :tls_machine_action_origin, transition.unknown, [])
    changes = Map.get(state.module_changes, source.pid, [])
    own = Enum.filter(changes, &(&1.origin == callback.source.index))

    state =
      tls_exact(
        state,
        source,
        :tls_callback_module_program,
        Enum.map(own, & &1.action),
        transition.modules
      )

    state =
      put_in(
        state.module_changes[source.pid],
        Enum.reject(changes, &(&1.origin == callback.source.index))
      )

    pairs = machine_timer_pairs(state, source, callback.source.index)
    timers = elem(root.state, 3)

    context = %{
      state: state,
      source: source,
      pairs: pairs,
      timers: timers,
      zero: [],
      seen: MapSet.new()
    }

    context =
      if transition.changed?, do: cancel_machine_timer(context, :state_timeout), else: context

    context = cancel_machine_timer(context, :timeout)
    context = Enum.reduce(transition.timeouts, context, &machine_timeout/2)
    state = tls_exact(context.state, source, :tls_machine_timer_program, context.pairs, [])
    expected = put_elem(transition.state, 3, context.timers)
    expected = put_elem(expected, 4, elem(root.state, 4) ++ context.zero)

    queue = %{
      events: transition.events,
      hibernate: transition.hibernate,
      origin: callback.source.index,
      fresh?: transition.events != []
    }

    state
    |> put_in([:machine_states, source.pid], %{
      root
      | state: expected,
        origin: callback.source.index
    })
    |> put_in([:machine_queues, source.pid], queue)
  end

  defp machine_timer_pairs(state, source, first) do
    [
      {:erlang, :start_timer, 4},
      {:erlang, :cancel_timer, 1},
      {:erlang, :make_ref, 0}
    ]
    |> Enum.flat_map(&Map.get(state.pair_index, {source.pid, &1}, []))
    |> Enum.filter(fn pair ->
      pair.source.pid == source.pid and pair.source.index > first and
        pair.returned.index < source.index and
        pair.source.mfa in [
          {:erlang, :start_timer, 4},
          {:erlang, :cancel_timer, 1},
          {:erlang, :make_ref, 0}
        ]
    end)
    |> Enum.sort_by(& &1.source.index)
  end

  defp cancel_machine_timer(context, type) do
    case Map.get(context.timers, type) do
      {ref, _message} ->
        {result, context} = machine_timer_call(context, :cancel_timer, [ref])
        timers = Map.delete(context.timers, type)
        timers = if result == false, do: Map.put(timers, ref, []), else: timers
        %{context | timers: timers}

      nil ->
        context
    end
  end

  defp machine_timeout({type, time, message, options}, context) do
    if MapSet.member?(context.seen, type) do
      context
    else
      context = %{context | seen: MapSet.put(context.seen, type)}
      install_machine_timeout(context, type, time, message, options)
    end
  end

  defp install_machine_timeout(context, type, :infinity, _message, _options),
    do: cancel_machine_timer(context, type)

  defp install_machine_timeout(context, type, :update, message, _options) do
    case Map.get(context.timers, type) do
      {ref, _old} -> %{context | timers: Map.put(context.timers, type, {ref, message})}
      nil -> install_machine_timeout(context, type, 0, message, [])
    end
  end

  defp install_machine_timeout(context, type, time, message, options) do
    {ref, context} =
      if time == 0,
        do: machine_timer_call(context, :make_ref, []),
        else: machine_timer_call(context, :start_timer, [time, context.source.pid, type, options])

    context = cancel_machine_timer(context, type)
    timers = Map.put(context.timers, type, {ref, message})
    zero = if time == 0, do: [{type, ref} | context.zero], else: context.zero
    %{context | timers: timers, zero: zero}
  end

  defp machine_timer_call(%{pairs: [pair | rest]} = context, function, arguments) do
    {_, :call, {module, actual_function, actual}} = pair.source.event
    {_, :return_from, _, result} = pair.returned.event
    expected = {:erlang, function, arguments}

    state =
      tls_exact(
        context.state,
        pair.source,
        :tls_machine_timer_program,
        {module, actual_function, actual},
        expected
      )

    valid? =
      if function == :cancel_timer,
        do: result == false or (is_integer(result) and result >= 0),
        else: is_reference(result)

    state = tls_exact(state, pair.returned, :tls_machine_timer_program, valid?, true)
    {result, %{context | state: state, pairs: rest}}
  end

  defp machine_timer_call(context, _function, _arguments) do
    state = tls_failure(context.state, context.source, :tls_machine_timer_origin)
    {:missing_native_timer, %{context | state: state}}
  end

  defp loop_current_copy(state, source, function, version) do
    cond do
      function in @loop_state_functions ->
        worker_copy(state, source, [2, 2, 2, 1, 1], version.data, version.origin)

      function in [:reply_then_terminate, :do_reply_then_terminate, :terminate] ->
        worker_copy(state, source, [2, 2, 5, 1, 1], version.data, version.origin)

      true ->
        state
    end
  end

  defp loop_next_copy(state, source, function, version, next) do
    expected =
      case state.machine_programs[source.pid] do
        %{data: {_name, data}} ->
          data

        _ ->
          if function in [:loop_state_callback, :loop_state_callback_result],
            do: version.data,
            else: next.data
      end

    cond do
      function in [:loop_state_callback, :loop_state_callback_result] ->
        worker_copy(state, source, [2, 2, 4, 1], expected, version.origin)

      function in @loop_next_functions ->
        worker_copy(state, source, [2, 2, 4, 1], expected, next.origin)

      true ->
        state
    end
  end

  defp loop_result_copy(state, source, :loop_state_callback_result, arguments, next) do
    case result_data_path(List.last(arguments)) do
      nil -> state
      path -> worker_copy(state, source, [2, 2, 10 | path], next.data, next.origin)
    end
  end

  defp loop_result_copy(state, _source, _function, _arguments, _next), do: state

  defp loop_commit(state, pid, function)
       when function in [:loop_done, :reply_then_terminate, :do_reply_then_terminate, :terminate] do
    case Map.pop(state.pending, pid) do
      {nil, _pending} ->
        state

      {version, pending} ->
        state |> Map.put(:pending, pending) |> put_in([:owners, pid, :version], version)
    end
  end

  defp loop_commit(state, _pid, _function), do: state

  defp loop_message(state, source, arguments) do
    queue = Map.get(state.received, source.pid, :queue.new())

    case :queue.out(queue) do
      {{:value, %{message: message, source: origin}}, remaining}
      when origin.index < source.index ->
        state = put_in(state.received[source.pid], remaining)
        state = tls_exact(state, source, :tls_event_copy, Enum.at(arguments, 3), message)

        state =
          put_in(state.machine_received[source.pid], %{value: message, origin: origin.index})

        term = %{index: source.index, path: [2, 2, 3], origin: {:tls_message, origin.index}}
        state = Map.update!(state, :terms, &[term | &1])

        machine_message(state, source.pid, message, origin.index)

      _ ->
        tls_failure(state, source, :tls_event_origin)
    end
  end

  defp machine_message(state, pid, {:timeout, ref, type} = message, origin)
       when is_reference(ref) do
    root = state.machine_states[pid]
    timers = elem(root.state, 3)

    case Map.get(timers, type) do
      {^ref, content} ->
        expected = put_elem(root.state, 3, Map.delete(timers, type))

        state
        |> put_in([:machine_states, pid], %{root | state: expected, origin: origin})
        |> put_in([:messages, pid], %{value: {type, content}, origin: origin})

      _ ->
        if Map.has_key?(timers, ref) do
          expected = put_elem(root.state, 3, Map.delete(timers, ref))

          state
          |> put_in([:machine_states, pid], %{root | state: expected, origin: origin})
          |> Map.update!(:messages, &Map.delete(&1, pid))
        else
          machine_message(state, pid, {:info, message}, origin, :converted)
        end
    end
  end

  defp machine_message(state, pid, message, origin),
    do: machine_message(state, pid, callback_message(message), origin, :converted)

  defp machine_message(state, pid, event, origin, :converted),
    do: put_in(state.messages[pid], %{value: event, origin: origin})

  # Receive tracing records mailbox arrivals. Selective native helpers consume
  # only their independently bound receipts; every other arrival stays FIFO for
  # loop_msg. Receipt selection never grants an observation allowance.
  defp call_receipts(events, pairs) do
    occurrences = pair_occurrences(pairs)
    arrivals = Enum.group_by(events, &{&1.pid, elem(&1.event, 1)})

    pairs
    |> Map.values()
    |> Enum.flat_map(fn
      %{
        source: %{event: {pid, :call, {:gen, :call, [destination, label, request, _]}}} = source,
        returned: %{event: {reply_pid, :return_from, {:gen, :call, 4}, {:ok, result}}} = returned
      }
      when reply_pid == pid ->
        case call_target(occurrences, source, returned, destination) do
          {:ok, target, origin} ->
            source = Map.put(source, :resolved_at, origin)

            call_receipt(
              arrivals,
              occurrences,
              source,
              returned,
              target,
              label,
              request,
              result
            )

          :error ->
            []
        end

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp call_target(_pairs, source, _returned, target) when is_pid(target),
    do: {:ok, target, source.index}

  defp call_target(pairs, source, returned, name) when is_atom(name) do
    resolutions =
      for pair <- Map.get(pairs, {source.pid, {:erlang, :whereis, 1}}, []),
          pair.source.event === {source.pid, :call, {:erlang, :whereis, [name]}},
          pair.source.index > source.index and pair.returned.index < returned.index,
          {_, :return_from, _, target} <- [pair.returned.event],
          is_pid(target),
          do: {target, pair.returned.index}

    case resolutions do
      [{target, origin}] -> {:ok, target, origin}
      _ -> :error
    end
  end

  defp call_target(_pairs, _source, _returned, _destination), do: :error

  defp call_receipt(events, pairs, source, returned, target, label, request, result) do
    pid = source.pid

    requests =
      Enum.filter(Map.get(events, {pid, :send}, []), fn
        %{event: {^pid, :send, {^label, {^pid, _tag}, ^request}, ^target}} = sent ->
          sent.index > source.index and sent.index < returned.index

        _ ->
          false
      end)

    case requests do
      [%{event: {_, :send, {_, {_, tag}, _}, _}} = sent] ->
        case call_monitor(pairs, source, sent, pid, target, tag) do
          {:ok, ref} -> call_reply(events, pairs, sent, returned, tag, result, ref)
          :error -> []
        end

      _ ->
        []
    end
  end

  defp call_monitor(pairs, source, sent, pid, target, tag) do
    {^pid, :call, {:gen, :call, [_, _, _, timeout]}} = source.event
    alias? = timeout != :infinity or node(target) != node()

    candidates =
      Map.get(pairs, {pid, {:erlang, :monitor, 2}}, []) ++
        Map.get(pairs, {pid, {:erlang, :monitor, 3}}, [])

    expected = if alias?, do: [:process, target, [alias: :demonitor]], else: [:process, target]

    matches =
      for %{source: monitor, returned: returned} <- candidates,
          monitor.event === {pid, :call, {:erlang, :monitor, expected}},
          monitor.index > source.resolved_at and returned.index < sent.index,
          {_, :return_from, _, ref} <- [returned.event],
          is_reference(ref),
          tag === if(alias?, do: [:alias | ref], else: ref),
          do: ref

    case matches do
      [ref] -> {:ok, ref}
      _ -> :error
    end
  end

  defp call_reply(events, pairs, sent, returned, tag, result, ref) do
    {pid, :send, _, target} = sent.event

    destination =
      case tag do
        [:alias | ref] -> ref
        _ -> pid
      end

    replies =
      Enum.filter(Map.get(events, {target, :send}, []), fn
        %{event: {^target, :send, {^tag, _reply}, ^destination}} = reply ->
          reply.index > sent.index and reply.index < returned.index

        _ ->
          false
      end)

    case replies do
      [reply] ->
        if call_request_received?(events, sent, reply, target),
          do: call_reply_received(events, pairs, reply, returned, pid, tag, result, ref),
          else: []

      _ ->
        []
    end
  end

  defp call_request_received?(events, sent, reply, target) do
    {_, :send, message, ^target} = sent.event

    Enum.count(Map.get(events, {target, :receive}, []), fn received ->
      received.event === {target, :receive, message} and
        sent.index < received.index and received.index < reply.index
    end) == 1
  end

  defp call_reply_received(events, pairs, reply, returned, pid, tag, result, ref) do
    {_, :send, message, _} = reply.event

    receipts =
      for %{event: {^pid, :receive, {^tag, _value}}} = received <-
            Map.get(events, {pid, :receive}, []),
          received.index > reply.index and received.index < returned.index,
          do: received

    case receipts do
      [%{event: {_, :receive, ^message}} = receipt] when elem(message, 1) === result ->
        if call_demonitored?(pairs, receipt, returned, pid, ref), do: [receipt.index], else: []

      _ ->
        []
    end
  end

  defp call_demonitored?(pairs, receipt, returned, pid, ref) do
    Enum.any?(Map.get(pairs, {pid, {:erlang, :demonitor, 2}}, []), fn pair ->
      pair.source.event === {pid, :call, {:erlang, :demonitor, [ref, [:flush]]}} and
        receipt.index < pair.source.index and pair.returned.index < returned.index and
        elem(pair.returned.event, 3) in [true, false]
    end)
  end

  defp callback_message({:"$gen_call", from, message}), do: {{:call, from}, message}
  defp callback_message({:"$gen_cast", message}), do: {:cast, message}
  defp callback_message(message), do: {:info, message}

  defp worker_call(state, source, arguments, position) do
    frames = Map.get(state.frames, source.pid, [])
    {state, version} = worker_input(state, source, arguments, frames)
    state = worker_copy(state, source, [2, 2, position], version.data, version.origin)
    state = receiver_record_input(state, source, arguments, version, position)
    state = hibernate_input(state, source, arguments, frames, version)
    frame = %{source: source, input: version, current: version, arguments: arguments}
    frame = Map.put(frame, :event, Map.get(state.messages, source.pid))
    {state, frame} = worker_initialization(state, frame)
    {state, frame} = worker_write_update(state, frame, frames)
    {state, frame} = worker_handshake_dispatch(state, frame, frames)
    put_in(state.frames[source.pid], [frame | frames])
  end

  defp worker_handshake_dispatch(
         state,
         %{event: %{value: {:internal, {:handshake, _}}}} = frame,
         []
       ) do
    case Map.get(state.handshake_packets, frame.source.pid, []) do
      [%{packet: packet} = expected | rest] ->
        state =
          tls_exact(
            state,
            frame.source,
            :tls_handshake_copy,
            frame.event.value,
            {:internal, {:handshake, packet}}
          )

        state = put_in(state.handshake_packets[frame.source.pid], rest)
        {state, Map.put(frame, :expected_handshake, expected)}

      [] ->
        {tls_failure(state, frame.source, :tls_handshake_origin), frame}
    end
  end

  defp worker_handshake_dispatch(state, frame, [%{expected_handshake: expected} | _]),
    do: {state, Map.put(frame, :expected_handshake, expected)}

  defp worker_handshake_dispatch(state, frame, _frames), do: {state, frame}

  defp worker_initialization(
         state,
         %{source: %{mfa: {:tls_sender, :init, 3}} = source} = frame
       ) do
    family = state.owners[source.pid].family
    receiver = family.owner
    sender = family.sender
    {_name, receiver_data} = Map.fetch!(family.states, receiver)
    initialization = sender_initialization(receiver_data)

    factories =
      Map.get(state.pair_index, {receiver, {:tls_gen_connection, :initialize_tls_sender, 1}}, [])

    interfaces = Map.get(state.pair_index, {receiver, {:tls_sender, :initialize, 2}}, [])
    calls = Map.get(state.pair_index, {receiver, {:gen_statem, :call, 2}}, [])

    with %{value: {{:call, from}, _message}} <- frame.event,
         {:ok, initialization_origin} <- Map.fetch(family, :initialization_origin),
         [factory] <- Enum.filter(factories, &initialization_active?(&1, source)),
         [interface] <- Enum.filter(interfaces, &initialization_active?(&1, source)),
         [call] <- Enum.filter(calls, &initialization_active?(&1, source)),
         true <- initialization_origin < factory.source.index,
         true <- factory.source.index < interface.source.index,
         true <- interface.source.index < call.source.index,
         true <- call.returned.index < interface.returned.index,
         true <- interface.returned.index < factory.returned.index,
         true <- factory.returned.event == {receiver, :return_from, factory.source.mfa, :ok},
         true <- interface.returned.event == {receiver, :return_from, interface.source.mfa, :ok},
         true <- call.returned.event == {receiver, :return_from, call.source.mfa, :ok} do
      origin = {:tls_receiver_initialization, initialization_origin}

      state =
        state
        |> worker_copy(factory.source, [2, 2, 0], receiver_data, origin)
        |> worker_copy(interface.source, [2, 2], [sender, initialization], origin)
        |> worker_copy(call.source, [2, 2], [sender, {receiver, initialization}], origin)
        |> worker_copy(source, [2, 2, 1], {receiver, initialization}, origin)

      data = initialized_sender_data(frame.input.data, receiver, initialization)
      current = %{frame.input | name: :handshake, data: data, origin: factory.source.index}
      {state, frame |> Map.put(:current, current) |> Map.put(:initialization_from, from)}
    else
      _ -> {tls_failure(state, source, :tls_sender_initialization_origin), frame}
    end
  end

  defp worker_initialization(state, frame), do: {state, frame}

  defp worker_write_update(
         state,
         %{
           source: %{mfa: {:tls_sender, name, 3}} = source,
           event: %{value: {:cast, {:new_write, _, _, _}}, origin: receipt}
         } = frame,
         []
       )
       when name in [:handshake, :connection] do
    case Map.pop(state.write_updates, receipt) do
      {nil, _updates} ->
        {tls_failure(state, source, :tls_write_update_origin), frame}

      {update, updates} ->
        state = %{state | write_updates: updates}
        {:new_write, write, version, maximum} = update.message
        data = frame.input.data
        states = sender_write_state(elem(data, 2), write, maximum)
        environment = put_elem(elem(data, 1), 6, version)

        environment =
          if name == :handshake,
            do: put_elem(environment, 8, sender_key_update(version, write, elem(environment, 8))),
            else: environment

        current = %{
          frame.input
          | name: :connection,
            data: data |> put_elem(1, environment) |> put_elem(2, states),
            origin: update.origin
        }

        {state, frame |> Map.put(:current, current) |> Map.put(:write_update, update)}
    end
  end

  defp worker_write_update(state, frame, _frames), do: {state, frame}

  defp sender_write_state(states, write, maximum) do
    states = Map.put(states, :current_write, Map.delete(write, :aead_handle))

    if maximum == :undefined,
      do: Map.delete(states, :max_fragment_length),
      else: Map.put(states, :max_fragment_length, maximum)
  end

  defp sender_key_update({3, 4}, %{security_parameters: parameters}, current) do
    if elem(parameters, 3) == 9, do: :seq_num_wrap, else: current
  end

  defp sender_key_update(_version, _write, current), do: current

  defp initialization_active?(pair, source),
    do: pair.source.index < source.index and source.index < pair.returned.index

  # initialize_tls_sender/1 builds this message from the independently constructed
  # receiver entry. No field is learned from the checked sender request or return.
  defp sender_initialization(data) do
    environment = elem(data, 2)
    options = elem(data, 4)
    connection_states = elem(data, 10)

    keylog =
      case Map.get(options, :keep_secrets, false) do
        {:keylog, function} -> function
        _ -> :undefined
      end

    %{
      current_write: Map.fetch!(connection_states, :current_write),
      beast_mitigation: Map.get(connection_states, :beast_mitigation, :disabled),
      role: elem(environment, 1),
      socket: elem(environment, 11),
      socket_opts_tab: elem(data, 1),
      erl_dist: Map.get(options, :erl_dist, false),
      trackers: elem(environment, 18),
      transport_cb: elem(environment, 3),
      negotiated_version: elem(elem(data, 3), 5),
      renegotiate_at: Map.fetch!(options, :renegotiate_at),
      key_update_at: Map.fetch!(options, :key_update_at),
      log_level: Map.fetch!(options, :log_level),
      hibernate_after: Map.get(options, :hibernate_after, :infinity),
      keylog_fun: keylog
    }
  end

  defp initialized_sender_data(data, receiver, initialization) do
    environment =
      Enum.reduce(
        [
          {1, receiver},
          {2, initialization.role},
          {3, initialization.socket},
          {4, initialization.socket_opts_tab},
          {5, initialization.transport_cb},
          {6, initialization.negotiated_version},
          {7, initialization.renegotiate_at},
          {8, initialization.key_update_at},
          {9, initialization.erl_dist},
          {10, initialization.log_level},
          {11, initialization.hibernate_after},
          {12, initialization.keylog_fun}
        ],
        elem(data, 1),
        fn {position, value}, environment -> put_elem(environment, position, value) end
      )

    connection_states = Map.put(elem(data, 2), :current_write, initialization.current_write)

    connection_states =
      if initialization.beast_mitigation == :disabled,
        do: connection_states,
        else: Map.put(connection_states, :beast_mitigation, initialization.beast_mitigation)

    data |> put_elem(1, environment) |> put_elem(2, connection_states) |> put_elem(3, 0)
  end

  defp hibernate_input(
         state,
         %{mfa: {:tls_sender, :hibernate_after, 3}} = source,
         [name, _data, actions],
         [%{source: %{mfa: {:tls_sender, :send_application_data, 4}}} | _],
         version
       ) do
    state
    |> tls_exact(source, :tls_callback_input, name, version.name)
    |> tls_exact(source, :tls_callback_input, actions, [])
  end

  defp hibernate_input(
         state,
         %{mfa: {:tls_sender, :hibernate_after, 3}} = source,
         [name, _data, actions],
         [%{write_update: _update} | _],
         version
       ) do
    state
    |> tls_exact(source, :tls_callback_input, name, version.name)
    |> tls_exact(source, :tls_callback_input, actions, [])
  end

  defp hibernate_input(
         state,
         %{mfa: {:tls_sender, :hibernate_after, 3}} = source,
         _arguments,
         _frames,
         _version
       ),
       do: tls_failure(state, source, :tls_callback_input_origin)

  defp hibernate_input(state, _source, _arguments, _frames, _version), do: state

  defp receiver_actions(
         [%{handshake_program: %{packets: [_ | _], events: events}} | _],
         _version
       ),
       do: events

  defp receiver_actions(frames, version) do
    finished = Enum.find(frames, &Map.has_key?(&1, :connection_ready))

    hello =
      Enum.find(frames, fn
        %{source: %{mfa: {module, :initial_hello, 3}}}
        when module in [:tls_client_connection, :tls_client_connection_1_3] ->
          true

        _ ->
          false
      end)

    recv =
      Enum.find_value(frames, fn frame ->
        case frame.event do
          %{value: {{:call, _from}, {:recv, _length, timeout}}} -> {:recv, timeout}
          _ -> nil
        end
      end)

    delivered? =
      Enum.any?(frames, fn frame ->
        frame.source.mfa == {:tls_gen_connection, :handle_protocol_record, 3} and
          elem(elem(frame.input.data, 9), 1) != :undefined and
          elem(elem(version.data, 9), 1) == :undefined
      end)

    cond do
      finished ->
        Enum.at(finished.connection_ready, 2)

      hello ->
        [{:call, _from}, {:start, timeout}, _data] = hello.arguments
        [{{:timeout, :handshake}, timeout, :close}]

      delivered? ->
        [{{:timeout, :recv}, :infinity, :timeout}]

      recv ->
        {:recv, timeout} = recv
        timeout = if elem(elem(version.data, 9), 1) == :undefined, do: :infinity, else: timeout
        [{{:timeout, :recv}, timeout, :timeout}]

      true ->
        if Enum.any?(frames, &(&1.source.mfa == {:tls_gen_connection, :next_event, 3})),
          do: [],
          else: :missing_receiver_actions
    end
  end

  defp worker_input(state, source, arguments, []) do
    current = state.owners[source.pid].version

    version =
      case {List.first(source.stack), state.machine_programs[source.pid]} do
        {{:gen_statem, :loop_state_callback, _},
         %{state_call: false, data: {name, data}, origin: origin}} ->
          %{current | name: name, data: data, origin: {:tls_state_enter, origin}}

        _ ->
          current
      end

    state =
      case Map.get(state.messages, source.pid) do
        %{value: {type, message}} ->
          state
          |> tls_exact(source, :tls_event_copy, Enum.at(arguments, 0), type)
          |> tls_exact(source, :tls_event_copy, Enum.at(arguments, 1), message)

        nil ->
          tls_failure(state, source, :tls_event_origin)
      end

    {state, version}
  end

  defp worker_input(state, source, arguments, [parent | _]) do
    case source.mfa do
      {:tls_gen_connection, function, arity}
      when {function, arity} in [{:next_record, 5}, {:next_record, 7}, {:next_record_done, 4}] ->
        worker_record_input(state, source, parent)

      {:ssl_gen_statem, :passive_receive, 3} ->
        recv_input(state, source, parent)

      {:tls_sender, :send_or_buffer, 5} ->
        {state, version} = sender_constructed(state, source, parent)
        {sender_forward_copies(state, source, arguments, parent), version}

      {:tls_gen_connection, :next_event, 4} ->
        worker_next_event_input(state, source, parent)

      {:tls_gen_connection, :next_event, 3} ->
        server_hello_next_input(state, source, arguments, parent)

      _ ->
        _ = arguments
        {state, parent.current}
    end
  end

  defp server_hello_next_input(
         state,
         source,
         arguments,
         %{
           source: %{mfa: {:tls_client_connection, :hello, 3}},
           legacy_hello: %{next: next}
         } = parent
       ) do
    expected = [:certify, :no_record]
    state = tls_exact(state, source, :tls_callback_input, Enum.take(arguments, 2), expected)
    {state, %{parent.current | name: :certify, data: next}}
  end

  defp server_hello_next_input(
         state,
         source,
         arguments,
         %{server_hello_program: program} = parent
       ) do
    state =
      tls_exact(state, source, :tls_callback_input, Enum.take(arguments, 2), [
        program.next_name,
        :no_record
      ])

    {state, %{parent.current | name: program.next_name}}
  end

  defp server_hello_next_input(
         state,
         source,
         arguments,
         %{
           source: %{mfa: {:tls_client_connection_1_3, :wait_ee, 3}},
           event: %{value: {:internal, {:encrypted_extensions, extensions}}}
         } = parent
       ) do
    data = parent.current.data
    options = elem(data, 4)
    handshake = elem(data, 6)

    maximum =
      case Map.get(options, :max_fragment_length, :undefined) do
        :undefined -> :undefined
        512 -> {:max_frag_enum, 1}
        1024 -> {:max_frag_enum, 2}
        2048 -> {:max_frag_enum, 3}
        4096 -> {:max_frag_enum, 4}
      end

    with true <- Map.get(extensions, :max_frag_enum, :undefined) === maximum,
         {:ok, alpn} <- encrypted_extensions_alpn(Map.get(extensions, :alpn, :undefined)) do
      accepted? =
        hd(Map.fetch!(options, :versions)) == {3, 4} and
          Map.fetch!(options, :use_ticket) != [:undefined] and
          Map.fetch!(options, :early_data) != :undefined and
          Map.get(extensions, :early_data, :undefined) != :undefined

      handshake = if accepted?, do: put_elem(handshake, 10, true), else: handshake
      resumed? = elem(handshake, 6) == true
      name = if resumed?, do: :wait_finished, else: :wait_cert_cr
      handshake = if resumed?, do: handshake, else: put_elem(handshake, 17, alpn)
      data = put_elem(data, 6, handshake)

      state =
        tls_exact(state, source, :tls_callback_input, Enum.take(arguments, 2), [name, :no_record])

      {state,
       %{
         parent.current
         | name: name,
           data: data,
           origin: {:tls_encrypted_extensions, parent.source.index}
       }}
    else
      _ ->
        {tls_failure(state, source, :tls_encrypted_extensions_origin), parent.current}
    end
  end

  defp server_hello_next_input(
         state,
         source,
         arguments,
         %{
           source: %{mfa: {:tls_client_connection_1_3, :wait_cert_cr, 3}},
           event: %{value: {:internal, {:certificate_1_3, <<>>, entries} = certificate}}
         } = parent
       ) do
    data = parent.current.data

    with {:ok, %{source: call, returned: returned}, peer, key, :verified} <-
           server_certificate_program(state, parent, source, entries) do
      handshake = put_elem(elem(data, 6), 25, key)
      session = put_elem(elem(data, 8), 3, peer)
      next = data |> put_elem(6, handshake) |> put_elem(8, session)
      origin = {:tls_server_certificate, call.index}

      state =
        state
        |> handshake_copy(call, [2, 2], [certificate, data], parent.current.origin)
        |> handshake_copy(returned, [3], {next, :wait_cv}, origin)
        |> tls_exact(source, :tls_callback_input, Enum.take(arguments, 2), [:wait_cv, :no_record])

      {state, %{parent.current | name: :wait_cv, data: next, origin: origin}}
    else
      {:error, rule} -> {tls_failure(state, source, rule), parent.current}
      _ -> {tls_failure(state, source, :tls_server_certificate_origin), parent.current}
    end
  end

  defp server_hello_next_input(
         state,
         source,
         arguments,
         %{
           source: %{mfa: {:tls_client_connection_1_3, :wait_cv, 3}},
           event: %{value: {:internal, {:certificate_verify_1_3, scheme, signature}}}
         } = parent
       ) do
    data = parent.current.data
    options = elem(data, 4)
    handshake = elem(data, 6)
    parameters = Map.fetch!(elem(data, 10), :pending_write).security_parameters
    scope = %{source: parent.source, returned: source}

    with true <- scheme in tls13_signature_schemes(options.signature_algs),
         {[<<15, _::binary>> | messages], _} <- elem(handshake, 3),
         {:ok, digest} <-
           handshake_primitive(state, scope, {:crypto, :hash, 2}, [
             elem(parameters, 8),
             Enum.reverse(messages)
           ]),
         true <- verify_server_transcript(scheme, signature, digest, elem(handshake, 25)) do
      expected = [:wait_finished, :no_record]
      state = tls_exact(state, source, :tls_callback_input, Enum.take(arguments, 2), expected)
      origin = {:tls_server_certificate_verify, parent.source.index}
      {state, %{parent.current | name: :wait_finished, origin: origin}}
    else
      _ -> {tls_failure(state, source, :tls_server_certificate_verify_origin), parent.current}
    end
  end

  defp server_hello_next_input(
         state,
         source,
         arguments,
         %{
           source: %{mfa: {:tls_client_connection, :certify, 3}},
           event: %{value: {:internal, {:certificate, chain}}}
         } = parent
       ) do
    data = parent.current.data
    entries = Enum.map(chain, &{:certificate_entry, &1, %{}})
    mfa = {:ssl_handshake, :certify, 9}
    exchange = elem(elem(data, 6), 21)

    with true <- exchange in [:ecdhe_rsa, :ecdhe_ecdsa, :dhe_rsa, :dhe_dss, :rsa],
         [%{source: call, returned: returned}] <-
           tls_scoped_calls(state, parent.source, source, mfa),
         {:ok, peer, key, :verified} <-
           server_certificate(state, call, returned, entries, data) do
      handshake = put_elem(elem(data, 6), 25, key)
      session = put_elem(elem(data, 8), 3, peer)
      next = data |> put_elem(6, handshake) |> put_elem(8, session)
      origin = {:tls_legacy_certificate, call.index}

      state =
        state
        |> handshake_copy(
          returned,
          [3],
          {{:cert, peer, :public_key.pkix_decode_cert(peer, :otp)}, key},
          origin
        )
        |> tls_exact(source, :tls_callback_input, Enum.take(arguments, 2), [:certify, :no_record])

      {state, %{parent.current | name: :certify, data: next, origin: origin}}
    else
      {:error, rule} -> {tls_failure(state, source, rule), parent.current}
      _ -> {tls_failure(state, source, :tls_legacy_certificate_origin), parent.current}
    end
  end

  defp server_hello_next_input(
         state,
         source,
         arguments,
         %{
           source: %{mfa: {:tls_client_connection, :certify, 3}},
           event: %{value: {:internal, {:server_key_exchange, wire}}}
         } = parent
       ) do
    case legacy_server_key_exchange(state, parent.source, source, parent.current.data, wire) do
      {:ok, data} ->
        state =
          tls_exact(state, source, :tls_callback_input, Enum.take(arguments, 2), [
            :certify,
            :no_record
          ])

        origin = {:tls_legacy_server_key, parent.source.index}
        {state, %{parent.current | name: :certify, data: data, origin: origin}}

      :error ->
        {tls_failure(state, source, :tls_legacy_server_key_origin), parent.current}
    end
  end

  defp server_hello_next_input(
         state,
         source,
         arguments,
         %{
           source: %{mfa: {:tls_client_connection, :certify, 3}},
           event: %{value: {:internal, {:server_hello_done}}}
         } = parent
       ) do
    case legacy_client_flight(state, parent, source) do
      {:ok, state, data} ->
        state =
          tls_exact(state, source, :tls_callback_input, Enum.take(arguments, 2), [
            :cipher,
            :no_record
          ])

        origin = {:tls_legacy_client_flight, parent.source.index}
        {state, %{parent.current | name: :cipher, data: data, origin: origin}}

      :error ->
        {tls_failure(state, source, :tls_legacy_client_flight_origin), parent.current}
    end
  end

  defp server_hello_next_input(
         state,
         source,
         arguments,
         %{
           source: %{mfa: {:tls_client_connection, :cipher, 3}},
           event: %{value: {:internal, {:change_cipher_spec, <<1>>}}}
         } = parent
       ) do
    data = parent.current.data
    handshake = elem(data, 6)

    with false <- elem(handshake, 4),
         {:ok, states} <-
           legacy_activate(state, parent.source, source, elem(data, 10), :read) do
      data = data |> put_elem(6, put_elem(handshake, 4, true)) |> put_elem(10, states)

      state =
        tls_exact(state, source, :tls_callback_input, Enum.take(arguments, 2), [
          :cipher,
          :no_record
        ])

      {state, %{parent.current | data: data, origin: {:tls_legacy_read_cipher, source.index}}}
    else
      _ -> {tls_failure(state, source, :tls_legacy_read_cipher_origin), parent.current}
    end
  end

  defp server_hello_next_input(state, source, _arguments, parent),
    do: change_cipher_spec_next_input(state, source, parent)

  defp tls_scoped_calls(state, first, last, mfa) do
    Enum.filter(Map.get(state.pair_index, {first.pid, mfa}, []), fn pair ->
      first.index < pair.source.index and pair.returned.index < last.index
    end)
  end

  defp server_certificate_program(state, frame, last, entries) do
    mfa = {:tls_client_connection_1_3, :handle_certificate, 2}
    data = frame.input.data

    with [%{source: call, returned: returned} = pair] <-
           tls_scoped_calls(state, frame.source, last, mfa),
         {:ok, peer, key, result} <- server_certificate(state, call, returned, entries, data) do
      {:ok, pair, peer, key, result}
    else
      {:error, rule} -> {:error, rule}
      _ -> {:error, :tls_certificate_handler}
    end
  end

  defp server_certificate(state, call, returned, entries, data) do
    options = elem(data, 4)
    stapling = elem(elem(data, 6), 32)
    host = elem(elem(data, 2), 9)

    with {:ok, [peer | _] = chain} <- certificate_chain(entries, options, stapling),
         {:ok, roots} <- certificate_roots(options),
         {:ok, dates} <- certificate_dates(state, call, returned),
         {:ok, key, root, path} <- certificate_path(roots, chain, dates, options),
         :ok <- certificate_trust_input(state, call, returned, root, path, options) do
      {:ok, peer, key, certificate_hostname(peer, host, options)}
    else
      {:error, rule} -> {:error, rule}
    end
  rescue
    _invalid in [ArgumentError, FunctionClauseError, MatchError, KeyError] ->
      {:error, :tls_certificate_material}
  end

  defp certificate_chain(entries, options, stapling) do
    with %{verify: :verify_peer, verify_fun: :undefined, crl_check: false} <- options,
         %{configured: false} <- stapling,
         [] <- Map.get(options, :cert_policy_opts, []) do
      chain =
        for {:certificate_entry, der, extensions} <- entries,
            is_binary(der) and map_size(extensions) == 0,
            do: der

      if chain != [] and length(chain) == length(entries) and length(chain) - 1 <= options.depth,
        do: {:ok, chain},
        else: {:error, :tls_certificate_chain}
    else
      _ -> {:error, :tls_certificate_options}
    end
  end

  defp certificate_roots(%{cacerts: certs}) when is_list(certs) and certs != [], do: {:ok, certs}

  defp certificate_roots(%{cacertfile: file}) when is_list(file) or is_binary(file) do
    with {:ok, pem} <- File.read(file),
         [_ | _] = roots <-
           for({:Certificate, der, :not_encrypted} <- :public_key.pem_decode(pem), do: der) do
      {:ok, roots}
    else
      _ -> {:error, :tls_certificate_anchor}
    end
  end

  defp certificate_roots(_options), do: {:error, :tls_certificate_anchor}

  defp certificate_dates(state, first, last) do
    case certificate_clock_reads(state, first, last) do
      [_ | _] = dates -> {:ok, dates}
      [] -> {:error, :tls_certificate_clock}
    end
  end

  defp certificate_path(roots, chain, dates, options) do
    case certificate_issuer_path(roots, Enum.reverse(chain), dates, options) do
      {:ok, _, _, _} = path -> path
      :error -> {:error, :tls_certificate_path}
    end
  end

  defp certificate_trust_input(state, first, last, root, path, options) do
    mfa = {:public_key, :pkix_path_validation, 3}
    depth = options.depth
    root_otp = :public_key.pkix_decode_cert(root, :otp)

    with [%{source: %{event: {_, :call, {_, _, [anchor, chain, path_options]}}}}] <-
           tls_scoped_calls(state, first, last, mfa),
         true <- certificate_input?(anchor, root, root_otp),
         true <- length(chain) == length(path),
         true <- Enum.all?(Enum.zip(chain, path), &certificate_copy?/1),
         [max_path_length: ^depth, verify_fun: {verify, context}] <- path_options,
         true <- is_function(verify, 4),
         %{issuer: ^root_otp, role: :client, crl_check: false, path_len: path_length} <- context,
         true <- path_length == length(path) do
      :ok
    else
      _ -> {:error, :tls_certificate_path_call}
    end
  end

  defp certificate_copy?({actual, der}),
    do: certificate_input?(actual, der, :public_key.pkix_decode_cert(der, :otp))

  defp certificate_input?({:cert, der, otp}, der, otp), do: true
  defp certificate_input?(der, der, _otp), do: true
  defp certificate_input?(otp, _der, otp), do: true
  defp certificate_input?(_value, _der, _otp), do: false

  defp certificate_clock_reads(state, first, last) do
    mfa = {:calendar, :universal_time, 0}
    reads = tls_scoped_calls(state, first, last, mfa)

    dates =
      for %{source: %{event: {pid, :call, {:calendar, :universal_time, []}}}, returned: clock} <-
            reads,
          {^pid, :return_from, ^mfa, {{y, m, d}, {h, minute, second}} = date} <- [clock.event],
          :calendar.valid_date({y, m, d}) and h in 0..23 and minute in 0..59 and second in 0..59,
          do: date

    if length(dates) == length(reads), do: dates, else: []
  end

  defp certificate_hostname(peer, host, options) do
    case Map.get(options, :server_name_indication, :undefined) do
      :disable ->
        :verified

      name ->
        name = if name == :undefined, do: host, else: name
        name = if is_atom(name), do: Atom.to_charlist(name), else: name
        reference = certificate_reference_name(name)

        hostname_options = options.customize_hostname_check

        if :public_key.pkix_verify_hostname(peer, [reference], hostname_options) do
          :verified
        else
          %{extensions: extensions} = certificate_record(peer, nil)
          names = Map.get(extensions, {2, 5, 29, 17}, [])
          {:refused, certificate_hostname_alert(name, names)}
        end
    end
  end

  defp certificate_hostname_alert(_name, []) do
    reason = {:bad_cert, {:hostname_check_failed, :missing_subject_altnames}}
    record_alert({:ssl_handshake, :path_validation_alert, 3}, 11, 42, reason)
  end

  defp certificate_hostname_alert(name, [_ | _] = names) do
    reason = {:bad_cert, {:hostname_check_failed, {:requested, name}, {:received, names}}}
    record_alert({:ssl_handshake, :path_validation_alert, 3}, 12, 42, reason)
  end

  defp certificate_reference_name(ip) when is_tuple(ip), do: {:ip, ip}

  defp certificate_reference_name(name) do
    case :inet.parse_strict_address(name) do
      {:ok, ip} -> {:ip, ip}
      _ -> {:dns_id, name}
    end
  end

  # The modeled path starts at a configured trust anchor. Its public keys,
  # policy inputs, and validity times come from the certificates and clock reads.
  defp certificate_issuer_path(roots, chain, dates, options) do
    Enum.find_value(roots, :error, fn root ->
      path = if hd(chain) === root, do: tl(chain), else: chain
      issuer = certificate_record(root, nil)

      with [_ | _] <- path,
           true <- certificate_valid_at?(issuer, dates),
           true <- certificate_policy?(issuer, length(path) - 1, options),
           {:ok, peer} <- checked_certificate_links(path, dates, options, issuer) do
        {:ok, peer.key, root, path}
      else
        _ -> nil
      end
    end)
  end

  defp checked_certificate_links(path, dates, options, issuer) do
    peer_position = length(path) - 1

    path
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, issuer}, fn {der, index}, {:ok, issuer} ->
      cert = certificate_record(der, issuer.key)
      remaining = peer_position - index
      ca_depth = if remaining == 0, do: :peer, else: remaining - 1

      if certificate_valid_at?(cert, dates) and certificate_policy?(cert, ca_depth, options) and
           certificate_signature_allowed?(cert, options) and
           :public_key.pkix_is_issuer(cert.otp, issuer.otp) and
           :public_key.pkix_verify(der, certificate_verify_key(issuer.key)) do
        {:cont, {:ok, cert}}
      else
        {:halt, :error}
      end
    end)
  end

  defp certificate_record(der, previous) do
    {:OTPCertificate, tbs, signature, _} = otp = :public_key.pkix_decode_cert(der, :otp)
    {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, algorithm, parameters}, key} = elem(tbs, 7)

    parameters =
      case {parameters, previous} do
        {nil_value, {^algorithm, _, previous}}
        when nil_value in [:NULL, :asn1_NOVALUE, {:null, :NULL}] ->
          previous

        {:asn1_NOVALUE, _} when algorithm in [{1, 3, 101, 112}, {1, 3, 101, 113}] ->
          {:namedCurve, algorithm}

        {{:params, parameters}, _} ->
          parameters

        _ ->
          parameters
      end

    extensions =
      case elem(tbs, 10) do
        :asn1_NOVALUE -> %{}
        list -> Map.new(list, fn {:Extension, oid, _, value} -> {oid, value} end)
      end

    %{
      otp: otp,
      key: {algorithm, key, parameters},
      signature: signature,
      validity: elem(tbs, 5),
      extensions: extensions
    }
  end

  defp certificate_verify_key(
         {_algorithm, {:RSAPublicKey, _, _} = key,
          {:"RSASSA-PSS-params", _, _, _, _} = parameters}
       ),
       do: {key, parameters}

  defp certificate_verify_key({_algorithm, {:RSAPublicKey, _, _} = key, _parameters}), do: key

  defp certificate_verify_key({_algorithm, {:ECPoint, _} = key, parameters}),
    do: {key, parameters}

  defp certificate_verify_key({_algorithm, key, {:"Dss-Parms", _, _, _} = parameters}),
    do: {key, parameters}

  defp certificate_verify_key({_algorithm, key, _parameters}), do: key

  defp certificate_signature_allowed?(cert, options) do
    configured = Map.get(options, :signature_algs_cert, :undefined)
    allowed = if configured == :undefined, do: options.signature_algs, else: configured
    signature = :ssl_cipher.signature_algorithm_to_scheme(cert.signature)
    :ssl_cipher.is_supported_sign(signature, tls13_signature_schemes(allowed))
  end

  defp tls13_signature_schemes(allowed) when is_list(allowed) do
    Enum.flat_map(allowed, fn
      :default -> []
      algorithm when is_atom(algorithm) -> [algorithm]
      {:sha512, :rsa} -> [:rsa_pkcs1_sha512]
      {:sha384, :rsa} -> [:rsa_pkcs1_sha384]
      {:sha256, :rsa} -> [:rsa_pkcs1_sha256]
      {:sha, :rsa} -> [:rsa_pkcs1_sha1]
      {:sha, :ecdsa} -> [:ecdsa_sha1]
      _ -> []
    end)
  end

  defp tls13_signature_schemes(_allowed), do: []

  defp verify_server_transcript(scheme, signature, digest, {_algorithm, key, _} = public_key) do
    {hash, sign, _} = :ssl_cipher.scheme_to_components(scheme)
    prefix = :binary.copy(<<32>>, 64)
    content = <<prefix::binary, "TLS 1.3, server CertificateVerify", 0, digest::binary>>

    case sign do
      kind when kind in [:rsa_pss_rsae, :rsa_pss_pss] ->
        options = [
          rsa_padding: :rsa_pkcs1_pss_padding,
          rsa_pss_saltlen: Map.fetch!(%{sha256: 32, sha384: 48, sha512: 64}, hash),
          rsa_mgf1_md: hash
        ]

        :public_key.verify(content, hash, signature, key, options)

      kind when kind in [:mldsa44, :mldsa65, :mldsa87, :slhdsa, :eddsa] ->
        :public_key.verify(content, :none, signature, certificate_verify_key(public_key))

      _ ->
        :public_key.verify(content, hash, signature, certificate_verify_key(public_key))
    end
  rescue
    _invalid in [ArgumentError, FunctionClauseError, KeyError] -> false
  end

  defp verify_server_transcript(_scheme, _signature, _digest, _key), do: false

  defp certificate_policy?(cert, depth, options) do
    extensions = cert.extensions

    supported = [
      {2, 5, 29, 14},
      {2, 5, 29, 15},
      {2, 5, 29, 17},
      {2, 5, 29, 19},
      {2, 5, 29, 35},
      {2, 5, 29, 37}
    ]

    usages = Map.get(extensions, {2, 5, 29, 15}, [:digitalSignature, :keyCertSign])
    purposes = Map.get(extensions, {2, 5, 29, 37}, [{1, 3, 6, 1, 5, 5, 7, 3, 1}])
    server? = {1, 3, 6, 1, 5, 5, 7, 3, 1} in purposes
    any_ca? = Map.get(options, :allow_any_ca_purpose) == true and {2, 5, 29, 37, 0} in purposes

    Enum.all?(Map.keys(extensions), &(&1 in supported)) and
      case depth do
        :peer ->
          server? and :digitalSignature in usages

        depth ->
          (server? or any_ca?) and :keyCertSign in usages and
            certificate_ca_depth?(Map.get(extensions, {2, 5, 29, 19}), depth)
      end
  end

  defp certificate_ca_depth?({:BasicConstraints, true, :asn1_NOVALUE}, _depth), do: true

  defp certificate_ca_depth?({:BasicConstraints, true, maximum}, depth) when is_integer(maximum),
    do: depth <= maximum

  defp certificate_ca_depth?(_constraints, _depth), do: false

  defp certificate_valid_at?(%{validity: {:Validity, first, last}}, dates) do
    Enum.all?(dates, fn {{year, _, _}, _} = date ->
      now = :calendar.datetime_to_gregorian_seconds(date)

      with {:ok, first} <- certificate_time(first, year, :start),
           {:ok, last} <- certificate_time(last, year, :finish) do
        first <= now and now <= last
      else
        _ -> false
      end
    end)
  end

  defp certificate_time({:utcTime, value}, year, boundary) do
    with <<digits::binary-size(2), _::binary>> = value <- List.to_string(value),
         {short_year, ""} <- Integer.parse(digits) do
      minimum_year = Integer.mod(year - 50, 100)

      century =
        case boundary do
          :start when short_year >= 50 -> 19
          :start -> div(year, 100)
          :finish when short_year < minimum_year -> div(year + 50, 100)
          :finish -> div(year - 49, 100)
        end

      certificate_time({:generalTime, Integer.to_string(century) <> value}, year, boundary)
    else
      _ -> :error
    end
  end

  defp certificate_time({:generalTime, value}, _year, _boundary) do
    case Regex.run(~r/\A(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z\z/, to_string(value)) do
      [_, y, m, d, h, minute, second] ->
        [y, m, d, h, minute, second] =
          Enum.map([y, m, d, h, minute, second], &String.to_integer/1)

        if :calendar.valid_date({y, m, d}) and h in 0..23 and minute in 0..59 and second in 0..59 do
          {:ok, :calendar.datetime_to_gregorian_seconds({{y, m, d}, {h, minute, second}})}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp certificate_time(_time, _year, _boundary), do: :error

  defp encrypted_extensions_alpn(:undefined), do: {:ok, :undefined}

  defp encrypted_extensions_alpn({:alpn, <<size, protocol::binary-size(size)>>}),
    do: {:ok, protocol}

  defp encrypted_extensions_alpn(_invalid), do: :error

  defp change_cipher_spec_next_input(
         state,
         source,
         %{
           source: %{mfa: {:tls_client_connection_1_3, name, 3}},
           event: %{value: {:internal, {:change_cipher_spec, _type}}}
         } = parent
       )
       when name in [
              :hello_middlebox_assert,
              :hello_retry_middlebox_assert,
              :start,
              :wait_sh,
              :wait_ee,
              :wait_cert_cr,
              :wait_cert,
              :wait_cv,
              :wait_finished
            ] do
    version = parent.current

    {state, name, data} =
      case name do
        :hello_middlebox_assert ->
          {state, :wait_ee, version.data}

        :hello_retry_middlebox_assert ->
          {state, :wait_sh, version.data}

        name ->
          specific = elem(version.data, 7)

          state =
            tls_exact(
              state,
              source,
              :tls_middlebox_origin,
              Map.fetch!(specific, :change_cipher_spec),
              :ignore
            )

          specific = Map.put(specific, :change_cipher_spec, :fail)
          {state, name, put_elem(version.data, 7, specific)}
      end

    arguments = elem(elem(source.event, 2), 2)

    state =
      tls_exact(state, source, :tls_callback_input, Enum.take(arguments, 2), [name, :no_record])

    {state, %{version | name: name, data: data, origin: {:tls_middlebox, parent.source.index}}}
  end

  defp change_cipher_spec_next_input(state, source, parent),
    do: passive_input(state, source, parent)

  defp worker_record_input(state, source, parent) do
    case Map.get(state.parsed, source.pid) do
      %{input: input} -> {state, input}
      nil -> {tls_failure(state, source, :tls_record_origin), parent.current}
    end
  end

  defp worker_next_event_input(state, source, parent) do
    case parent.source.mfa do
      {module, :initial_hello, 3}
      when module in [:tls_client_connection, :tls_client_connection_1_3] ->
        initial_hello_input(state, source, parent)

      {:tls_client_connection, :certify, 3} ->
        arguments = elem(elem(source.event, 2), 2)

        case parent.event do
          %{value: {:internal, packet}}
          when is_tuple(packet) and elem(packet, 0) in [:certificate, :server_hello_done] ->
            state = tls_exact(state, source, :tls_callback_input, Enum.at(arguments, 3), [])
            server_hello_next_input(state, source, arguments, parent)

          _ ->
            buffered_input(state, source, parent)
        end

      {module, name, 3}
      when {module, name} in [
             {:tls_client_connection_1_3, :wait_finished},
             {:tls_client_connection, :cipher}
           ] and is_map_key(parent, :connection_ready) ->
        arguments = elem(elem(source.event, 2), 2)

        state =
          tls_exact(
            state,
            source,
            :tls_callback_input,
            [
              Enum.at(arguments, 0),
              Enum.at(arguments, 1),
              Enum.at(arguments, 3)
            ],
            parent.connection_ready
          )

        {state, %{parent.current | name: :connection}}

      _ ->
        buffered_input(state, source, parent)
    end
  end

  # next_record keeps its State argument unchanged while ciphertext, cipher
  # state and the reversed fragment accumulator advance in separate arguments.
  # The final helper commits them together. Every input starts at the modeled
  # caller version, never at a checked helper argument or return.
  defp receiver_record_input(
         state,
         %{mfa: {:tls_gen_connection, :next_record, 2}} = source,
         arguments,
         version,
         position
       ) do
    buffers = elem(version.data, 11)

    parsed = %{
      input: version,
      buffer: elem(buffers, 1),
      buffers: buffers,
      remaining: elem(buffers, 3),
      states: elem(version.data, 10),
      fragments: [],
      early_data: false,
      record: :no_record,
      origin: source.index
    }

    state
    |> put_in([:parsed, source.pid], parsed)
    |> record_arguments(source, arguments, [version.name, version.data], position)
  end

  defp receiver_record_input(
         state,
         %{mfa: {:tls_gen_connection, :next_record, arity}} = source,
         arguments,
         version,
         position
       ) do
    case Map.fetch(state.parsed, source.pid) do
      {:ok, parsed} ->
        buffers = parsed.buffers
        check = Map.get(elem(version.data, 4), :padding_check, true)

        expected =
          case arity do
            3 ->
              [version.name, buffers, version.data]

            5 ->
              [version.data, parsed.remaining, parsed.states, buffers, check]

            7 ->
              [
                version.data,
                parsed.remaining,
                parsed.states,
                check,
                buffers,
                parsed.early_data,
                Enum.reverse(parsed.fragments)
              ]
          end

        record_arguments(state, source, arguments, expected, position)

      :error ->
        tls_failure(state, source, :tls_record_origin)
    end
  end

  defp receiver_record_input(
         state,
         %{mfa: {:tls_gen_connection, :next_record_done, 4}} = source,
         arguments,
         version,
         position
       ) do
    case Map.fetch(state.parsed, source.pid) do
      {:ok, parsed} ->
        buffers = parsed.buffers |> put_elem(3, parsed.remaining)
        expected = [version.data, buffers, parsed.states, selected_record(parsed)]
        record_arguments(state, source, arguments, expected, position)

      :error ->
        tls_failure(state, source, :tls_record_origin)
    end
  end

  defp receiver_record_input(
         state,
         %{mfa: {:tls_gen_connection, :handle_protocol_record, 3}} = source,
         arguments,
         version,
         position
       ) do
    case Map.get(state.parsed, source.pid) do
      nil ->
        tls_failure(state, source, :tls_record_origin)

      _parsed ->
        expected = [handshake_record(state, source.pid), version.name, version.data]
        record_arguments(state, source, arguments, expected, position)
    end
  end

  defp receiver_record_input(state, _source, _arguments, _version, _position), do: state

  defp record_arguments(state, source, actual, expected, state_position) do
    tls_exact(
      state,
      source,
      :tls_record_input,
      List.delete_at(actual, state_position),
      List.delete_at(expected, state_position)
    )
  end

  # The first callback changes the receiver before its next_event helper. Build
  # that version forward from its entry and completed native helper returns;
  # neither next_event's checked state nor a later system snapshot supplies it.
  defp initial_hello_input(state, source, parent) do
    data = parent.input.data
    environment = elem(data, 2)
    options = elem(data, 4)
    handshake = elem(data, 6)
    states = elem(data, 10)
    versions = Map.fetch!(options, :versions)
    hello_version = hd(versions)
    use_ticket = Map.fetch!(options, :use_ticket)
    scope = Map.put(Map.fetch!(state.pairs, parent.source.index), :returned, source)

    with [{:call, from}, {:start, timeout}, _] <- parent.arguments,
         true <- Map.fetch!(options, :session_tickets) != :auto,
         {:ok, shares} <- hello_shares(state, scope, options),
         {:ok, ^shares, _} <-
           hello_fact(
             state,
             parent,
             source,
             {:tls_client_connection_1_3, :maybe_generate_client_shares, 1},
             [options]
           ),
         {:ok, {^use_ticket, ^data}, _} <-
           hello_fact(
             state,
             parent,
             source,
             {:tls_client_connection_1_3, :maybe_automatic_session_resumption, 1},
             [data]
           ),
         {:ok, tickets, _} <-
           hello_fact(
             state,
             parent,
             source,
             {:tls_handshake_1_3, :get_ticket_data, 3},
             [source.pid, Map.fetch!(options, :session_tickets), use_ticket]
           ),
         {:ok, nonce} <- hello_nonce(state, scope, options),
         {:ok, ^nonce, _} <-
           hello_fact(state, parent, source, {:tls_handshake, :ocsp_nonce, 1}, [options]),
         arguments = [
           elem(environment, 9),
           elem(environment, 10),
           states,
           options,
           elem(elem(data, 8), 1),
           elem(elem(handshake, 5), 0),
           shares,
           tickets,
           nonce,
           elem(environment, 12),
           elem(environment, 17)
         ],
         {:ok, hello0, _} <-
           hello_fact(state, parent, source, {:tls_handshake, :client_hello, 11}, arguments),
         hello1 = hello_early_data(hello0, Map.fetch!(options, :early_data), hello_version),
         {:ok, ^hello1, _} <-
           hello_fact(
             state,
             parent,
             source,
             {:tls_handshake_1_3, :maybe_add_early_data_indication, 3},
             [hello0, Map.fetch!(options, :early_data), hello_version]
           ),
         {:ok, hello2, _} <-
           hello_fact(
             state,
             parent,
             source,
             {:tls_handshake_1_3, :maybe_add_binders, 3},
             [hello1, tickets, hello_version]
           ),
         maximum = Map.get(elem(hello1, 6), :max_frag_enum, :undefined),
         expected_states = hello_fragment_limit(maximum, states),
         {:ok, ^expected_states, _} <-
           hello_fact(
             state,
             parent,
             source,
             {:ssl_record, :maybe_set_max_fragment_length, 2},
             [maximum, states]
           ),
         state2 =
           data
           |> put_elem(10, expected_states)
           |> put_elem(3, put_elem(elem(data, 3), 5, hello_version)),
         {:ok, fragment} <- client_hello_fragment(hello2),
         {messages, _previous} = elem(handshake, 3),
         history = {[fragment | messages], messages},
         {:ok, encoded, encoded_states} <-
           encode_handshake_records(state, source, fragment, hello_version, expected_states),
         {:ok, {^encoded, ^encoded_states, ^history}, _} <-
           hello_fact(
             state,
             parent,
             source,
             {:tls_gen_connection, :encode_handshake, 4},
             [hello2, hello_version, expected_states, elem(handshake, 3)]
           ),
         queued_handshake =
           handshake |> put_elem(3, history) |> put_elem(31, [elem(handshake, 31), encoded]),
         queued = state2 |> put_elem(6, queued_handshake) |> put_elem(10, encoded_states),
         {:ok, ^queued, _} <-
           hello_fact(
             state,
             parent,
             source,
             {:tls_gen_connection, :queue_handshake, 2},
             [hello2, state2]
           ),
         true <- use_ticket == [:undefined] or Map.fetch!(options, :early_data) == :undefined,
         {:ok, {:ok, ^queued}, _} <-
           hello_fact(
             state,
             parent,
             source,
             {:tls_client_connection_1_3, :maybe_send_early_data, 1},
             [queued]
           ),
         [write] <-
           Enum.filter(state.transport.writes, fn write ->
             write.port == state.owners[source.pid].family.port and
               write.source.pid == source.pid and parent.source.index < write.source.index and
               write.returned.index < source.index
           end),
         true <- write.bytes === IO.iodata_to_binary(elem(queued_handshake, 31)),
         sent = put_elem(queued, 6, put_elem(queued_handshake, 31, [])),
         {:ok, {^sent, []}, sent_index} <-
           hello_fact(
             state,
             parent,
             source,
             {:tls_gen_connection, :send_handshake_flight, 1},
             [queued]
           ) do
      requested = if hd(versions) >= {3, 3}, do: {3, 3}, else: Enum.min(versions)

      stapling =
        Map.merge(elem(handshake, 32), %{
          ocsp_nonce: nonce,
          configured: Map.has_key?(options, :stapling)
        })

      handshake = elem(sent, 6) |> put_elem(30, shares) |> put_elem(32, stapling)

      expected =
        sent
        |> put_elem(3, put_elem(elem(data, 3), 5, requested))
        |> put_elem(6, handshake)
        |> put_elem(8, elem(data, 8))
        |> put_elem(9, put_elem(elem(sent, 9), 1, from))

      name = if versions == [{3, 4}], do: :wait_sh, else: :hello
      arguments = elem(elem(source.event, 2), 2)

      state =
        tls_exact(state, source, :tls_initial_hello_helper, Enum.take(arguments, 2), [
          name,
          :no_record
        ])

      actions = [{{:timeout, :handshake}, timeout, :close}]
      state = tls_exact(state, source, :tls_initial_hello_actions, Enum.at(arguments, 3), actions)

      {state,
       %{
         parent.input
         | name: name,
           data: expected,
           origin: {:tls_initial_hello, parent.source.index, sent_index}
       }}
    else
      _ -> {tls_failure(state, source, :tls_initial_hello_origin), parent.current}
    end
  end

  defp hello_fact(state, parent, source, mfa, arguments) do
    calls =
      Map.get(state.pair_index, {source.pid, mfa}, [])
      |> Enum.filter(fn pair ->
        parent.source.index < pair.source.index and pair.returned.index < source.index and
          pair.source.event === {source.pid, :call, {elem(mfa, 0), elem(mfa, 1), arguments}}
      end)

    case calls do
      [%{returned: %{event: {_, :return_from, ^mfa, value}}} = pair] ->
        {:ok, value, pair.returned.index}

      _ ->
        {:error, mfa}
    end
  end

  defp hello_fragment_limit({:max_frag_enum, enum}, states) when enum in 1..4,
    do: Map.put(states, :max_fragment_length, Bitwise.bsl(1, 8 + enum))

  defp hello_fragment_limit(_maximum, states), do: states

  defp client_hello_fragment(
         {:client_hello, {major, minor}, <<random::binary-size(32)>>, session, _cookie, suites,
          extensions}
       )
       when is_map(extensions) do
    encoded = client_hello_extensions(extensions)

    body =
      IO.iodata_to_binary([
        <<major, minor>>,
        random,
        hello_vector(session, 8),
        hello_vector(suites, 16),
        <<1, 0>>,
        hello_vector(encoded, 16)
      ])

    {:ok, [1, <<byte_size(body)::24>>, body]}
  rescue
    _malformed in [ArgumentError, FunctionClauseError, KeyError] -> :error
  catch
    :unsupported_client_hello_extension -> :error
  end

  defp client_hello_fragment(_hello), do: :error

  defp client_hello_extensions(extensions) do
    {psk, extensions} = Map.pop(extensions, :pre_shared_key, :undefined)

    encoded =
      Enum.reduce(Map.to_list(extensions), [], fn {_key, extension}, encoded ->
        [client_hello_extension(extension) | encoded]
      end)

    [encoded, client_hello_extension(psk)]
  end

  defp client_hello_extension(:undefined), do: []
  defp client_hello_extension({:renegotiation_info, :undefined}), do: []

  defp client_hello_extension({:renegotiation_info, <<0>>}),
    do: hello_extension(65_281, <<0>>)

  defp client_hello_extension({:renegotiation_info, bytes}),
    do: hello_extension(65_281, hello_vector(bytes, 8))

  defp client_hello_extension({:alpn, protocols}),
    do: hello_extension(16, hello_vector(protocols, 16))

  defp client_hello_extension({:next_protocol_negotiation, protocols}),
    do: hello_extension(13_172, protocols)

  defp client_hello_extension({:elliptic_curves, curves}) do
    groups = for curve <- curves, do: <<hello_enum(@handshake_curve_oids, curve)::16>>
    hello_extension(10, hello_vector(groups, 16))
  end

  defp client_hello_extension({:supported_groups, groups}) do
    ids = for group <- groups, do: <<hello_enum(@handshake_groups, group)::16>>
    hello_extension(10, hello_vector(ids, 16))
  end

  defp client_hello_extension({:ec_point_formats, formats}),
    do: hello_extension(11, hello_vector(formats, 8))

  defp client_hello_extension({:srp, user}),
    do: hello_extension(12, hello_vector(user, 8))

  defp client_hello_extension({kind, schemes})
       when kind in [:hash_sign_algos, :signature_algorithms, :signature_algorithms_cert] do
    code = if kind == :signature_algorithms_cert, do: 50, else: 13
    values = for scheme <- schemes, do: <<hello_signature_code(scheme)::16>>
    hello_extension(code, hello_vector(values, 16))
  end

  defp client_hello_extension({:sni, []}), do: hello_extension(0, <<>>)

  defp client_hello_extension({:sni, name}),
    do: hello_extension(0, hello_vector([0, hello_vector(name, 16)], 16))

  defp client_hello_extension({:use_srtp, profiles, mki}),
    do: hello_extension(14, [hello_vector(profiles, 16), hello_vector(mki, 8)])

  defp client_hello_extension({:max_frag_enum, size}), do: hello_extension(1, <<size>>)

  defp client_hello_extension({:client_hello_versions, versions}) do
    values = for {major, minor} <- versions, do: <<major, minor>>
    hello_extension(43, hello_vector(values, 8))
  end

  defp client_hello_extension({:key_share_client_hello, shares}) do
    values =
      Enum.map(shares, fn {:key_share_entry, group, key} ->
        [<<hello_enum(@handshake_groups, group)::16>>, hello_vector(key, 16)]
      end)

    hello_extension(51, hello_vector(values, 16))
  end

  defp client_hello_extension({:psk_key_exchange_modes, modes}) do
    values = Enum.map(modes, &Map.fetch!(%{psk_ke: 0, psk_dhe_ke: 1}, &1))
    hello_extension(45, hello_vector(values, 8))
  end

  defp client_hello_extension(
         {:pre_shared_key_client_hello, {:offered_psks, identities, binders}}
       ) do
    identities =
      Enum.map(identities, fn {:psk_identity, identity, age} ->
        [hello_vector(identity, 16), <<age::32>>]
      end)

    binders = Enum.map(binders, &hello_vector(&1, 8))
    hello_extension(41, [hello_vector(identities, 16), hello_vector(binders, 16)])
  end

  defp client_hello_extension({:cookie, cookie}),
    do: hello_extension(44, hello_vector(cookie, 16))

  defp client_hello_extension({:early_data_indication}), do: hello_extension(42, <<>>)

  defp client_hello_extension({:certificate_authorities, authorities}) do
    names = Enum.map(authorities, &hello_vector(:public_key.pkix_encode(:Name, &1, :otp), 16))
    hello_extension(47, hello_vector(names, 16))
  end

  defp client_hello_extension(
         {:certificate_status_request, type, {:ocsp_status_request, identifiers, extensions}}
       ) do
    ids = Enum.map(identifiers, &hello_vector(&1, 16))
    encoded = if extensions == [], do: <<>>, else: :public_key.der_encode(:Extensions, extensions)
    hello_extension(5, [type, hello_vector(ids, 16), hello_vector(encoded, 16)])
  end

  defp client_hello_extension(_extension), do: throw(:unsupported_client_hello_extension)

  defp hello_extension(code, payload), do: [<<code::16>>, hello_vector(payload, 16)]

  defp hello_vector(value, width) do
    length = IO.iodata_length(value)
    if length >= Bitwise.bsl(1, width), do: throw(:unsupported_client_hello_extension)
    [<<length::size(width)>>, value]
  end

  defp hello_enum(table, value) do
    Enum.find_value(table, fn {id, entry} -> if entry == value, do: id end) ||
      throw(:unsupported_client_hello_extension)
  end

  defp hello_signature_code({hash, :rsa_pss_rsae}),
    do: 0x0800 + hello_enum(Enum.map(4..6, &{&1, handshake_hash(&1)}), hash)

  defp hello_signature_code({hash, :rsa_pss_pss}),
    do: 0x0805 + hello_enum(Enum.map(4..6, &{&1, handshake_hash(&1)}), hash)

  defp hello_signature_code({hash, sign}) do
    hash = hello_enum(Enum.map(0..6, &{&1, handshake_hash(&1)}), hash)
    sign = hello_enum(Enum.map(0..3, &{&1, handshake_sign(&1)}), sign)
    Bitwise.bsl(hash, 8) + sign
  end

  defp hello_signature_code(scheme), do: hello_enum(@handshake_signatures, scheme)

  defp hello_shares(state, scope, %{versions: [{3, 4} | _], psk_groups: groups}) do
    Enum.reduce_while(groups, {:ok, []}, fn group, {:ok, shares} ->
      case handshake_generated_share(state, scope, group) do
        {:ok, exchange} -> {:cont, {:ok, shares ++ [{:key_share_entry, group, exchange}]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, shares} -> {:ok, {:key_share_client_hello, shares}}
      :error -> :error
    end
  end

  defp hello_shares(_state, _scope, _options), do: {:ok, :undefined}

  defp hello_nonce(state, scope, %{stapling: %{ocsp_nonce: true}}) do
    with {:ok, nonce} when byte_size(nonce) == 32 <-
           handshake_primitive(state, scope, {:crypto, :strong_rand_bytes, 1}, [32]) do
      {:ok, <<4, 32, nonce::binary>>}
    else
      _ -> :error
    end
  end

  defp hello_nonce(_state, _scope, _options), do: {:ok, :undefined}

  defp hello_early_data(hello, bytes, {3, 4}) when is_binary(bytes) and byte_size(bytes) > 0,
    do: put_elem(hello, 6, Map.put(elem(hello, 6), :early_data, {:early_data_indication}))

  defp hello_early_data(hello, _bytes, _version), do: hello

  defp passive_input(
         state,
         source,
         %{source: %{mfa: {:tls_gen_connection, :gen_info, 3}}} = parent
       ) do
    family = state.owners[source.pid].family

    case parent.event do
      %{value: {:info, {:tcp_passive, port}}, origin: origin} when port == family.port ->
        bound? = Enum.any?(state.transport.passive, &(&1.received.index == origin))
        state = tls_exact(state, source, :tls_passive_origin, bound?, true)
        passive_transition(state, source, parent)

      _ ->
        {state, parent.current}
    end
  end

  defp passive_input(state, _source, parent), do: {state, parent.current}

  defp passive_transition(state, source, parent) do
    version = parent.current
    data = version.data
    receiving? = elem(elem(data, 9), 1) != :undefined
    empty? = elem(elem(data, 11), 3) == []
    options = active_options(state, parent.source.index, source)

    if receiving? and empty? do
      state = tls_exact(state, source, :tls_passive_option, length(options), 1)
      {state, version}
    else
      state = tls_exact(state, source, :tls_passive_option, options, [])
      specific = Map.put(elem(data, 7), :active_n_toggle, true)

      version = %{
        version
        | data: put_elem(data, 7, specific),
          origin: {:tls_passive, parent.source.index, parent.event.origin, version.origin}
      }

      {state, version}
    end
  end

  defp active_options(state, first, source) do
    port = state.owners[source.pid].family.port

    Enum.filter(state.transport.options, fn option ->
      option.port == port and option.source.pid == source.pid and
        option.source.index > first and option.returned.index < source.index and
        is_integer(option.mode)
    end)
  end

  defp active_option_return(state, %{mfa: {:prim_inet, :setopts, 2}} = source) do
    family = state.owners[source.pid].family

    options =
      Enum.filter(state.transport.options, &(&1.returned.index == source.index))

    case {options, Map.get(state.frames, source.pid, [])} do
      {[%{mode: mode} = option], [frame | rest]}
      when is_integer(mode) and source.pid == family.owner ->
        version = frame.current
        specific = elem(version.data, 7)
        expected = Map.fetch!(specific, :active_n)
        state = tls_exact(state, source, :tls_active_option_copy, mode, expected)

        specific =
          specific |> Map.put(:active_n_toggle, false) |> Map.put(:socket_active, expected)

        version = %{
          version
          | data: put_elem(version.data, 7, specific),
            origin: {:tls_active_option, option.source.index, source.index}
        }

        put_in(state.frames[source.pid], [%{frame | current: version} | rest])

      _ ->
        state
    end
  end

  defp active_option_return(state, _source), do: state

  defp recv_input(state, source, parent) do
    case parent.event do
      %{value: {{:call, from}, {:recv, length, _timeout}}} ->
        version = parent.current
        recv = elem(version.data, 9) |> put_elem(1, from) |> put_elem(2, length)
        origin = {:tls_recv, parent.source.index, parent.event.origin}
        {state, %{version | data: put_elem(version.data, 9, recv), origin: origin}}

      _ ->
        {tls_failure(state, source, :tls_recv_origin), parent.current}
    end
  end

  defp sender_constructed(state, source, parent) do
    case Map.get(state.encoded, source.pid) do
      %{result: {_bytes, states}, origin: origin, plaintext: plaintext} ->
        data = parent.input.data

        data =
          data |> put_elem(2, states) |> put_elem(3, elem(data, 3) + IO.iodata_length(plaintext))

        {state, %{parent.input | data: data, origin: origin}}

      nil ->
        {tls_failure(state, source, :tls_encode_origin), parent.current}
    end
  end

  defp sender_forward_copies(state, source, arguments, parent) do
    [transport, socket, records, from, _data] = arguments
    family = state.owners[source.pid].family
    environment = elem(parent.input.data, 1)
    expected = {elem(environment, 5), family.port, Enum.at(parent.arguments, 1)}
    actual = {transport, socket, from}
    state = tls_exact(state, source, :tls_forward_copy, actual, expected)

    case Map.get(state.encoded, source.pid) do
      %{result: {expected, _states}, origin: origin} ->
        state = tls_exact(state, source, :tls_record_copy, records, expected)
        copy = %{index: source.index, path: [2, 2, 2], origin: origin}
        Map.update!(state, :terms, &[copy | &1])

      nil ->
        tls_failure(state, source, :tls_encode_origin)
    end
  end

  defp buffered_input(
         state,
         source,
         %{source: %{mfa: {:ssl_gen_statem, :passive_receive, 3}}} = parent
       ) do
    if elem(elem(parent.current.data, 12), 1) > 0,
      do: consume_buffer(state, source, parent.current, elem(parent.current.data, 12)),
      else: {state, parent.current}
  end

  defp buffered_input(state, _source, parent), do: {state, parent.current}

  defp worker_copy(state, source, path, expected, origin) do
    if MapSet.member?(state.covered, {source.index, path}) do
      state
    else
      actual = native_term(source.event, path)
      state = tls_exact(state, source, :tls_worker_state_copy, actual, expected)
      state = tls_error_path(state, source, path, :tls_worker_state_copy)

      copy = %{index: source.index, path: path, origin: origin}
      Map.update!(state, :terms, &[copy | &1])
    end
  end

  defp native_term(value, []), do: value

  defp native_term(value, [position | path]) when is_tuple(value),
    do: native_term(elem(value, position), path)

  defp native_term(value, [position | path]) when is_list(value),
    do: native_term(Enum.at(value, position), path)

  defp result_data_path({:next_state, _, _}), do: [2]
  defp result_data_path({:next_state, _, _, _}), do: [2]
  defp result_data_path({:stop_and_reply, _, _, _}), do: [3]
  defp result_data_path({:stop, _, _}), do: [2]
  defp result_data_path({:keep_state, _}), do: [1]
  defp result_data_path({:keep_state, _, _}), do: [1]
  defp result_data_path({:ok, _}), do: [1]
  defp result_data_path({:no_record, _}), do: [1]
  defp result_data_path({:data, _, _, _, _}), do: []
  defp result_data_path(_result), do: nil

  defp worker_result_data_path({:tls_gen_connection, function, _arity}, {_record, _data})
       when function in [:next_record, :next_record_done],
       do: [1]

  defp worker_result_data_path(_mfa, result), do: result_data_path(result)

  defp record_call(state, source, :tls_sender, :send_reply, arguments) do
    frame = List.first(Map.get(state.frames, source.pid, []))
    family = state.owners[source.pid].family

    case {frame, Map.get(state.messages, source.pid)} do
      {%{source: parent}, %{value: {{:call, from}, {:application_data, _data}}} = message} ->
        writes =
          Enum.filter(state.transport.writes, fn write ->
            write.port == family.port and write.source.pid == source.pid and
              write.source.index > parent.index and write.returned.index < source.index
          end)

        case writes do
          [write] ->
            {_, :return_from, {:gen_tcp, :send, 2}, reply} = write.returned.event
            state = tls_exact(state, source, :tls_reply_copy, arguments, [from, reply])
            origin = {:tls_reply, message.origin, write.returned.index}
            copy = %{index: source.index, path: [2, 2], origin: origin}

            state
            |> Map.update!(:terms, &[copy | &1])
            |> put_in([:direct_replies, source.pid], %{
              from: from,
              reply: reply,
              origin: origin,
              last: state.pairs[source.index].returned.index
            })

          _ ->
            tls_failure(state, source, :tls_reply_origin)
        end

      _ ->
        tls_failure(state, source, :tls_reply_origin)
    end
  end

  defp record_call(state, source, :tls_handshake, :hello, _arguments) do
    frame = hd(state.frames[source.pid])

    case server_hello_selection(frame) do
      {:ok, hello, selected, stapling} ->
        data = frame.current.data
        environment = elem(data, 6)

        arguments = [
          hello,
          elem(data, 4),
          elem(data, 10),
          elem(elem(environment, 5), 0),
          elem(elem(data, 8), 1)
        ]

        state =
          arguments
          |> Enum.with_index()
          |> Enum.reduce(state, fn {expected, position}, state ->
            handshake_copy(state, source, [2, 2, position], expected, frame.input.origin)
          end)

        put_in(state.records[source.index], %{
          kind: :server_hello,
          result: {:next_state, :wait_sh, selected, stapling},
          selected: selected,
          stapling: stapling,
          origin: frame.input.origin
        })

      {:legacy, program} ->
        data = frame.current.data
        environment = elem(data, 6)
        session = elem(data, 8)

        state =
          handshake_copy(
            state,
            source,
            [2, 2],
            [
              program.hello,
              elem(data, 4),
              elem(data, 10),
              elem(elem(environment, 5), 0),
              elem(session, 1)
            ],
            frame.input.origin
          )

        put_in(state.records[source.index], %{
          kind: :legacy_hello,
          result: program.result,
          program: program
        })

      :error ->
        tls_failure(state, source, :tls_hello_negotiation_origin)
    end
  end

  defp record_call(state, source, :tls_client_connection_1_3, :handle_server_hello, _arguments) do
    frame = hd(state.frames[source.pid])

    case server_hello_program(state, source, frame) do
      {:ok, program} ->
        state =
          state
          |> handshake_copy(source, [2, 2, 0], program.hello, frame.input.origin)
          |> handshake_copy(source, [2, 2, 1], frame.current.data, frame.input.origin)

        [frame | rest] = state.frames[source.pid]
        frame = Map.put(frame, :server_hello_program, program)

        state
        |> put_in([:frames, source.pid], [frame | rest])
        |> put_in([:records, source.index], %{
          kind: :server_hello_state,
          result: program.result,
          data: program.active,
          name: program.next_name,
          origin: {:tls_server_hello_state, source.index}
        })

      :error ->
        tls_failure(state, source, :tls_server_hello_origin)
    end
  end

  defp record_call(state, source, :tls_handshake_1_3, :update_start_state, _arguments) do
    case hd(state.frames[source.pid]) do
      %{server_hello_program: _program} -> server_hello_helper(state, source, :start)
      frame -> retry_start_record(state, source, frame)
    end
  end

  defp record_call(state, source, :tls_handshake_1_3, :calculate_handshake_secrets, _arguments),
    do: server_hello_helper(state, source, :secrets)

  defp record_call(state, source, :tls_handshake_1_3, :replace_ch1_with_message_hash, _arguments) do
    frame = hd(state.frames[source.pid])
    data = frame.current.data
    handshake = elem(data, 6)
    parameters = Map.fetch!(elem(data, 10), :pending_read).security_parameters
    hash = elem(parameters, 8)
    scope = Map.fetch!(state.pairs, source.index)

    with {[retry, first | previous], last} <- elem(handshake, 3),
         {:ok, digest} <- handshake_primitive(state, scope, {:crypto, :hash, 2}, [hash, first]) do
      message_hash = [254, 0, 0, byte_size(digest), digest]
      history = {[retry, message_hash | previous], last}
      expected = put_elem(data, 6, put_elem(handshake, 3, history))
      origin = {:tls_retry_history, source.index}

      state
      |> handshake_copy(source, [2, 2], [data], frame.current.origin)
      |> put_in([:records, source.index], %{
        kind: :handshake_state,
        result: expected,
        origin: origin
      })
    else
      _ -> tls_failure(state, source, :tls_handshake_origin)
    end
  end

  defp record_call(state, source, :tls_handshake_1_3, function, _arguments)
       when function in [
              :validate_finished,
              :finished,
              :calculate_read_traffic_secrets,
              :calculate_write_traffic_secrets,
              :maybe_calculate_resumption_master_secret,
              :prepare_connection
            ] do
    frame = hd(state.frames[source.pid])

    case handshake_connection_result(state, source, function, frame) do
      {:ok, arguments, kind, result} ->
        origin = {:tls_connection_secrets, source.index}

        state
        |> handshake_copy(source, [2, 2], arguments, frame.current.origin)
        |> put_in([:records, source.index], %{kind: kind, result: result, origin: origin})

      :error ->
        tls_failure(state, source, :tls_connection_secrets_origin)
    end
  end

  defp record_call(state, source, :ssl_record, function, _arguments)
       when function in [:step_encryption_state, :step_encryption_state_write] do
    frame = hd(state.frames[source.pid])
    data = frame.current.data
    directions = if function == :step_encryption_state, do: [:read, :write], else: [:write]

    states =
      Enum.reduce(directions, elem(data, 10), fn direction, states ->
        {pending, current} =
          if direction == :read,
            do: {:pending_read, :current_read},
            else: {:pending_write, :current_write}

        next =
          states
          |> Map.fetch!(pending)
          |> Map.put(:sequence_number, 0)
          |> Map.delete(:aead_handle)

        Map.put(states, current, next)
      end)

    origin = {:tls_encryption_step, source.index}

    state
    |> handshake_copy(source, [2, 2, 0], data, frame.current.origin)
    |> put_in([:records, source.index], %{
      kind: :handshake_state,
      result: put_elem(data, 10, states),
      origin: origin
    })
  end

  defp record_call(state, source, :ssl_record, :step_encryption_state_read, _arguments),
    do: server_hello_helper(state, source, :active)

  defp record_call(state, source, :tls_gen_connection, function, _arguments)
       when function in [:reinit, :reinit_handshake_data] do
    frame = hd(state.frames[source.pid])
    data = reinitialized_receiver(frame.current.data)
    origin = {:tls_receiver_reinitialized, source.index}

    state
    |> handshake_copy(source, [2, 2, 0], frame.current.data, frame.current.origin)
    |> put_in([:records, source.index], %{kind: :handshake_state, result: data, origin: origin})
  end

  defp record_call(state, source, :tls_sender, :update_connection_state, _arguments) do
    frame = hd(state.frames[source.pid])
    data = frame.current.data
    sender = Map.fetch!(elem(data, 7), :sender)
    states = elem(data, 10)
    write = Map.fetch!(states, :current_write)
    version = elem(elem(data, 3), 5)
    maximum = Map.get(states, :max_fragment_length, :undefined)
    message = {:new_write, write, version, maximum}
    origin = {:tls_receiver_write_update, source.index}

    state =
      handshake_copy(
        state,
        source,
        [2, 2],
        [sender, write, version, maximum],
        frame.current.origin
      )

    with {:ok, sent, receipt} <- write_update_receipt(state, source, sender),
         [cast] <-
           Enum.filter(
             Map.get(state.pair_index, {source.pid, {:gen_statem, :cast, 2}}, []),
             fn pair ->
               source.index < pair.source.index and
                 pair.returned.index < state.pairs[source.index].returned.index
             end
           ) do
      state
      |> handshake_copy(cast.source, [2, 2], [sender, message], origin)
      |> handshake_copy(cast.returned, [3], :ok, origin)
      |> handshake_copy(sent, [2], {:"$gen_cast", message}, origin)
      |> handshake_copy(sent, [3], sender, origin)
      |> handshake_copy(receipt, [2], {:"$gen_cast", message}, origin)
      |> put_in([:write_updates, receipt.index], %{message: message, origin: origin})
      |> put_in([:records, source.index], %{kind: :handshake_value, result: :ok, origin: origin})
    else
      _ -> tls_failure(state, source, :tls_write_update_origin)
    end
  end

  defp record_call(state, source, :tls_sender, function, _arguments)
       when function in [:handle_new_write_state, :key_update_at] do
    case hd(state.frames[source.pid]) do
      %{write_update: update} = frame ->
        {:new_write, write, version, maximum} = update.message

        {arguments, result} =
          case function do
            :handle_new_write_state ->
              states = elem(frame.input.data, 2)
              {[states, write, maximum], sender_write_state(states, write, maximum)}

            :key_update_at ->
              current = elem(elem(frame.input.data, 1), 8)
              {[version, write, current], sender_key_update(version, write, current)}
          end

        state
        |> handshake_copy(source, [2, 2], arguments, update.origin)
        |> put_in([:records, source.index], %{
          kind: :handshake_value,
          result: result,
          origin: update.origin
        })

      _ ->
        tls_failure(state, source, :tls_write_update_origin)
    end
  end

  defp record_call(state, source, :ssl_gen_statem, :prepare_connection, _arguments) do
    [frame | rest] = state.frames[source.pid]

    case legacy_finished_receiver(frame) do
      {:ok, frame} ->
        state = put_in(state.frames[source.pid], [frame | rest])
        prepared_receiver_record(state, source, frame)

      :error ->
        tls_failure(state, source, :tls_legacy_finished_origin)
    end
  end

  defp record_call(state, source, :ssl_record, :pending_connection_state, _arguments) do
    case hd(state.frames[source.pid]) do
      %{server_hello_program: program} ->
        server_hello_record(
          state,
          source,
          [elem(program.start, 10), :read],
          Map.fetch!(elem(program.start, 10), :pending_read)
        )

      _ ->
        state
    end
  end

  defp record_call(state, source, module, :callback_mode, _arguments) do
    case {get_in(state.machine_programs, [source.pid, :module_action]), tls_callback_mode(module)} do
      {%{modules: [^module | _], origin: origin}, {:ok, mode, _enter?}} ->
        put_in(state.records[source.index], %{
          kind: :handshake_value,
          result: mode,
          origin: origin
        })

      _ ->
        state
    end
  end

  defp record_call(state, source, module, :encode_data, arguments)
       when module in [:tls_record, :tls_record_1_3] do
    case sender_plaintext(state, source) do
      {:ok, plaintext} ->
        frame = hd(state.frames[source.pid])
        data = frame.input.data
        version = elem(elem(data, 1), 6)
        states = elem(data, 2)

        expected_args =
          if module == :tls_record, do: [plaintext, version, states], else: [plaintext, states]

        state = tls_exact(state, source, :tls_record_input, arguments, expected_args)

        case encode_records(state, source, plaintext, version, states) do
          {:ok, expected} ->
            put_in(state.records[source.index], %{
              result: expected,
              kind: :encode,
              plaintext: plaintext
            })

          :error ->
            tls_failure(state, source, :tls_encode_primitive_origin)
        end

      :error ->
        tls_failure(state, source, :tls_plaintext_origin)
    end
  end

  defp record_call(state, source, module, :encode_alert_record, arguments)
       when module in [:tls_record, :tls_record_1_3] do
    frame = hd(state.frames[source.pid])

    with {:ok, {:alert, level, description, _, _, _} = alert, version, states, program} <-
           alert_record_input(state, source, frame),
         {:ok, encoded, next} <-
           encode_record(state, source, <<level, description>>, version, states, 21) do
      expected_args =
        if module == :tls_record, do: [alert, version, states], else: [alert, states]

      state
      |> tls_exact(source, :tls_record_input, arguments, expected_args)
      |> put_in([:records, source.index], %{
        kind: :alert_encode,
        result: {encoded, next},
        program: program,
        origin: {:tls_alert_encoding, source.index}
      })
    else
      _ -> tls_failure(state, source, :tls_alert_origin)
    end
  end

  defp record_call(state, source, :tls_record, :get_tls_records, arguments) do
    frame = hd(state.frames[source.pid])
    version = frame.input
    data = version.data
    family = state.owners[source.pid].family

    case frame.event do
      %{value: {:info, {:tcp, port, bytes}}} when port == family.port ->
        buffers = elem(data, 11)
        environment = elem(data, 3)

        versions =
          if version.name in [:hello, :start] do
            [{3, 0}, {3, 4}, {3, 3}, {3, 2}, {3, 1}]
          else
            elem(environment, 5)
          end

        expected_args = [
          bytes,
          versions,
          elem(buffers, 1),
          Map.get(elem(data, 10), :max_fragment_length, :undefined),
          elem(environment, 2)
        ]

        state = tls_exact(state, source, :tls_record_input, arguments, expected_args)

        case parse_record_stream(expected_args) do
          {:ok, {records, buffer} = expected} ->
            parsed = %{
              input: version,
              buffer: buffer,
              buffers: buffers |> put_elem(1, buffer) |> put_elem(3, elem(buffers, 3) ++ records),
              remaining: elem(buffers, 3) ++ records,
              states: elem(data, 10),
              fragments: [],
              early_data: false,
              record: :no_record,
              origin: source.index
            }

            put_in(state.records[source.index], %{
              result: expected,
              kind: :records,
              parsed: parsed
            })

          {:alert, expected} ->
            put_in(state.records[source.index], %{result: expected, kind: :record_alert})

          {:error, _reason} ->
            tls_failure(state, source, :tls_record_parser_origin)
        end

      _ ->
        tls_failure(state, source, :tls_record_origin)
    end
  end

  defp record_call(state, source, :tls_gen_connection, :get_tls_handshakes, _arguments) do
    frame = hd(state.frames[source.pid])
    version = frame.current

    case handshake_record(state, source.pid) do
      {:ssl_tls, 22, _, fragment, _} ->
        state = worker_copy(state, source, [2, 2, 2], version.data, version.origin)
        state = handshake_copy(state, source, [2, 2, 0], fragment, version.origin)
        state = handshake_copy(state, source, [2, 2, 1], version.name, version.origin)

        case handshake_packets(fragment, version.name, version.data) do
          {:ok, result} ->
            state
            |> Map.update!(:handshake_rest, &Map.delete(&1, source.pid))
            |> put_in([:records, source.index], %{
              kind: :handshakes,
              result: result,
              input: version
            })

          {:exception, exception} ->
            put_in(state.records[source.index], %{
              kind: :handshake_exception,
              result: exception,
              input: version
            })

          :error ->
            tls_failure(state, source, :tls_handshake_parser_origin)
        end

      _ ->
        tls_failure(state, source, :tls_handshake_origin)
    end
  end

  defp record_call(state, source, :tls_gen_connection, function, _arguments)
       when function in [:tls_handshake_events, :unprocessed_events] do
    frame = hd(state.frames[source.pid])

    case Map.get(frame, :handshake_program) do
      nil ->
        tls_failure(state, source, :tls_handshake_origin)

      program ->
        {arguments, result} = handshake_program_call(source, function, program)

        state =
          arguments
          |> Enum.with_index()
          |> Enum.reduce(state, fn {expected, position}, state ->
            handshake_copy(state, source, [2, 2, position], expected, program.origin)
          end)

        put_in(state.records[source.index], %{
          kind: :handshake_value,
          result: result,
          origin: program.origin
        })
    end
  end

  defp record_call(state, source, module, :decode_cipher_text, arguments)
       when module in [:tls_record, :tls_record_1_3] do
    case Map.get(state.parsed, source.pid) do
      %{remaining: [record | _], states: states, input: input} ->
        expected_args =
          if module == :tls_record_1_3,
            do: [record, states],
            else: [
              elem(elem(input.data, 3), 5),
              record,
              states,
              Map.get(elem(input.data, 4), :padding_check, true)
            ]

        nested? =
          Enum.any?(state.records, fn {_index, record} ->
            Map.get(record, :pid) == source.pid and record.kind == :decode
          end)

        kind = if nested?, do: :decode_copy, else: :decode

        state = tls_exact(state, source, :tls_record_input, arguments, expected_args)

        case decode_record(state, source, module, expected_args) do
          {:ok, expected} ->
            put_in(state.records[source.index], %{result: expected, kind: kind, pid: source.pid})

          :error ->
            tls_failure(state, source, :tls_decode_primitive_origin)
        end

      _ ->
        tls_failure(state, source, :tls_record_origin)
    end
  end

  defp record_call(state, _source, _module, _function, _arguments), do: state

  defp prepared_receiver_record(state, source, frame) do
    data = reinitialized_receiver(frame.current.data)
    {data, reply} = acknowledged_receiver(data)
    origin = {:tls_receiver_prepared, source.index}

    state =
      state
      |> handshake_copy(
        source,
        [2, 2],
        [frame.current.data, :tls_gen_connection],
        frame.current.origin
      )
      |> put_in([:records, source.index], %{
        kind: :prepared_connection,
        result: {:no_record, data},
        data: data,
        origin: origin
      })

    case reply do
      {from, value} ->
        put_in(state.direct_replies[source.pid], %{
          from: from,
          reply: value,
          origin: origin,
          last: state.pairs[source.index].returned.index
        })

      nil ->
        state
    end
  end

  defp alert_record_input(
         state,
         source,
         %{
           source: %{mfa: {:tls_client_connection_1_3, :wait_cert_cr, 3}},
           event: %{value: {:internal, {:certificate_1_3, <<>>, entries} = certificate}}
         } = frame
       ) do
    data = frame.input.data

    with {:ok, pair, _peer, _key, {:refused, alert}} <-
           server_certificate_program(state, frame, source, entries) do
      role = elem(elem(data, 2), 1)
      version = elem(elem(data, 3), 5)
      send_alert = put_elem(alert, 4, role)
      program = %{certificate: certificate, pair: pair, alert: alert, send_alert: send_alert}
      {:ok, send_alert, version, elem(data, 10), program}
    end
  end

  defp alert_record_input(_state, _source, frame) do
    with {:ok, alert} <- sender_alert(frame.event) do
      data = frame.input.data
      {:ok, alert, elem(elem(data, 1), 6), elem(data, 2), :sender}
    end
  end

  # Decryption is constructed from the modeled read state and exact native
  # crypto arguments. A primitive's return is an origin; a TLS helper's return
  # is the value being checked and cannot supply its own expectation.
  defp decode_record(state, source, :tls_record_1_3, [record, states]),
    do: decode_record_13(state, source, record, states)

  defp decode_record(state, source, :tls_record, [{3, 4}, record, states, _padding]),
    do: decode_record_13(state, source, record, states)

  defp decode_record(state, source, :tls_record, [_version, record, states, padding]) do
    read = states.current_read

    if elem(read.security_parameters, 4) == 2,
      do: decode_record_aead(state, source, record, states),
      else: decode_record_cipher(state, source, record, states, padding)
  end

  defp decode_record_13(state, source, {:ssl_tls, 23, {3, 3}, fragment, _}, states) do
    read = states.current_read

    case Map.fetch(read, :aead_handle) do
      {:ok, handle} ->
        decode_record_13_aead(state, source, fragment, states, handle, false)

      :error ->
        cond do
          elem(read.security_parameters, 4) == 2 and Map.has_key?(read, :early_data) ->
            with {:ok, handle} <- record_aead_handle(state, source, read, false) do
              decode_record_13_aead(state, source, fragment, states, handle, true)
            end

          elem(read.security_parameters, 1) == <<0, 0>> ->
            {:ok, {{:ssl_tls, 23, {3, 4}, fragment, false}, states}}

          true ->
            {:ok,
             record_alert(
               {:tls_record_1_3, :decode_cipher_text, 2},
               0,
               20,
               {:record_type_mismatch, 23}
             )}
        end
    end
  end

  defp decode_record_13(_state, _source, {:ssl_tls, 21, {3, 3}, <<2, 47>>, _}, states),
    do: {:ok, {{:ssl_tls, 21, {3, 4}, <<2, 47>>, false}, states}}

  defp decode_record_13(_state, _source, {:ssl_tls, 21, {3, 3}, <<_level, alert>>, _}, states)
       when alert in [0, 90] and
              elem(states.current_read.security_parameters, 12) == :undefined,
       do: {:ok, {{:ssl_tls, 21, {3, 4}, <<2, alert>>, false}, states}}

  defp decode_record_13(_state, _source, {:ssl_tls, 20, {3, 3}, <<1>>, _}, states),
    do: {:ok, {{:ssl_tls, 20, {3, 4}, <<1>>, false}, states}}

  defp decode_record_13(_state, _source, {:ssl_tls, type, {3, 3}, fragment, _}, states)
       when elem(states.current_read.security_parameters, 1) == <<0, 0>>,
       do: {:ok, {{:ssl_tls, type, {3, 4}, fragment, false}, states}}

  defp decode_record_13(_state, _source, {:ssl_tls, type, _, _, _}, _states),
    do:
      {:ok,
       record_alert(
         {:tls_record_1_3, :decode_cipher_text, 2},
         0,
         20,
         {:record_type_mismatch, type}
       )}

  defp decode_record_13_aead(state, source, fragment, states, handle, early?) do
    read = states.current_read
    nonce = record_nonce(read.sequence_number, elem(read.cipher_state, 1))
    arguments = [handle, nonce, fragment, <<23, 3, 3, IO.iodata_length(fragment)::16>>]

    case record_primitive_event(state, source, {:crypto, :crypto_one_time_aead, 4}, arguments) do
      {:ok, {:return_from, plaintext}} when is_binary(plaintext) ->
        if early? and read.early_data.early_data_accepted and
             read.early_data.pending_early_data_size > 0 do
          decode_early_record(plaintext, states, handle)
        else
          read = read |> Map.put(:sequence_number, read.sequence_number + 1)
          read = Map.put(read, :aead_handle, handle)
          {:ok, {decode_inner_record(plaintext), Map.put(states, :current_read, read)}}
        end

      {:ok, {tag, _reason}} when tag in [:return_from, :exception_from] ->
        if early? and read.early_data.trial_decryption and
             not read.early_data.early_data_accepted and
             read.early_data.pending_early_data_size > 0 do
          ignore_early_record(fragment, states, handle)
        else
          ordinal = if tag == :return_from, do: 0, else: 1

          {:ok,
           record_alert({:tls_record_1_3, :decipher_aead, 4}, ordinal, 20, :decryption_failed)}
        end

      :error ->
        :error
    end
  end

  defp decode_inner_record(<<>>),
    do: record_alert({:tls_record_1_3, :decode_inner_plaintext, 1}, 1, 10, :empty_alert)

  defp decode_inner_record(plaintext) do
    length = byte_size(plaintext) - 1
    <<content::binary-size(^length), type>> = plaintext

    cond do
      type == 0 ->
        decode_inner_record(content)

      type not in [21, 22, 23] ->
        decode_inner_record(<<>>)

      length > 16_384 ->
        record_alert(
          {:tls_record_1_3, :decode_inner_plaintext, 1},
          0,
          22,
          {:plain_text_too_long, length}
        )

      true ->
        {:ssl_tls, type, {3, 4}, content, false}
    end
  end

  defp ignore_early_record(fragment, states, handle) do
    read = states.current_read
    tag = if elem(read.security_parameters, 3) == 11, do: 8, else: 16
    remaining = read.early_data.pending_early_data_size - max(1, byte_size(fragment) - 1 - tag)

    if remaining < 0 do
      {:ok,
       record_alert(
         {:tls_record_1_3, :ignore_early_data, 6},
         0,
         20,
         {:decryption_failed, {:max_early_data_threshold_exceeded, remaining}}
       )}
    else
      early = %{read.early_data | pending_early_data_size: remaining}
      read = read |> Map.put(:early_data, early) |> Map.put(:aead_handle, handle)
      {:ok, {:no_record, Map.put(states, :current_read, read)}}
    end
  end

  defp decode_early_record(plaintext, states, handle) do
    read = states.current_read

    case decode_inner_record(plaintext) do
      {:ssl_tls, 22, _, <<5, _::binary>>, _} = record ->
        {:ok,
         {record,
          Map.put(states, :current_read, %{read | sequence_number: read.sequence_number + 1})}}

      {:ssl_tls, 23, _, data, _} = record ->
        remaining = read.early_data.pending_early_data_size - max(1, byte_size(data))

        if remaining < 0 do
          {:ok,
           record_alert(
             {:tls_record_1_3, :process_early_data, 6},
             0,
             10,
             {:too_much_early_data, {:max_early_data_threshold_exceeded, remaining}}
           )}
        else
          early = %{read.early_data | pending_early_data_size: remaining}
          read = read |> Map.put(:early_data, early) |> Map.put(:aead_handle, handle)
          read = Map.put(read, :sequence_number, read.sequence_number + 1)
          {:ok, {put_elem(record, 4, true), Map.put(states, :current_read, read)}}
        end

      {:ssl_tls, type, _, _, _} ->
        {:ok,
         record_alert(
           {:tls_record_1_3, :process_early_data, 6},
           1,
           10,
           {:unexpected_inner_type, type}
         )}

      _alert ->
        :error
    end
  end

  defp decode_record_aead(
         state,
         source,
         {:ssl_tls, type, {major, minor}, fragment, _} = record,
         states
       ) do
    read = states.current_read
    cipher = read.cipher_state
    bulk = elem(read.security_parameters, 3)
    sequence = read.sequence_number
    cipher = if bulk == 9, do: put_elem(cipher, 5, <<sequence::64>>), else: cipher
    tag_length = elem(cipher, 6)
    prefix = if bulk == 9, do: 0, else: 8
    length = byte_size(fragment) - prefix - tag_length

    if length < 0 do
      {:ok, record_alert({:ssl_record, :decipher_aead, 5}, 1, 20, :decryption_failed)}
    else
      <<explicit::binary-size(^prefix), content::binary-size(^length), tag::binary>> = fragment

      nonce =
        if bulk == 9 do
          record_primitive(state, source, {:crypto, :exor, 2}, [
            <<0::32, sequence::64>>,
            elem(cipher, 1)
          ])
        else
          <<salt::binary-size(4), _::binary>> = elem(cipher, 1)
          {:ok, salt <> explicit}
        end

      with {:ok, nonce} <- nonce,
           {:ok, algorithm} <- record_aead_algorithm(bulk, elem(cipher, 2)),
           {:ok, {kind, plaintext}} <-
             record_primitive_event(state, source, {:crypto, :crypto_one_time_aead, 7}, [
               algorithm,
               elem(cipher, 2),
               nonce,
               content,
               <<sequence::64, type, major, minor, length::16>>,
               tag,
               false
             ]) do
        if kind == :return_from and is_binary(plaintext) do
          read = %{read | cipher_state: cipher, sequence_number: sequence + 1}
          {:ok, {put_elem(record, 3, plaintext), Map.put(states, :current_read, read)}}
        else
          ordinal = if kind == :return_from, do: 0, else: 1
          {:ok, record_alert({:ssl_record, :decipher_aead, 5}, ordinal, 20, :decryption_failed)}
        end
      else
        _ -> :error
      end
    end
  end

  defp decode_record_cipher(
         state,
         source,
         {:ssl_tls, type, version, fragment, _} = record,
         states,
         padding
       ) do
    read = states.current_read

    case decipher_record(state, source, fragment, version, read, padding) do
      {:ok, plaintext, mac, cipher} ->
        with {:ok, expected} <- record_read_mac(state, source, type, plaintext, version, read) do
          if mac === expected do
            read = %{read | cipher_state: cipher, sequence_number: read.sequence_number + 1}
            {:ok, {put_elem(record, 3, plaintext), Map.put(states, :current_read, read)}}
          else
            {:ok, record_alert({:tls_record, :decode_cipher_text, 4}, 0, 20, :undefined)}
          end
        end

      {:alert, alert} ->
        {:ok, alert}

      :error ->
        :error
    end
  end

  defp record_read_mac(_state, _source, _type, _plaintext, _version, read)
       when elem(read.security_parameters, 7) == 0,
       do: {:ok, <<>>}

  defp record_read_mac(state, source, type, plaintext, {major, minor}, read) do
    with {:ok, algorithm} <- record_mac_algorithm(elem(read.security_parameters, 7)) do
      header = <<read.sequence_number::64, type, major, minor, byte_size(plaintext)::16>>

      record_primitive(state, source, {:crypto, :mac, 4}, [
        :hmac,
        algorithm,
        read.mac_secret,
        [header, plaintext]
      ])
    end
  end

  defp decipher_record(_state, _source, fragment, _version, read, _padding)
       when elem(read.security_parameters, 3) == 0,
       do: {:ok, fragment, <<>>, read.cipher_state}

  defp decipher_record(state, source, fragment, version, read, padding) do
    cipher = read.cipher_state
    bulk = elem(read.security_parameters, 3)

    case bulk do
      1 ->
        decipher_stream_record(state, source, fragment, read)

      3 ->
        decipher_block_record(state, source, fragment, version, read, padding, :des_cbc)

      4 ->
        decipher_block_record(state, source, fragment, version, read, padding, :des_ede3_cbc)

      7 when byte_size(elem(cipher, 2)) == 16 ->
        decipher_block_record(state, source, fragment, version, read, padding, :aes_128_cbc)

      7 when byte_size(elem(cipher, 2)) == 32 ->
        decipher_block_record(state, source, fragment, version, read, padding, :aes_256_cbc)

      _ ->
        :error
    end
  end

  defp decipher_stream_record(state, source, fragment, read) do
    cipher = read.cipher_state

    initialized =
      case elem(cipher, 4) do
        {:stream_init, :rc4, key, _iv} ->
          record_primitive(state, source, {:crypto, :crypto_init, 3}, [:rc4, key, false])

        handle ->
          {:ok, handle}
      end

    with {:ok, handle} <- initialized,
         {:ok, {kind, plaintext}} <-
           record_primitive_event(state, source, {:crypto, :crypto_update, 2}, [handle, fragment]) do
      hash = elem(read.security_parameters, 9)

      if kind == :return_from and is_binary(plaintext) and byte_size(plaintext) >= hash do
        length = byte_size(plaintext) - hash
        <<content::binary-size(^length), mac::binary>> = plaintext
        {:ok, content, mac, put_elem(cipher, 4, handle)}
      else
        {:alert, record_alert({:ssl_cipher, :decipher, 6}, 0, 20, :decryption_failed)}
      end
    else
      _ -> :error
    end
  end

  defp decipher_block_record(state, source, fragment, version, read, padding?, algorithm) do
    cipher = read.cipher_state

    case record_primitive_event(state, source, {:crypto, :crypto_one_time, 5}, [
           algorithm,
           elem(cipher, 2),
           elem(cipher, 1),
           fragment,
           false
         ]) do
      {:ok, {:return_from, plaintext}} when is_binary(plaintext) ->
        decipher_block_plaintext(plaintext, fragment, version, read, padding?)

      {:ok, {:exception_from, _exception}} ->
        {:alert, record_alert({:ssl_cipher, :block_decipher, 6}, 0, 20, :decryption_failed)}

      _ ->
        :error
    end
  end

  defp decipher_block_plaintext(plaintext, fragment, version, read, padding?) do
    iv_size = byte_size(elem(read.cipher_state, 1))
    hash = elem(read.security_parameters, 9)
    size = byte_size(plaintext)
    explicit_size = if version == {3, 1}, do: 0, else: iv_size
    pad = if size > 0, do: :binary.last(plaintext), else: 0
    actual_pad = if version == {3, 1} and pad >= size - 1, do: 0, else: pad
    length = size - explicit_size - actual_pad - 1 - hash

    if size > 0 and length >= 0 and byte_size(fragment) >= iv_size do
      <<explicit::binary-size(^explicit_size), content::binary-size(^length),
        mac::binary-size(^hash), padding::binary-size(^actual_pad), _pad>> = plaintext

      next_iv =
        if version == {3, 1},
          do: binary_part(fragment, byte_size(fragment) - iv_size, iv_size),
          else: explicit

      valid? =
        actual_pad == pad and
          ((version == {3, 1} and not padding?) or padding == :binary.copy(<<pad>>, pad))

      content = if valid?, do: content, else: <<240, content::binary>>
      {:ok, content, mac, put_elem(read.cipher_state, 1, next_iv)}
    else
      {:alert, record_alert({:ssl_cipher, :block_decipher, 6}, 0, 20, :decryption_failed)}
    end
  end

  defp record_alert({module, function, arity}, ordinal, description, reason) do
    where = Compiled.alert_location(module, function, arity, ordinal)
    {:alert, 2, description, where, :undefined, reason}
  end

  # OTP 29.1.2 tls_record's framing program, constructed from the qualified
  # transport bytes and modeled buffer. Keep its front/rear queue exactly;
  # flattening the remainder would lose native buffer-copy obligations.
  defp parse_record_stream([bytes, versions, buffer, maximum, downgrade]) do
    {header, queue} = record_queue(bytes, buffer)
    parse_record_queue(versions, queue, maximum, downgrade, [], header)
  end

  defp record_queue([bytes], {header, {front, size, rear}}),
    do: {header, {front, size + byte_size(bytes), [bytes | rear]}}

  defp record_queue(bytes, {header, {front, size, rear}}) when is_list(bytes),
    do: {header, {front, size + IO.iodata_length(bytes), bytes ++ rear}}

  defp record_queue(bytes, {header, {front, size, rear}}),
    do: {header, {front, size + byte_size(bytes), [bytes | rear]}}

  defp record_queue(bytes, <<>>) when is_list(bytes),
    do: {:undefined, {[], IO.iodata_length(bytes), bytes}}

  defp record_queue(bytes, <<>>), do: {:undefined, {[bytes], byte_size(bytes), []}}

  defp parse_record_queue(versions, queue, maximum, downgrade, records, :undefined),
    do:
      parse_record_queue(
        versions,
        queue,
        maximum,
        downgrade,
        records,
        {:ssl_tls, :undefined, :undefined, :undefined, false}
      )

  defp parse_record_queue(versions, {_, size, _} = queue, maximum, downgrade, records, header) do
    {:ssl_tls, type, version, length, false} = header

    cond do
      type == :undefined and size >= 1 ->
        {<<type>>, queue} = record_queue_take(1, queue)

        parse_record_queue(
          versions,
          queue,
          maximum,
          downgrade,
          records,
          put_elem(header, 1, type)
        )

      type == :undefined ->
        {:ok, {Enum.reverse(records), {:undefined, queue}}}

      type not in 20..23 ->
        {:alert,
         record_alert(
           {:tls_record, :validate_tls_records_type, 8},
           0,
           10,
           {:unsupported_record_type, type}
         )}

      version == :undefined and size >= 2 ->
        {<<major, minor>>, queue} = record_queue_take(2, queue)

        parse_record_queue(
          versions,
          queue,
          maximum,
          downgrade,
          records,
          put_elem(header, 2, {major, minor})
        )

      version == :undefined ->
        {:ok, {Enum.reverse(records), {header, queue}}}

      not record_version?(version, versions) ->
        ordinal = if is_list(versions), do: 0, else: 1

        {:alert,
         record_alert(
           {:tls_record, :validate_tls_record_version, 8},
           ordinal,
           20,
           {:unsupported_version, version}
         )}

      length == :undefined and size >= 2 ->
        {<<length::16>>, queue} = record_queue_take(2, queue)

        parse_record_queue(
          versions,
          queue,
          maximum,
          downgrade,
          records,
          put_elem(header, 3, length)
        )

      length == :undefined ->
        {:ok, {Enum.reverse(records), {header, queue}}}

      length > record_maximum(versions, maximum) ->
        {:alert, record_alert({:tls_record, :validate_tls_record_length, 8}, 0, 22, :undefined)}

      length > size ->
        {:ok, {Enum.reverse(records), {header, queue}}}

      true ->
        {fragment, queue} = record_queue_take(length, queue)
        record = {:ssl_tls, type, version, fragment, false}

        if is_tuple(downgrade) and tuple_size(downgrade) == 2,
          do: {:ok, {[record], {:undefined, queue}}},
          else:
            parse_record_queue(
              versions,
              queue,
              maximum,
              downgrade,
              [record | records],
              :undefined
            )
    end
  end

  defp record_version?({3, _} = version, versions) when is_list(versions),
    do: version in versions

  defp record_version?({3, 3}, {3, 4}), do: true
  defp record_version?(version, version), do: true
  defp record_version?(_version, _versions), do: false

  defp record_maximum(_versions, maximum) when is_integer(maximum), do: maximum + 256 + 32
  defp record_maximum([{3, 4} | _], _maximum), do: 16_384 + 256
  defp record_maximum({3, 4}, _maximum), do: 16_384 + 256
  defp record_maximum(_versions, _maximum), do: 16_384 + 2048

  defp record_queue_take(0, queue), do: {<<>>, queue}

  defp record_queue_take(count, {front, size, rear}) do
    {bytes, front, rear} = record_queue_take(count, front, rear, [])
    {bytes, {front, size - count, rear}}
  end

  defp record_queue_take(count, [], rear, parts),
    do: record_queue_take(count, Enum.reverse(rear), [], parts)

  defp record_queue_take(count, [bytes | front], rear, parts) when byte_size(bytes) < count,
    do: record_queue_take(count - byte_size(bytes), front, rear, [bytes | parts])

  defp record_queue_take(count, [bytes | front], rear, parts) when byte_size(bytes) == count,
    do: {IO.iodata_to_binary(Enum.reverse([bytes | parts])), front, rear}

  defp record_queue_take(count, [bytes | front], rear, parts) do
    <<taken::binary-size(^count), rest::binary>> = bytes
    {IO.iodata_to_binary(Enum.reverse([taken | parts])), [rest | front], rear}
  end

  # Build the record program from the modeled sender, the qualified plaintext
  # boundary and argument-qualified crypto primitives. Replaying tls_record
  # would run the implementation whose copies this proof has to check.
  defp encode_records(state, source, plaintext, version, states) do
    maximum = Map.get(states, :max_fragment_length, 16_384)
    fragments = record_fragments(plaintext, maximum)
    write = Map.fetch!(states, :current_write)
    bulk = elem(write.security_parameters, 3)

    fragments =
      case {version, bulk, Map.get(states, :beast_mitigation, :disabled)} do
        {{3, 1}, bulk, mode} when bulk != 1 and mode in [:one_n_minus_one, :zero_n] ->
          size = if mode == :one_n_minus_one, do: 1, else: 0
          {first, rest} = record_fragment(plaintext, size, [])
          [first | record_fragments(rest, maximum)]

        _ ->
          fragments
      end

    encode_record_fragments(state, source, fragments, version, states, 23)
  end

  defp encode_handshake_records(state, source, fragment, version, states) do
    maximum = Map.get(states, :max_fragment_length, 16_384)

    if IO.iodata_length(fragment) > maximum do
      fragments = fragment |> :erlang.iolist_to_iovec() |> record_fragments(maximum)

      case encode_record_fragments(state, source, fragments, version, states, 22) do
        {:ok, {encoded, states}} -> {:ok, encoded, states}
        :error -> :error
      end
    else
      encode_record(state, source, fragment, version, states, 22)
    end
  end

  defp encode_record_fragments(state, source, fragments, version, states, type) do
    Enum.reduce_while(fragments, {:ok, {[], states}}, fn fragment, {:ok, {encoded, states}} ->
      case encode_record(state, source, fragment, version, states, type) do
        {:ok, record, states} -> {:cont, {:ok, {[record | encoded], states}}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, {encoded, states}} -> {:ok, {Enum.reverse(encoded), states}}
      :error -> :error
    end
  end

  defp record_fragments([], _maximum), do: []

  defp record_fragments(data, maximum) do
    {first, rest} = record_fragment(data, maximum, [])
    [first | record_fragments(rest, maximum)]
  end

  defp record_fragment([], _remaining, accumulated), do: {Enum.reverse(accumulated), []}

  defp record_fragment([binary | rest] = data, remaining, accumulated) do
    cond do
      byte_size(binary) <= remaining ->
        record_fragment(rest, remaining - byte_size(binary), [binary | accumulated])

      remaining == 0 ->
        {Enum.reverse(accumulated), data}

      true ->
        <<first::binary-size(^remaining), tail::binary>> = binary
        {Enum.reverse(accumulated, [first]), [tail | rest]}
    end
  end

  defp encode_record(state, source, fragment, {3, 4}, states, type) do
    write = states.current_write
    sequence = write.sequence_number

    if elem(write.security_parameters, 1) == <<0, 0>> do
      record = record_packet(type, {3, 3}, fragment)
      {:ok, record, Map.put(states, :current_write, %{write | sequence_number: sequence + 1})}
    else
      with {:cipher_state, iv, _key, _finished, _nonce, _cipher, tag_length} <- write.cipher_state,
           nonce = record_nonce(sequence, iv),
           plaintext = [fragment, type],
           aad = <<23, 3, 3, IO.iodata_length(plaintext) + tag_length::16>>,
           {:ok, handle} <- record_aead_handle(state, source, write, true),
           {:ok, encrypted} <-
             record_primitive(state, source, {:crypto, :crypto_one_time_aead, 4}, [
               handle,
               nonce,
               plaintext,
               aad
             ]),
           true <- is_binary(encrypted) do
        write = write |> Map.put(:aead_handle, handle) |> Map.put(:sequence_number, sequence + 1)
        {:ok, record_packet(23, {3, 3}, encrypted), Map.put(states, :current_write, write)}
      else
        _ -> :error
      end
    end
  end

  defp encode_record(state, source, fragment, {major, minor} = version, states, type)
       when major in 0..255 and minor in 0..255 do
    write = states.current_write
    parameters = write.security_parameters

    result =
      if elem(parameters, 4) == 2,
        do: record_aead(state, source, fragment, version, write, type),
        else: record_cipher(state, source, fragment, version, write, type)

    case result do
      {:ok, encrypted, cipher} ->
        write = %{write | cipher_state: cipher, sequence_number: write.sequence_number + 1}
        {:ok, record_packet(type, version, encrypted), Map.put(states, :current_write, write)}

      :error ->
        :error
    end
  end

  defp encode_record(_state, _source, _fragment, _version, _states, _type), do: :error

  defp record_packet(type, {major, minor}, fragment),
    do: [<<type, major, minor, IO.iodata_length(fragment)::16>>, fragment]

  defp record_nonce(sequence, iv) do
    size = bit_size(iv) - 64
    <<head::bitstring-size(^size), high::32, low::32>> = iv

    <<head::bitstring,
      Bitwise.bxor(high, Bitwise.band(Bitwise.bsr(sequence, 32), 0xFFFFFFFF))::32,
      Bitwise.bxor(low, Bitwise.band(sequence, 0xFFFFFFFF))::32>>
  end

  defp record_aead_handle(state, source, write, encrypt?) do
    case Map.fetch(write, :aead_handle) do
      {:ok, handle} ->
        {:ok, handle}

      :error ->
        cipher = write.cipher_state

        with {:ok, algorithm} <-
               record_aead_algorithm(elem(write.security_parameters, 3), elem(cipher, 2)) do
          record_primitive(state, source, {:crypto, :crypto_one_time_aead_init, 4}, [
            algorithm,
            elem(cipher, 2),
            elem(cipher, 6),
            encrypt?
          ])
        end
    end
  end

  defp record_aead(state, source, fragment, {major, minor}, write, type) do
    cipher = write.cipher_state
    bulk = elem(write.security_parameters, 3)
    sequence = write.sequence_number
    length = IO.iodata_length(fragment)
    aad = <<sequence::64, type, major, minor, length::16>>

    with {:ok, algorithm} <- record_aead_algorithm(bulk, elem(cipher, 2)),
         {:ok, nonce, prefix, next_cipher} <-
           record_legacy_nonce(state, source, bulk, cipher, sequence),
         {:ok, {content, tag}} <-
           record_primitive(state, source, {:crypto, :crypto_one_time_aead, 7}, [
             algorithm,
             elem(cipher, 2),
             nonce,
             fragment,
             aad,
             elem(cipher, 6),
             true
           ]),
         true <- is_binary(content) and is_binary(tag) do
      {:ok, prefix <> content <> tag, next_cipher}
    else
      _ -> :error
    end
  end

  defp record_legacy_nonce(state, source, 9, cipher, sequence) do
    seed = <<sequence::64>>

    with {:ok, nonce} <-
           record_primitive(state, source, {:crypto, :exor, 2}, [
             <<0::32, seed::binary>>,
             elem(cipher, 1)
           ]) do
      {:ok, nonce, <<>>, put_elem(cipher, 5, seed)}
    end
  end

  defp record_legacy_nonce(_state, _source, bulk, cipher, _sequence) when bulk in [8, 10, 11] do
    <<salt::binary-size(4), _::binary>> = elem(cipher, 1)
    explicit = elem(cipher, 5)
    {:ok, <<salt::binary, explicit::64>>, <<explicit::64>>, put_elem(cipher, 5, explicit + 1)}
  end

  defp record_aead_algorithm(9, _key), do: {:ok, :chacha20_poly1305}

  defp record_aead_algorithm(bulk, key) when bulk in [8, 10, 11] do
    case {bulk, byte_size(key)} do
      {8, 16} -> {:ok, :aes_128_gcm}
      {8, 24} -> {:ok, :aes_192_gcm}
      {8, 32} -> {:ok, :aes_256_gcm}
      {_, 16} -> {:ok, :aes_128_ccm}
      {_, 24} -> {:ok, :aes_192_ccm}
      {_, 32} -> {:ok, :aes_256_ccm}
      _ -> :error
    end
  end

  defp record_aead_algorithm(_bulk, _key), do: :error

  defp record_cipher(state, source, fragment, version, write, type) do
    with {:ok, mac} <- record_mac(state, source, fragment, version, write, type) do
      record_ciphertext(state, source, fragment, version, write, mac)
    end
  end

  defp record_mac(_state, _source, _fragment, _version, %{security_parameters: parameters}, _type)
       when elem(parameters, 7) == 0,
       do: {:ok, <<>>}

  defp record_mac(state, source, fragment, {major, minor}, write, type) do
    with {:ok, algorithm} <- record_mac_algorithm(elem(write.security_parameters, 7)) do
      header = <<write.sequence_number::64, type, major, minor, IO.iodata_length(fragment)::16>>

      record_primitive(state, source, {:crypto, :mac, 4}, [
        :hmac,
        algorithm,
        write.mac_secret,
        [header, fragment]
      ])
    end
  end

  defp record_mac_algorithm(1), do: {:ok, :md5}
  defp record_mac_algorithm(2), do: {:ok, :sha}
  defp record_mac_algorithm(4), do: {:ok, :sha256}
  defp record_mac_algorithm(5), do: {:ok, :sha384}
  defp record_mac_algorithm(6), do: {:ok, :sha512}

  defp record_mac_algorithm(algorithm)
       when algorithm in [:md5, :sha, :sha224, :sha256, :sha384, :sha512],
       do: {:ok, algorithm}

  defp record_mac_algorithm(_algorithm), do: :error

  defp record_ciphertext(
         _state,
         _source,
         fragment,
         _version,
         %{security_parameters: parameters} = write,
         <<>>
       )
       when elem(parameters, 3) == 0,
       do: {:ok, IO.iodata_to_binary(fragment), write.cipher_state}

  defp record_ciphertext(state, source, fragment, version, write, mac) do
    cipher = write.cipher_state
    bulk = elem(write.security_parameters, 3)

    case bulk do
      1 ->
        record_stream_cipher(state, source, fragment, cipher, mac)

      3 ->
        record_block_cipher(state, source, fragment, version, cipher, mac, {:des_cbc, 8})

      4 ->
        record_block_cipher(state, source, fragment, version, cipher, mac, {:des_ede3_cbc, 8})

      7 when byte_size(elem(cipher, 2)) == 16 ->
        record_block_cipher(state, source, fragment, version, cipher, mac, {:aes_128_cbc, 16})

      7 when byte_size(elem(cipher, 2)) == 32 ->
        record_block_cipher(state, source, fragment, version, cipher, mac, {:aes_256_cbc, 16})

      _ ->
        :error
    end
  end

  defp record_stream_cipher(state, source, fragment, cipher, mac) do
    initialized =
      case elem(cipher, 4) do
        {:stream_init, :rc4, key, _iv} ->
          record_primitive(state, source, {:crypto, :crypto_init, 3}, [:rc4, key, true])

        handle ->
          {:ok, handle}
      end

    with {:ok, handle} <- initialized,
         {:ok, encrypted} <-
           record_primitive(state, source, {:crypto, :crypto_update, 2}, [handle, [fragment, mac]]) do
      {:ok, IO.iodata_to_binary(encrypted), put_elem(cipher, 4, handle)}
    end
  end

  defp record_block_cipher(state, source, fragment, version, cipher, mac, {algorithm, block_size}) do
    padding = block_size - rem(byte_size(mac) + IO.iodata_length(fragment) + 1, block_size)
    block = [fragment, mac, :binary.copy(<<padding>>, padding + 1)]

    with {:ok, input, next} <- record_block_iv(state, source, version, cipher, block),
         {:ok, encrypted} <-
           record_primitive(state, source, {:crypto, :crypto_one_time, 5}, [
             algorithm,
             elem(cipher, 2),
             elem(cipher, 1),
             input,
             true
           ]),
         true <- is_binary(encrypted) do
      next =
        if version == {3, 1} do
          size = byte_size(elem(cipher, 1))
          put_elem(next, 1, binary_part(encrypted, byte_size(encrypted) - size, size))
        else
          next
        end

      {:ok, encrypted, next}
    else
      _ -> :error
    end
  end

  defp record_block_iv(_state, _source, {3, 1}, cipher, block), do: {:ok, block, cipher}

  defp record_block_iv(state, source, _version, cipher, block) do
    size = byte_size(elem(cipher, 1))

    cache =
      case elem(cipher, 4) do
        <<>> -> record_primitive(state, source, {:crypto, :strong_rand_bytes, 1}, [size * 32])
        cache -> {:ok, cache}
      end

    with {:ok, <<iv::binary-size(^size), rest::binary>>} <- cache do
      {:ok, [iv | block], cipher |> put_elem(1, iv) |> put_elem(4, rest)}
    end
  end

  defp record_primitive(state, source, mfa, arguments) do
    case record_primitive_event(state, source, mfa, arguments) do
      {:ok, {:return_from, value}} -> {:ok, value}
      _ -> :error
    end
  end

  defp record_primitive_event(state, source, {module, function, _} = mfa, arguments) do
    scope = Map.fetch!(state.pairs, source.index)

    values =
      for pair <- Map.get(state.pair_index, {source.pid, mfa}, []),
          source.index < pair.source.index and pair.returned.index < scope.returned.index,
          pair.source.event === {source.pid, :call, {module, function, arguments}},
          {_, kind, ^mfa, value} <- [pair.returned.event],
          kind in [:return_from, :exception_from],
          do: {kind, value}

    case Enum.uniq(values) do
      [value] -> {:ok, value}
      _ -> :error
    end
  end

  defp handshake_program_call(source, :tls_handshake_events, program) do
    recursive? = List.first(source.stack) == {:tls_gen_connection, :tls_handshake_events, 2}
    rest = if recursive?, do: <<>>, else: program.rest
    {[program.packets, rest], handshake_events(program.packets, rest)}
  end

  defp handshake_program_call(_source, :unprocessed_events, program),
    do: {[program.events], length(program.events) - 1}

  # Decode only the independently selected plaintext record and the modeled
  # pre-call handshake buffer. This parser creates no entropy and executes no
  # state callback. The initial server hello alone uses the highest offered
  # version; any coalesced remainder is queued for the negotiated state.
  defp handshake_packets(fragment, name, data) do
    version = elem(elem(data, 3), 5)
    [highest | _] = Map.fetch!(elem(data, 4), :versions)
    role = elem(elem(data, 2), 1)
    buffer = elem(elem(data, 11), 2)

    case {version, highest, role, name} do
      {{3, 3}, {3, 4}, :client, :hello} ->
        <<_type, length::24, _::binary>> = fragment
        <<first::binary-size(^length + 4), rest::binary>> = fragment

        {packets, remaining} =
          parse_handshake_stream(highest, <<buffer::binary, first::binary>>, [])

        {:ok, {packets, remaining, rest}}

      _ ->
        selected =
          if version == :undefined or
               (version == {3, 3} and highest == {3, 4} and role == :client and name == :wait_sh),
             do: highest,
             else: version

        {packets, remaining} =
          parse_handshake_stream(selected, <<buffer::binary, fragment::binary>>, [])

        {:ok, {packets, remaining, <<>>}}
    end
  rescue
    _error -> :error
  catch
    {:handshake_alert, alert} -> {:exception, {:throw, alert}}
    :invalid_handshake -> :error
  end

  # Framing, vectors, records and extensions are built from the independently
  # selected plaintext. No native TLS decoder supplies an expected packet.
  # Malformed or unmodeled constructors fail closed and retain the raw event.
  defp parse_handshake_stream(version, <<type, length::24, tail::binary>> = bytes, packets)
       when byte_size(tail) >= length do
    <<body::binary-size(^length), rest::binary>> = tail
    raw = binary_part(bytes, 0, length + 4)
    packet = decode_handshake_packet(version, type, body)
    parse_handshake_stream(version, rest, [{packet, raw} | packets])
  end

  defp parse_handshake_stream(_version, rest, packets), do: {Enum.reverse(packets), rest}

  defp decode_handshake_packet(_version, 0, <<>>), do: {:hello_request}

  defp decode_handshake_packet(
         version,
         1,
         <<major, minor, random::binary-size(32), size, session::binary-size(size),
           suite_size::16, suites::binary-size(suite_size), methods_size,
           _methods::binary-size(methods_size), extensions::binary>>
       ) do
    unless rem(suite_size, 2) == 0, do: handshake_decode_error()
    extensions = handshake_vector(extensions)
    selected = handshake_extension_version(extensions, version, {major, minor})

    {:client_hello, {major, minor}, random, session, :undefined,
     for(<<suite::binary-size(2) <- suites>>, do: suite),
     decode_handshake_extensions(extensions, selected, :client_hello, true)}
  end

  defp decode_handshake_packet(
         version,
         2,
         <<major, minor, random::binary-size(32), size, session::binary-size(size),
           cipher::binary-size(2), compression, extensions::binary>>
       ) do
    retry? = version == {3, 4} and random == @hello_retry_random

    unless compression == 0 or retry? do
      handshake_alert(
        {:ssl_handshake, :decode_handshake, 3},
        0,
        47,
        {:invalid_compression_method, compression}
      )
    end

    absent? = extensions == <<>>
    extensions = handshake_vector(extensions)

    selected =
      if absent?,
        do: version,
        else: handshake_extension_version(extensions, version, {major, minor})

    kind = if retry?, do: :hello_retry_request, else: :server_hello

    {:server_hello, {major, minor}, random, session, cipher,
     decode_handshake_extensions(extensions, selected, kind, true)}
  end

  defp decode_handshake_packet(
         {3, 4},
         4,
         <<lifetime::32, age::32, nonce_size, nonce::binary-size(nonce_size), ticket_size::16,
           ticket::binary-size(ticket_size), size::16, extensions::binary-size(size)>>
       ),
       do:
         {:new_session_ticket, lifetime, age, nonce, ticket,
          decode_handshake_extensions(extensions, {3, 4}, :new_session_ticket, false)}

  defp decode_handshake_packet({3, 4}, 5, _body), do: {:end_of_early_data}

  defp decode_handshake_packet({3, 4}, 8, <<size::16, extensions::binary-size(size)>>),
    do:
      {:encrypted_extensions,
       decode_handshake_extensions(extensions, {3, 4}, :encrypted_extensions, false)}

  defp decode_handshake_packet(
         {3, 4},
         11,
         <<context_size, context::binary-size(context_size), size::24,
           entries::binary-size(size)>>
       ),
       do: {:certificate_1_3, context, handshake_certificates(entries, :tls13, [])}

  defp decode_handshake_packet(_version, 11, <<size::24, certificates::binary-size(size)>>),
    do: {:certificate, handshake_certificates(certificates, :legacy, [])}

  defp decode_handshake_packet(_version, 12, keys), do: {:server_key_exchange, keys}

  defp decode_handshake_packet(
         {3, 4},
         13,
         <<context_size, context::binary-size(context_size), size::16,
           extensions::binary-size(size)>>
       ),
       do:
         {:certificate_request_1_3, context,
          decode_handshake_extensions(extensions, {3, 4}, :certificate_request, false)}

  defp decode_handshake_packet(
         {3, 3},
         13,
         <<size, types::binary-size(size), signs_size::16, signs::binary-size(signs_size),
           names_size::16, names::binary-size(names_size)>>
       ),
       do:
         {:certificate_request, types,
          {:hash_sign_algos, handshake_signature_list(signs, {3, 3})},
          handshake_authorities(names)}

  defp decode_handshake_packet(
         _version,
         13,
         <<size, types::binary-size(size), names_size::16, names::binary-size(names_size)>>
       ),
       do: {:certificate_request, types, :undefined, handshake_authorities(names)}

  defp decode_handshake_packet(_version, 14, <<>>), do: {:server_hello_done}

  defp decode_handshake_packet(
         {3, 4},
         15,
         <<algorithm::16, size::16, signature::binary-size(size)>>
       ),
       do: {:certificate_verify_1_3, handshake_signature(algorithm), signature}

  defp decode_handshake_packet(
         {3, 3},
         15,
         <<algorithm::16, size::16, signature::binary-size(size)>>
       ) do
    [scheme] = handshake_signature_list(<<algorithm::16>>, {3, 3})
    {:certificate_verify, scheme, signature}
  end

  defp decode_handshake_packet(_version, 15, <<size::16, signature::binary-size(size)>>),
    do: {:certificate_verify, :undefined, signature}

  defp decode_handshake_packet(_version, 16, keys), do: {:client_key_exchange, keys}
  defp decode_handshake_packet(_version, 20, verify), do: {:finished, verify}

  defp decode_handshake_packet(_version, 22, <<1, size::24, response::binary-size(size)>>),
    do: {:certificate_status, 1, response}

  defp decode_handshake_packet({3, 4}, 24, <<0>>), do: {:key_update, :update_not_requested}
  defp decode_handshake_packet({3, 4}, 24, <<1>>), do: {:key_update, :update_requested}

  defp decode_handshake_packet({3, 4}, 24, <<request>>),
    do:
      handshake_alert(
        {:tls_handshake_1_3, :decode_key_update, 1},
        0,
        47,
        {:request_update, request}
      )

  defp decode_handshake_packet(
         _version,
         67,
         <<size, protocol::binary-size(size), padding_size, _padding::binary-size(padding_size)>>
       ),
       do: {:next_protocol, protocol}

  defp decode_handshake_packet(_version, type, _body),
    do:
      handshake_alert(
        {:ssl_handshake, :decode_handshake, 3},
        1,
        50,
        {:unknown_or_malformed_handshake, type}
      )

  defp handshake_alert(mfa, ordinal, description, reason),
    do: throw({:handshake_alert, record_alert(mfa, ordinal, description, reason)})

  defp handshake_decode_error,
    do:
      handshake_alert(
        {:tls_handshake, :get_tls_handshakes_aux, 4},
        0,
        50,
        :handshake_decode_error
      )

  defp handshake_vector(<<>>), do: <<>>
  defp handshake_vector(<<size::16, bytes::binary-size(size)>>), do: bytes

  defp handshake_extension_version(
         <<43::16, size::16, data::binary-size(size), _::binary>>,
         local,
         _
       )
       when size > 2 do
    <<_size, versions::binary>> = data
    [highest | _] = handshake_versions(versions, [])
    min(local, highest)
  end

  defp handshake_extension_version(<<43::16, 2::16, major, minor, _::binary>>, local, _),
    do: min(local, {major, minor})

  defp handshake_extension_version(
         <<_type::16, size::16, _::binary-size(size), rest::binary>>,
         local,
         legacy
       ),
       do: handshake_extension_version(rest, local, legacy)

  defp handshake_extension_version(_rest, local, legacy), do: min(local, legacy)

  defp handshake_certificates(<<>>, _kind, certificates), do: Enum.reverse(certificates)

  defp handshake_certificates(
         <<size::24, der::binary-size(size), rest::binary>>,
         :legacy,
         certificates
       ),
       do: handshake_certificates(rest, :legacy, [der | certificates])

  defp handshake_certificates(
         <<size::24, der::binary-size(size), extension_size::16,
           extensions::binary-size(extension_size), rest::binary>>,
         :tls13,
         certificates
       ),
       do:
         handshake_certificates(rest, :tls13, [
           {:certificate_entry, der,
            decode_handshake_extensions(extensions, {3, 4}, :certificate, false)}
           | certificates
         ])

  defp handshake_certificates(_bytes, :tls13, _certificates),
    do:
      handshake_alert(
        {:tls_handshake_1_3, :decode_cert_entries, 2},
        0,
        50,
        :truncated_certificate_entry
      )

  defp handshake_certificates(_bytes, :legacy, _certificates), do: handshake_decode_error()

  defp decode_handshake_extensions(bytes, version, kind, hello?) do
    defaults =
      case {hello?, version, kind} do
        {false, _, _} ->
          []

        {true, {3, 4}, :server_hello} ->
          [:key_share, :pre_shared_key, :server_hello_selected_version]

        {true, {3, 4}, :hello_retry_request} ->
          [:key_share, :cookie, :server_hello_selected_version]

        {true, {3, 4}, :client_hello} ->
          [
            :sni,
            :max_frag_enum,
            :status_request,
            :elliptic_curves,
            :signature_algs,
            :use_srtp,
            :alpn,
            :key_share,
            :pre_shared_key,
            :psk_key_exchange_modes,
            :early_data,
            :cookie,
            :client_hello_versions,
            :certificate_authorities,
            :signature_algs_cert
          ]

        {true, {3, 3}, :client_hello} ->
          [
            :renegotiation_info,
            :alpn,
            :next_protocol_negotiation,
            :srp,
            :ec_point_formats,
            :elliptic_curves,
            :sni,
            :signature_algs
          ]

        {true, _, :client_hello} ->
          [
            :renegotiation_info,
            :alpn,
            :next_protocol_negotiation,
            :srp,
            :ec_point_formats,
            :elliptic_curves,
            :sni
          ]

        {true, _, :server_hello} ->
          [:renegotiation_info, :alpn, :next_protocol_negotiation, :ec_point_formats]
      end

    parse_handshake_extensions(bytes, version, kind, Map.new(defaults, &{&1, :undefined}))
  end

  defp parse_handshake_extensions(
         <<type::16, size::16, bytes::binary-size(size), rest::binary>>,
         version,
         kind,
         extensions
       ) do
    extensions =
      case handshake_extension(type, bytes, version, kind, rest) do
        :ignore ->
          extensions

        {key, value} ->
          unless Map.get(extensions, key, :undefined) == :undefined do
            handshake_alert(
              {:ssl_handshake, :assert_unique_extension, 2},
              0,
              47,
              {:duplicate_extension, key}
            )
          end

          Map.put(extensions, key, value)
      end

    parse_handshake_extensions(rest, version, kind, extensions)
  end

  # OTP ignores incomplete extension suffixes; the complete raw bytes remain
  # observed and therefore acquire no cross-side allowance from that behavior.
  defp parse_handshake_extensions(_rest, _version, _kind, extensions), do: extensions

  defp handshake_extension(16, <<size::16, bytes::binary-size(size)>>, _version, kind, _)
       when kind in [:client_hello, :server_hello, :encrypted_extensions],
       do: {:alpn, {:alpn, bytes}}

  defp handshake_extension(13172, bytes, _version, kind, _)
       when kind in [:client_hello, :server_hello],
       do: {:next_protocol_negotiation, {:next_protocol_negotiation, bytes}}

  defp handshake_extension(65281, bytes, _version, kind, _)
       when kind in [:client_hello, :server_hello] do
    info = if byte_size(bytes) == 1, do: bytes, else: handshake_vector8(bytes)
    {:renegotiation_info, {:renegotiation_info, info}}
  end

  defp handshake_extension(12, bytes, _version, :client_hello, _),
    do: {:srp, {:srp, handshake_vector8(bytes)}}

  defp handshake_extension(13, bytes, version, kind, _)
       when kind in [:client_hello, :certificate_request] do
    schemes = handshake_signature_list(handshake_vector(bytes), version)
    tag = if version == {3, 4}, do: :signature_algorithms, else: :hash_sign_algos
    {:signature_algs, {tag, schemes}}
  end

  defp handshake_extension(50, bytes, _version, kind, _)
       when kind in [:client_hello, :certificate_request],
       do:
         {:signature_algs_cert,
          {:signature_algorithms_cert, handshake_signature_list(handshake_vector(bytes), {3, 4})}}

  defp handshake_extension(
         14,
         <<size::16, profiles::binary-size(size), tail::binary>>,
         _version,
         kind,
         _
       )
       when kind in [:client_hello, :server_hello, :encrypted_extensions],
       do:
         {:use_srtp,
          {:use_srtp, for(<<profile::binary-size(2) <- profiles>>, do: profile),
           handshake_vector8(tail)}}

  defp handshake_extension(10, <<_size::16, bytes::binary>>, {3, 4}, kind, _)
       when kind in [:client_hello, :encrypted_extensions],
       do:
         {:elliptic_curves,
          {:supported_groups,
           for(<<enum::16 <- bytes>>, is_map_key(@handshake_groups, enum),
             do: Map.fetch!(@handshake_groups, enum)
           )}}

  defp handshake_extension(10, <<_size::16, bytes::binary>>, version, kind, _)
       when version < {3, 4} and kind in [:client_hello, :server_hello],
       do:
         {:elliptic_curves,
          {:elliptic_curves,
           for(<<enum::16 <- bytes>>, is_map_key(@handshake_curve_oids, enum),
             do: Map.fetch!(@handshake_curve_oids, enum)
           )}}

  defp handshake_extension(11, <<_size, bytes::binary>>, _version, kind, _)
       when kind in [:client_hello, :server_hello],
       do: {:ec_point_formats, {:ec_point_formats, :binary.bin_to_list(bytes)}}

  defp handshake_extension(0, <<>>, _version, kind, _)
       when kind in [:server_hello, :encrypted_extensions], do: {:sni, {:sni, []}}

  defp handshake_extension(0, <<_size::16, names::binary>>, _version, kind, _)
       when kind in [:client_hello, :server_hello, :encrypted_extensions],
       do: {:sni, handshake_server_name(names)}

  defp handshake_extension(1, <<enum>>, _version, kind, _)
       when kind in [:client_hello, :server_hello, :encrypted_extensions],
       do: {:max_frag_enum, {:max_frag_enum, enum}}

  defp handshake_extension(43, <<major, minor>>, _version, kind, _)
       when kind in [:client_hello, :server_hello, :hello_retry_request],
       do: {:server_hello_selected_version, {:server_hello_selected_version, {major, minor}}}

  defp handshake_extension(43, <<_size, versions::binary>>, _version, kind, _)
       when byte_size(versions) > 1 and
              kind in [:client_hello, :server_hello, :hello_retry_request],
       do: {:client_hello_versions, {:client_hello_versions, handshake_versions(versions, [])}}

  defp handshake_extension(51, <<enum::16>>, _version, :hello_retry_request, _),
    do:
      {:key_share, {:key_share_hello_retry_request, Map.get(@handshake_groups, enum, :undefined)}}

  defp handshake_extension(
         51,
         <<enum::16, size::16, bytes::binary-size(size)>>,
         _version,
         :server_hello,
         _
       ) do
    group = Map.get(@handshake_groups, enum, :undefined)

    {:key_share,
     {:key_share_server_hello, {:key_share_entry, group, handshake_peer_share(group, bytes)}}}
  end

  defp handshake_extension(51, <<_size::16, shares::binary>>, _version, :client_hello, _),
    do: {:key_share, {:key_share_client_hello, handshake_peer_shares(shares, [])}}

  defp handshake_extension(45, bytes, _version, :client_hello, _),
    do:
      {:psk_key_exchange_modes,
       {:psk_key_exchange_modes,
        for(<<mode <- handshake_vector8(bytes)>>, do: Enum.fetch!([:psk_ke, :psk_dhe_ke], mode))}}

  defp handshake_extension(41, <<identity::16>>, _version, :server_hello, _),
    do: {:pre_shared_key, {:pre_shared_key_server_hello, identity}}

  defp handshake_extension(
         41,
         <<identity_size::16, identities::binary-size(identity_size), binder_size::16,
           binders::binary-size(binder_size)>>,
         _version,
         :client_hello,
         <<>>
       ),
       do:
         {:pre_shared_key,
          {:pre_shared_key_client_hello,
           {:offered_psks, handshake_psk_identities(identities, []),
            handshake_psk_binders(binders, [])}, binder_size + 2}}

  defp handshake_extension(41, _bytes, _version, :client_hello, _rest),
    do:
      handshake_alert(
        {:ssl_handshake, :decode_extensions, 4},
        0,
        47,
        :pre_shared_key_not_last_extension
      )

  defp handshake_extension(44, bytes, _version, kind, _)
       when kind in [:client_hello, :hello_retry_request],
       do: {:cookie, {:cookie, handshake_vector(bytes)}}

  defp handshake_extension(5, <<>>, _version, kind, _)
       when kind in [:client_hello, :server_hello, :certificate_request, :certificate],
       do: {:status_request, :undefined}

  defp handshake_extension(5, <<1, size::24, response::binary-size(size)>>, _version, _kind, _),
    do: {:status_request, {:certificate_status, :undefined, response}}

  defp handshake_extension(42, <<>>, _version, kind, _)
       when kind in [:client_hello, :encrypted_extensions],
       do: {:early_data, {:early_data_indication}}

  defp handshake_extension(42, <<maximum::32>>, _version, :new_session_ticket, _),
    do: {:early_data, {:early_data_indication_nst, maximum}}

  defp handshake_extension(47, bytes, _version, kind, _)
       when kind in [:client_hello, :certificate_request],
       do:
         {:certificate_authorities,
          {:certificate_authorities, handshake_authorities(handshake_vector(bytes))}}

  defp handshake_extension(_type, _bytes, _version, _kind, _rest), do: :ignore

  defp handshake_vector8(<<size, bytes::binary-size(size)>>), do: bytes

  defp handshake_server_name(<<0, size::16, hostname::binary-size(size), _rest::binary>>),
    do: {:sni, :binary.bin_to_list(hostname)}

  defp handshake_server_name(<<_type, size::16, _::binary-size(size), rest::binary>>),
    do: handshake_server_name(rest)

  defp handshake_server_name(_rest), do: :undefined

  defp handshake_versions(<<>>, versions), do: Enum.reverse(versions)

  defp handshake_versions(<<major, minor, rest::binary>>, versions),
    do: handshake_versions(rest, [{major, minor} | versions])

  defp handshake_peer_share(:x25519mlkem768, <<kem::binary-size(1088), curve::binary-size(32)>>),
    do: {kem, curve}

  defp handshake_peer_share(
         :secp256r1mlkem768,
         <<curve::binary-size(65), kem::binary-size(1088)>>
       ),
       do: {curve, kem}

  defp handshake_peer_share(
         :secp384r1mlkem1024,
         <<curve::binary-size(97), kem::binary-size(1568)>>
       ),
       do: {curve, kem}

  defp handshake_peer_share(_group, bytes), do: bytes

  defp handshake_peer_shares(<<>>, shares), do: Enum.reverse(shares)

  defp handshake_peer_shares(
         <<enum::16, size::16, bytes::binary-size(size), rest::binary>>,
         shares
       ) do
    group = Map.get(@handshake_groups, enum, :undefined)
    # Client hybrid encodings carry public keys rather than encapsulation ciphertexts.
    public =
      case {group, bytes} do
        {:x25519mlkem768, <<kem::binary-size(1184), curve::binary-size(32)>>} -> {kem, curve}
        {:secp256r1mlkem768, <<curve::binary-size(65), kem::binary-size(1184)>>} -> {curve, kem}
        {:secp384r1mlkem1024, <<curve::binary-size(97), kem::binary-size(1568)>>} -> {curve, kem}
        _ -> bytes
      end

    shares =
      if group == :undefined, do: shares, else: [{:key_share_entry, group, public} | shares]

    handshake_peer_shares(rest, shares)
  end

  defp handshake_psk_identities(<<>>, identities), do: Enum.reverse(identities)

  defp handshake_psk_identities(
         <<size::16, identity::binary-size(size), age::32, rest::binary>>,
         identities
       ),
       do: handshake_psk_identities(rest, [{:psk_identity, identity, age} | identities])

  defp handshake_psk_binders(<<>>, binders), do: Enum.reverse(binders)

  defp handshake_psk_binders(<<size, binder::binary-size(size), rest::binary>>, binders),
    do: handshake_psk_binders(rest, [binder | binders])

  defp handshake_signature(enum) do
    Map.get_lazy(@handshake_signatures, enum, fn ->
      hash = handshake_hash(Bitwise.bsr(enum, 8))
      sign = handshake_sign(Bitwise.band(enum, 255))
      if hash == :unassigned or sign == :unassigned, do: :unassigned, else: {hash, sign}
    end)
  end

  defp handshake_hash(enum) when enum in 0..6,
    do: Enum.fetch!([:null, :md5, :sha, :sha224, :sha256, :sha384, :sha512], enum)

  defp handshake_hash(enum) when enum in 224..255, do: enum
  defp handshake_hash(_enum), do: :unassigned
  defp handshake_sign(enum) when enum in 0..3, do: Enum.fetch!([:anon, :rsa, :dsa, :ecdsa], enum)
  defp handshake_sign(enum) when enum in 224..255, do: enum
  defp handshake_sign(_enum), do: :unassigned

  defp handshake_signature_list(bytes, version) when version < {3, 3},
    do: for(<<hash, sign <- bytes>>, do: {handshake_hash(hash), handshake_sign(sign)})

  defp handshake_signature_list(bytes, version) do
    for <<enum::16 <- bytes>>,
        scheme = handshake_signature(enum),
        scheme != :unassigned,
        value = handshake_signature_version(scheme, enum, version),
        value != :unassigned,
        do: value
  end

  defp handshake_signature_version(scheme, _enum, {3, 4}), do: scheme
  defp handshake_signature_version(scheme, _enum, _version) when is_tuple(scheme), do: scheme

  defp handshake_signature_version(_scheme, enum, {3, 3}) do
    case enum do
      n when n in [0x0401, 0x0501, 0x0601] -> {handshake_hash(Bitwise.bsr(n, 8)), :rsa}
      n when n in [0x0403, 0x0503, 0x0603] -> {handshake_hash(Bitwise.bsr(n, 8)), :ecdsa}
      n when n in 0x0804..0x0806 -> {handshake_hash(n - 0x0800), :rsa_pss_rsae}
      n when n in 0x0809..0x080B -> {handshake_hash(n - 0x0805), :rsa_pss_pss}
      0x0201 -> {:sha, :rsa}
      0x0203 -> {:sha, :ecdsa}
      n when n in 0x081A..0x081C -> {handshake_hash(n - 0x0816), :ecdsa}
      _ -> :unassigned
    end
  end

  defp handshake_signature_version(_scheme, enum, _version),
    do: {handshake_hash(Bitwise.bsr(enum, 8)), handshake_sign(Bitwise.band(enum, 255))}

  # X.509 Name is decoded from its wire DER, including unknown attribute open
  # types. Only singleton PrintableString RDNs receive OTP's space/case folding.
  # Neither a checked certificate helper return nor a live certificate database
  # supplies a name. OTP ignores an authority whose own DER cannot be decoded.
  defp handshake_authorities(bytes), do: handshake_authorities(bytes, [])
  defp handshake_authorities(<<>>, names), do: Enum.reverse(names)

  defp handshake_authorities(<<size::16, der::binary-size(size), rest::binary>>, names) do
    names =
      case handshake_authority(der) do
        {:ok, name} -> [name | names]
        :error -> names
      end

    handshake_authorities(rest, names)
  end

  defp handshake_authority(der) do
    {48, sequence, <<>>} = handshake_der(der)
    {:ok, {:rdnSequence, handshake_rdns(sequence, [])}}
  rescue
    _error -> :error
  catch
    :invalid_handshake -> :error
  end

  defp handshake_rdns(<<>>, rdns), do: Enum.reverse(rdns)

  defp handshake_rdns(bytes, rdns) do
    {49, set, rest} = handshake_der(bytes)
    attributes = handshake_name_attributes(set, [])
    true = attributes != []

    normalized =
      case attributes do
        [{:AttributeTypeAndValue, oid, {:printableString, value}}] ->
          value = value |> :string.trim() |> :string.split(~c"  ", :all)

          value =
            case value do
              [single] ->
                single

              parts ->
                parts
                |> Enum.reject(&(&1 == []))
                |> Enum.map(&:string.trim(&1, :leading, ~c" "))
                |> Enum.intersperse(~c" ")
                |> :unicode.characters_to_list()
            end

          [{:AttributeTypeAndValue, oid, {:printableString, :string.casefold(value)}}]

        attributes ->
          attributes
      end

    handshake_rdns(rest, [normalized | rdns])
  end

  defp handshake_name_attributes(<<>>, attributes), do: Enum.reverse(attributes)

  defp handshake_name_attributes(bytes, attributes) do
    {48, attribute, rest} = handshake_der(bytes)
    {6, encoded_oid, encoded_value} = handshake_der(attribute)
    oid = handshake_name_oid(encoded_oid)
    {tag, value, <<>>} = handshake_der(encoded_value)
    value = handshake_name_value(oid, tag, value, encoded_value)
    handshake_name_attributes(rest, [{:AttributeTypeAndValue, oid, value} | attributes])
  end

  defp handshake_der(<<tag, size, tail::binary>>) when size < 128 do
    <<value::binary-size(^size), rest::binary>> = tail
    {tag, value, rest}
  end

  defp handshake_der(<<tag, size_size, tail::binary>>) when size_size in 129..255 do
    count = size_size - 128
    <<encoded_size::binary-size(^count), tail::binary>> = tail
    size = :binary.decode_unsigned(encoded_size)
    <<value::binary-size(^size), rest::binary>> = tail
    {tag, value, rest}
  end

  defp handshake_name_oid(bytes) do
    [head | tail] = handshake_oid_components(bytes, 0, [])
    first = min(div(head, 40), 2)
    List.to_tuple([first, head - first * 40 | tail])
  end

  defp handshake_oid_components(<<>>, 0, values), do: Enum.reverse(values)

  defp handshake_oid_components(<<byte, rest::binary>>, partial, values) do
    value = partial * 128 + Bitwise.band(byte, 127)

    if byte < 128,
      do: handshake_oid_components(rest, 0, [value | values]),
      else: handshake_oid_components(rest, value, values)
  end

  defp handshake_name_value({2, 5, 4, 6}, 19, bytes, _encoded) when byte_size(bytes) == 2,
    do: :binary.bin_to_list(bytes)

  defp handshake_name_value({2, 5, 4, 5}, 19, bytes, _encoded) when byte_size(bytes) in 1..64,
    do: :binary.bin_to_list(bytes)

  defp handshake_name_value({2, 5, 4, 46}, 19, bytes, _encoded), do: :binary.bin_to_list(bytes)

  defp handshake_name_value({0, 9, 2342, 19_200_300, 100, 1, 25}, 22, bytes, _encoded),
    do: :binary.bin_to_list(bytes)

  defp handshake_name_value({1, 2, 840, 113_549, 1, 9, 1}, 22, bytes, _encoded)
       when byte_size(bytes) in 1..255, do: :binary.bin_to_list(bytes)

  defp handshake_name_value({2, 5, 4, attribute}, tag, bytes, _encoded)
       when attribute in [3, 4, 7, 8, 10, 11, 12, 41, 42, 43, 44, 65] do
    limit =
      cond do
        attribute in [4, 41, 42, 43, 44] -> 32768
        attribute in [7, 8, 65] -> 128
        true -> 64
      end

    {type, value} =
      case tag do
        12 ->
          {:utf8String, bytes}

        19 ->
          {:printableString, :binary.bin_to_list(bytes)}

        20 ->
          {:teletexString, :binary.bin_to_list(bytes)}

        30 ->
          true = rem(byte_size(bytes), 2) == 0
          {:bmpString, for(<<a, b <- bytes>>, do: if(a == 0, do: b, else: {0, 0, a, b}))}

        28 ->
          true = rem(byte_size(bytes), 4) == 0

          {:universalString,
           for(<<a, b, c, d <- bytes>>, do: if({a, b, c} == {0, 0, 0}, do: d, else: {a, b, c, d}))}
      end

    unless type == :utf8String or length(value) in 1..limit, do: throw(:invalid_handshake)
    {type, value}
  end

  defp handshake_name_value(oid, _tag, _bytes, encoded) do
    if oid in [
         {2, 5, 4, 6},
         {2, 5, 4, 5},
         {2, 5, 4, 46},
         {0, 9, 2342, 19_200_300, 100, 1, 25},
         {1, 2, 840, 113_549, 1, 9, 1}
       ],
       do: throw(:invalid_handshake),
       else: {:asn1_OPENTYPE, encoded}
  end

  defp handshake_events(packets, rest) do
    events = Enum.map(packets, &{:next_event, :internal, {:handshake, &1}})

    if rest == <<>>,
      do: events,
      else:
        events ++
          [{:next_event, :internal, {:protocol_record, {:ssl_tls, 22, :undefined, rest, false}}}]
  end

  defp handshake_record(state, pid) do
    case {get_in(state, [:handshake_rest, pid]), Map.fetch(state.parsed, pid)} do
      {%{record: record}, _} -> record
      {nil, {:ok, parsed}} -> selected_record(parsed)
      {nil, :error} -> :missing_tls_record_origin
    end
  end

  defp handshake_copy(state, source, path, expected, origin) do
    actual = native_term(source.event, path)
    state = tls_exact(state, source, :tls_handshake_copy, actual, expected)
    state = tls_error_path(state, source, path, :tls_handshake_copy)
    copy = %{index: source.index, path: path, origin: origin}
    Map.update!(state, :terms, &[copy | &1])
  end

  defp sender_plaintext(state, source) do
    case Map.get(state.messages, source.pid) do
      %{value: {{:call, {caller, _tag}}, {:application_data, _data}}} ->
        socket = state.owners[source.pid].family.socket

        writes =
          Enum.filter(Map.get(state.pair_index, {caller, {:ssl, :send, 2}}, []), fn pair ->
            pair.source.pid == caller and pair.source.mfa == {:ssl, :send, 2} and
              pair.source.index < source.index and pair.returned.index > source.index
          end)

        case writes do
          [%{source: %{event: {_, :call, {:ssl, :send, [^socket, data]}}}}] ->
            {:ok, :erlang.iolist_to_iovec(data)}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp worker_return(state, source, result) do
    call = Map.get(state.returns, source.index)

    case Map.pop(state.records, call) do
      {nil, _records} ->
        worker_frame_return(state, source, result)

      {record, records} ->
        state
        |> Map.put(:records, records)
        |> record_result(source, record, result)
        |> record_return(source, record)
    end
  end

  defp record_result(state, source, %{kind: :handshakes, result: result, input: input}, _actual) do
    result
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.reduce(state, fn {expected, position}, state ->
      handshake_copy(state, source, [3, position], expected, input.origin)
    end)
  end

  defp record_result(state, source, %{kind: :handshake_exception}, _actual),
    do: tls_failure(state, source, :tls_handshake_copy)

  defp record_result(state, source, %{kind: :handshake_value} = record, _actual),
    do: handshake_copy(state, source, [3], record.result, record.origin)

  defp record_result(state, source, %{kind: :handshake_state} = record, _actual),
    do: handshake_copy(state, source, [3], record.result, record.origin)

  defp record_result(state, source, %{kind: :prepared_connection} = record, _actual),
    do: handshake_copy(state, source, [3], record.result, record.origin)

  defp record_result(state, source, %{kind: :server_hello} = record, _actual),
    do: handshake_copy(state, source, [3], record.result, record.origin)

  defp record_result(state, source, %{kind: :server_hello_state} = record, _actual),
    do: handshake_copy(state, source, [3], record.result, record.origin)

  defp record_result(state, source, %{kind: :legacy_hello} = record, _actual),
    do: handshake_copy(state, source, [3], record.result, {:tls_legacy_hello, source.index})

  defp record_result(state, source, %{kind: :callback_mode} = record, _actual),
    do: program_term(state, source, [3], record.result, record.change.origin)

  defp record_result(state, source, record, actual),
    do: tls_exact(state, source, :tls_record_output, actual, record.result)

  defp record_return(state, source, %{kind: :encode} = record),
    do: put_in(state.encoded[source.pid], Map.put(record, :origin, {:tls_record, source.index}))

  defp record_return(
         state,
         source,
         %{kind: :alert_encode, result: {encoded, states}, program: :sender} = record
       ) do
    [frame | rest] = state.frames[source.pid]
    version = %{frame.input | data: put_elem(frame.input.data, 2, states), origin: record.origin}
    frame = frame |> Map.put(:current, version) |> Map.put(:alert_program, encoded)
    put_in(state.frames[source.pid], [frame | rest])
  end

  defp record_return(state, source, %{kind: :alert_encode} = record) do
    [frame | rest] = state.frames[source.pid]
    state = put_in(state.frames[source.pid], [Map.put(frame, :receiver_alert, record) | rest])
    from = elem(elem(frame.input.data, 9), 1)
    last = state.pairs[frame.source.index].returned.index

    if from == :undefined do
      tls_failure(state, source, :tls_certificate_alert_reply_origin)
    else
      put_in(state.direct_replies[source.pid], %{
        from: from,
        reply: certificate_alert_reply(record.program.send_alert),
        origin: record.origin,
        last: last
      })
    end
  end

  defp record_return(state, source, %{kind: :records, parsed: parsed}) do
    parsed = %{parsed | origin: source.index}
    put_in(state.parsed[source.pid], parsed)
  end

  defp record_return(state, source, %{kind: :record_alert}),
    do: Map.update!(state, :parsed, &Map.delete(&1, source.pid))

  defp record_return(state, source, %{kind: :handshake_state} = record) do
    [frame | rest] = state.frames[source.pid]
    version = %{frame.current | data: record.result, origin: record.origin}
    put_in(state.frames[source.pid], [%{frame | current: version} | rest])
  end

  defp record_return(state, source, %{kind: :prepared_connection} = record) do
    [frame | rest] = state.frames[source.pid]
    version = %{frame.current | data: record.data, origin: record.origin}
    frame = %{frame | current: version}

    frame =
      case frame.source.mfa do
        {:tls_client_connection_1_3, :wait_finished, 3} ->
          Map.put(frame, :connection_ready, [
            :connection,
            :no_record,
            [{{:timeout, :handshake}, :cancel}]
          ])

        {:tls_client_connection, :cipher, 3} ->
          Map.put(frame, :connection_ready, [
            :connection,
            :no_record,
            [{{:timeout, :handshake}, :infinity, :close}]
          ])

        _ ->
          frame
      end

    put_in(state.frames[source.pid], [frame | rest])
  end

  defp record_return(state, source, %{kind: :server_hello} = record) do
    [frame | rest] = state.frames[source.pid]
    data = frame.current.data
    environment = elem(data, 6)
    stapling = Map.merge(elem(environment, 32), record.stapling)

    data =
      data
      |> put_elem(3, put_elem(elem(data, 3), 5, record.selected))
      |> put_elem(6, put_elem(environment, 32, stapling))

    version = %{
      frame.current
      | name: :wait_sh,
        data: data,
        origin: {:tls_server_hello, source.index}
    }

    put_in(state.frames[source.pid], [%{frame | current: version} | rest])
  end

  defp record_return(state, source, %{kind: :legacy_hello, program: program}) do
    [frame | rest] = state.frames[source.pid]
    origin = {:tls_legacy_hello, source.index}
    frame = %{frame | current: %{frame.current | origin: origin}}
    put_in(state.frames[source.pid], [Map.put(frame, :legacy_hello, program) | rest])
  end

  defp record_return(state, source, %{kind: :server_hello_state} = record) do
    [frame | rest] = state.frames[source.pid]
    version = %{frame.current | name: record.name, data: record.data, origin: record.origin}
    put_in(state.frames[source.pid], [%{frame | current: version} | rest])
  end

  defp record_return(state, source, %{kind: :callback_mode} = record) do
    root = state.machine_states[source.pid]

    state
    |> put_in([:machine_states, source.pid], %{root | params: record.result})
    |> update_in([:module_changes, source.pid], &((&1 || []) ++ [record.change]))
    |> put_in([:machine_programs, source.pid, :module_action], nil)
  end

  defp record_return(state, source, %{kind: :decode, result: {record, states}}) do
    case Map.fetch(state.parsed, source.pid) do
      {:ok, parsed} ->
        parsed = decoded_record(parsed, record, states)
        put_in(state.parsed[source.pid], %{parsed | origin: source.index})

      :error ->
        tls_failure(state, source, :tls_record_origin)
    end
  end

  defp record_return(state, source, %{kind: :decode, result: {:alert, _, _, _, _, _}}),
    do: Map.update!(state, :parsed, &Map.delete(&1, source.pid))

  defp record_return(
         state,
         source,
         %{kind: :handshakes, result: {packets, buffer, rest}, input: input}
       ) do
    events = handshake_events(packets, rest)
    data = put_elem(input.data, 11, put_elem(elem(input.data, 11), 2, buffer))

    data =
      if packets != [] and input.name != :connection,
        do: put_elem(data, 6, put_elem(elem(data, 6), 2, length(events) - 1)),
        else: data

    [frame | frames] = state.frames[source.pid]
    version = %{input | data: data, origin: {:tls_handshakes, source.index}}
    program = %{packets: packets, rest: rest, events: events, origin: source.index}
    frame = frame |> Map.put(:current, version) |> Map.put(:handshake_program, program)
    state = put_in(state.frames[source.pid], [frame | frames])
    packets = Enum.map(packets, &%{packet: &1, origin: source.index})
    state = update_in(state.handshake_packets[source.pid], &((&1 || []) ++ packets))

    if rest == <<>> do
      state
    else
      continuation = %{record: {:ssl_tls, 22, :undefined, rest, false}, origin: source.index}

      put_in(state.handshake_rest[source.pid], continuation)
    end
  end

  defp record_return(state, _source, _record), do: state

  # TLS 1.3 may coalesce application fragments, suppress early records, or
  # speculatively decrypt a non-application record after an application run.
  # That last branch retains the ciphertext and its earlier cipher state.
  defp decoded_record(parsed, {:ssl_tls, 23, _, fragment, early_data} = record, states) do
    [_cipher | remaining] = parsed.remaining
    fragments = parsed.fragments ++ [fragment]
    tls13? = elem(elem(parsed.input.data, 3), 5) == {3, 4}

    %{
      parsed
      | remaining: remaining,
        states: states,
        fragments: fragments,
        early_data: if(tls13?, do: early_data, else: parsed.early_data),
        record: put_elem(record, 3, IO.iodata_to_binary(fragments))
    }
  end

  defp decoded_record(parsed, :no_record, states) do
    [_cipher | remaining] = parsed.remaining
    %{parsed | remaining: remaining, states: states, record: accumulated_record(parsed)}
  end

  defp decoded_record(%{fragments: []} = parsed, {:ssl_tls, _, _, _, _} = record, states) do
    [_cipher | remaining] = parsed.remaining
    %{parsed | remaining: remaining, states: states, record: record}
  end

  defp decoded_record(parsed, {:alert, _, _, _, _, _} = alert, states) do
    [_cipher | remaining] = parsed.remaining
    %{parsed | remaining: remaining, states: states, record: alert}
  end

  defp decoded_record(parsed, {:ssl_tls, _, _, _, _}, _states),
    do: %{parsed | record: accumulated_record(parsed)}

  defp accumulated_record(%{fragments: []}), do: :no_record

  defp accumulated_record(parsed),
    do: {:ssl_tls, 23, :undefined, IO.iodata_to_binary(parsed.fragments), parsed.early_data}

  defp selected_record(%{remaining: [{:ssl_tls, type, _, _, _} | _], fragments: [_ | _]} = parsed)
       when type != 23 do
    if elem(elem(parsed.input.data, 3), 5) == {3, 4},
      do: parsed.record,
      else: accumulated_record(parsed)
  end

  defp selected_record(parsed), do: parsed.record

  defp application_record_buffer(parsed, version) do
    case selected_record(parsed) do
      {:ssl_tls, 23, _version, plaintext, _early_data} -> {:ok, version, plaintext}
      _ -> :error
    end
  end

  # A modeled constructor or an exact copy of one supplies each root result.
  # A checked native return is never its own semantic expectation.
  defp worker_frame_return(state, source, result) do
    case Map.get(state.frames, source.pid, []) do
      [%{source: %{mfa: mfa}} = frame | rest] when mfa == source.mfa ->
        {state, version} = worker_output(state, source, frame)
        state = callback_result(state, source, frame, version, result)
        path = worker_result_data_path(source.mfa, result)

        state =
          if path,
            do: worker_copy(state, source, [3 | path], version.data, version.origin),
            else: state

        {expected, results} = Map.pop(state.callback_results, source.index)
        state = %{state | callback_results: results}
        state = put_in(state.frames[source.pid], rest)

        state =
          if rest == [] and is_nil(expected),
            do: tls_failure(state, source, :tls_callback_origin),
            else: state

        state =
          if rest == [],
            do:
              put_in(
                state.machine_callbacks[source.pid],
                callback_program(
                  state,
                  source,
                  frame,
                  if(Map.has_key?(frame, :callback_form),
                    do: callback_source_form(frame.callback_form.value, version),
                    else: expected
                  )
                )
              ),
            else: state

        state = advance_worker(state, source, version, rest)
        forward_callback_form(state, source, result, expected, rest)

      _ ->
        state
    end
  end

  # A tail-return is a copy of the earlier constructor's concrete source form.
  # Its state still comes from the independent worker model. The native action
  # interpreter receives that source form after the constructor/copy checks;
  # it never learns an expected state or state name from the checked return.
  defp callback_source_form({:next_state, _name, _data}, version),
    do: {:next_state, version.name, version.data}

  defp callback_source_form({:next_state, _name, _data, actions}, version),
    do: {:next_state, version.name, version.data, actions}

  defp callback_source_form({:keep_state, _data}, version),
    do: {:keep_state, version.data}

  defp callback_source_form({:keep_state, _data, actions}, version),
    do: {:keep_state, version.data, actions}

  defp callback_source_form(:keep_state_and_data, _version), do: :keep_state_and_data

  defp callback_source_form({:keep_state_and_data, actions}, _version),
    do: {:keep_state_and_data, actions}

  defp callback_source_form({:repeat_state, _data}, version),
    do: {:repeat_state, version.data}

  defp callback_source_form({:repeat_state, _data, actions}, version),
    do: {:repeat_state, version.data, actions}

  defp callback_source_form(:repeat_state_and_data, _version), do: :repeat_state_and_data

  defp callback_source_form({:repeat_state_and_data, actions}, _version),
    do: {:repeat_state_and_data, actions}

  defp callback_source_form(:stop, _version), do: :stop
  defp callback_source_form({:stop, reason}, _version), do: {:stop, reason}

  defp callback_source_form({:stop, reason, _data}, version),
    do: {:stop, reason, version.data}

  defp callback_source_form({:stop_and_reply, reason, replies}, _version),
    do: {:stop_and_reply, reason, replies}

  defp callback_source_form({:stop_and_reply, reason, replies, _data}, version),
    do: {:stop_and_reply, reason, replies, version.data}

  defp callback_source_form(_invalid, _version), do: :invalid_callback_source_form

  defp forward_callback_form(state, source, result, expected, [_parent | _])
       when source.mfa in [
              {:tls_sender, :hibernate_after, 3},
              {:tls_sender, :send_application_data, 4}
            ] do
    [parent | rest] = state.frames[source.pid]

    parent =
      parent
      |> Map.put(:callback_form, %{value: result, origin: source.index})
      |> Map.put(:callback_expected, expected)

    put_in(state.frames[source.pid], [parent | rest])
  end

  defp forward_callback_form(state, source, _result, expected, [_parent | _])
       when not is_nil(expected) do
    [parent | rest] = state.frames[source.pid]
    parent = Map.put(parent, :callback_expected, expected)
    put_in(state.frames[source.pid], [parent | rest])
  end

  defp forward_callback_form(state, _source, _result, _expected, _rest), do: state

  # State entry runs inside the original transition. Its own callback result
  # drives the native callback-result helper, while the original action program
  # still owns the pending events and timers at the final loop commit.
  defp callback_program(state, source, %{event: %{value: {:enter, _}}} = frame, result) do
    current = %{source: source, result: result, fresh?: true}

    with %{fresh?: true} = previous <- state.machine_callbacks[source.pid],
         earlier = Map.get(previous, :root_result, previous.result),
         {:ok, _name, _data, actions} <-
           transition_result(earlier, frame.input.name, frame.input.data),
         {:ok, name, data, entered} <-
           transition_result(result, frame.input.name, frame.input.data) do
      Map.merge(current, %{
        root_source: Map.get(previous, :root_source, previous.source),
        root_result: {:next_state, name, data, actions ++ entered}
      })
    else
      _ -> current
    end
  end

  defp callback_program(_state, source, _frame, result),
    do: %{source: source, result: result, fresh?: true}

  defp callback_result(
         state,
         %{mfa: {:tls_client_connection_1_3, :wait_cert_cr, 3}} = source,
         %{receiver_alert: _},
         version,
         actual
       ) do
    if version.origin == {:tls_certificate_refusal, source.index} do
      callback_result_exact(state, source, actual, {:stop, {:shutdown, :own_alert}, version.data})
    else
      state
    end
  end

  defp callback_result(
         state,
         %{mfa: {:tls_gen_connection, function, _}} = source,
         _frame,
         version,
         actual
       )
       when function in [:next_record, :next_record_done] do
    case {Map.fetch(state.parsed, source.pid), actual} do
      {{:ok, parsed}, {record, _data}} ->
        state
        |> tls_exact(source, :tls_record_selection, record, selected_record(parsed))
        |> tls_error_path(source, [3, 0], :tls_record_selection)
        |> put_in([:callback_results, source.index], {selected_record(parsed), version.data})

      {:error, _} ->
        tls_failure(state, source, :tls_record_origin)

      _ ->
        tls_failure(state, source, :tls_record_selection)
    end
  end

  defp callback_result(
         state,
         %{mfa: {:ssl_gen_statem, :hibernate_after, 3}} = source,
         %{arguments: [name, _data, actual_actions]},
         version,
         actual
       ) do
    [_current | parents] = state.frames[source.pid]
    actions = receiver_actions(parents, version)

    if is_list(actions) do
      state
      |> tls_exact(source, :tls_callback_input, [name, actual_actions], [version.name, actions])
      |> callback_result_exact(source, actual, receiver_hibernate_result(version, actions))
    else
      tls_failure(state, source, :tls_callback_input_origin)
    end
  end

  defp callback_result(
         state,
         %{mfa: {:ssl_gen_statem, :connection, 3}} = source,
         %{event: %{value: {{:call, from}, {:close, _timeout}}}} = frame,
         version,
         actual
       ) do
    port = state.owners[source.pid].family.port

    closed? = elem(elem(frame.input.data, 3), 3)

    shutdown = record_primitive(state, frame.source, {:gen_tcp, :shutdown, 2}, [port, :write])
    received = record_primitive(state, frame.source, {:gen_tcp, :recv, 3}, [port, 0, 5_000])

    if closed? or (match?({:ok, _}, shutdown) and match?({:ok, _}, received)) do
      callback_result_exact(
        state,
        source,
        actual,
        {:stop_and_reply, {:shutdown, :normal}, {:reply, from, :ok}, version.data}
      )
    else
      tls_failure(state, source, :tls_callback_origin)
    end
  end

  defp callback_result(
         state,
         %{mfa: {:ssl_gen_statem, :read_application_data, 2}} = source,
         _frame,
         version,
         actual
       ),
       do: callback_result_exact(state, source, actual, {:no_record, version.data})

  defp callback_result(
         state,
         %{mfa: {:tls_gen_connection, :next_event, _arity}} = source,
         frame,
         version,
         actual
       ) do
    case Map.fetch(frame, :callback_expected) do
      {:ok, expected} ->
        case transition_result(expected, version.name, version.data) do
          {:ok, _, _, _} -> callback_result_exact(state, source, actual, expected)
          :error -> next_record_callback_result(state, source, version, actual)
        end

      :error ->
        next_record_callback_result(state, source, version, actual)
    end
  end

  defp callback_result(
         state,
         %{mfa: {:tls_sender, :connection, 3}} = source,
         %{event: %{value: {{:call, from}, {:ack_alert, _alert}}}},
         version,
         actual
       ) do
    expected = {:next_state, :connection, version.data, [{:reply, from, :ok}]}
    callback_result_exact(state, source, actual, expected)
  end

  defp callback_result(
         state,
         %{mfa: {:tls_sender, :connection, 3}} = source,
         %{event: %{value: {:cast, {:alert, _, _, _, _, _}}}},
         version,
         actual
       ),
       do: callback_result_exact(state, source, actual, {:next_state, :connection, version.data})

  defp callback_result(
         state,
         %{mfa: {:tls_sender, :handle_common, 4}} = source,
         %{event: %{value: {:info, {:EXIT, _supervisor, reason}}}},
         version,
         actual
       ) do
    distribution = elem(elem(version.data, 1), 9)

    expected =
      case {distribution, reason} do
        {false, :shutdown} ->
          {:stop, {:shutdown, :shutdown}, version.data}

        {handle, :shutdown} when handle != :undefined ->
          {:next_state, :death_row, version.data, [{:state_timeout, 5_000, :shutdown}]}

        {:undefined, :shutdown} ->
          {:stop, :shutdown, version.data}

        {handle, reason} when handle != :undefined ->
          {:stop, {:shutdown, reason}, version.data}

        _ ->
          sender_hibernate_result(version, [])
      end

    callback_result_exact(state, source, actual, expected)
  end

  defp callback_result(
         state,
         %{mfa: {:tls_sender, :connection, 3}} = source,
         %{event: %{value: {:timeout, :hibernate}}},
         _version,
         actual
       ),
       do: callback_result_exact(state, source, actual, {:keep_state_and_data, [:hibernate]})

  defp callback_result(
         state,
         %{mfa: {:tls_sender, :death_row, 3}} = source,
         %{event: %{value: {:state_timeout, reason}}},
         _version,
         actual
       ),
       do: callback_result_exact(state, source, actual, {:stop, {:shutdown, reason}})

  defp callback_result(state, source, %{expected_handshake: expected} = frame, version, actual) do
    {handshake, _raw} = expected.packet

    result =
      if ignored_hello_request?(handshake, frame.input),
        do: :keep_state_and_data,
        else: {:next_state, version.name, version.data, [{:next_event, :internal, handshake}]}

    callback_result_exact(state, source, actual, result)
  end

  defp callback_result(
         state,
         %{mfa: {:tls_client_connection, :hello, 3}} = source,
         %{legacy_hello: _, callback_expected: expected},
         _version,
         actual
       ),
       do: callback_result_exact(state, source, actual, expected)

  defp callback_result(
         state,
         %{mfa: {:tls_client_connection, :hello, 3}} = source,
         %{event: %{value: {:internal, {:server_hello, _, _, _, _, _} = hello}}},
         version,
         actual
       ) do
    expected =
      {:next_state, :wait_sh, version.data,
       [{:change_callback_module, :tls_client_connection_1_3}, {:next_event, :internal, hello}]}

    callback_result_exact(state, source, actual, expected)
  end

  defp callback_result(
         state,
         %{mfa: {:tls_sender, :init, 3}} = source,
         %{initialization_from: from},
         version,
         actual
       ) do
    expected = {:next_state, :handshake, version.data, [{:reply, from, :ok}]}
    callback_result_exact(state, source, actual, expected)
  end

  defp callback_result(
         state,
         %{mfa: {:tls_client_connection_1_3, name, 3}} = source,
         %{event: %{value: {:enter, _}}},
         version,
         actual
       )
       when name in [
              :start,
              :wait_sh,
              :wait_ee,
              :wait_cert_cr,
              :wait_cert,
              :wait_cv,
              :wait_finished
            ],
       do: callback_result_exact(state, source, actual, {:next_state, name, version.data, []})

  defp callback_result(
         state,
         %{mfa: {:tls_client_connection_1_3, name, 3}} = source,
         %{event: %{value: {:enter, _}}},
         version,
         actual
       )
       when name in [:hello_middlebox_assert, :hello_retry_middlebox_assert],
       do: callback_result_exact(state, source, actual, {:keep_state, version.data})

  defp callback_result(
         state,
         %{mfa: {:tls_client_connection_1_3, :wait_sh, 3}} = source,
         %{server_hello_program: %{retry?: true, hello: hello}},
         version,
         actual
       ) do
    expected = {:next_state, :start, version.data, [{:next_event, :internal, hello}]}
    callback_result_exact(state, source, actual, expected)
  end

  defp callback_result(
         state,
         %{mfa: {:tls_client_connection_1_3, :start, 3}} = source,
         _frame,
         %{origin: {:tls_retry_hello, _}} = version,
         actual
       ) do
    callback_result_exact(state, source, actual, {:next_state, version.name, version.data, []})
  end

  defp callback_result(
         state,
         %{mfa: {:tls_client_connection_1_3, name, 3}} = source,
         %{event: %{value: {:internal, {:change_cipher_spec, _type}}}},
         version,
         actual
       )
       when name in [
              :hello_middlebox_assert,
              :hello_retry_middlebox_assert,
              :start,
              :wait_sh,
              :wait_ee,
              :wait_cert_cr,
              :wait_cert,
              :wait_cv,
              :wait_finished
            ] do
    case Map.fetch(state.parsed, source.pid) do
      {:ok, parsed} ->
        case selected_record(parsed) do
          :no_record ->
            callback_result_exact(state, source, actual, receiver_hibernate_result(version, []))

          {:ssl_tls, _, _, _, _} = record ->
            expected =
              {:next_state, version.name, version.data,
               [{:next_event, :internal, {:protocol_record, record}}]}

            callback_result_exact(state, source, actual, expected)

          _ ->
            tls_failure(state, source, :tls_record_selection)
        end

      :error ->
        tls_failure(state, source, :tls_record_origin)
    end
  end

  defp callback_result(
         state,
         %{mfa: {:tls_gen_connection, :handle_protocol_record, 3}} = source,
         %{arguments: [{:ssl_tls, 20, _, _, _} | _]},
         version,
         actual
       ) do
    case handshake_record(state, source.pid) do
      {:ssl_tls, 20, _, fragment, _} ->
        actions = [{:next_event, :internal, {:change_cipher_spec, fragment}}]
        expected = {:next_state, version.name, version.data, actions}
        callback_result_exact(state, source, actual, expected)

      _ ->
        tls_failure(state, source, :tls_record_origin)
    end
  end

  defp callback_result(
         state,
         %{mfa: {:tls_gen_connection, :handle_protocol_record, 3}} = source,
         %{handshake_program: %{packets: [_ | _], events: events}},
         version,
         actual
       ) do
    expected =
      if version.name == :connection,
        do: receiver_hibernate_result(version, events),
        else: {:next_state, version.name, version.data, events}

    callback_result_exact(state, source, actual, expected)
  end

  defp callback_result(
         state,
         %{mfa: {:tls_sender, :handshake, 3}} = source,
         %{write_update: _update},
         version,
         actual
       ),
       do: callback_result_exact(state, source, actual, {:next_state, :connection, version.data})

  defp callback_result(
         state,
         %{mfa: {:tls_sender, :connection, 3}} = source,
         %{write_update: _update},
         version,
         actual
       ),
       do: callback_result_exact(state, source, actual, sender_hibernate_result(version, []))

  defp callback_result(
         state,
         %{mfa: {:tls_sender, :connection, 3}} = source,
         %{event: %{value: {{:call, _from}, {:application_data, _data}}}} = frame,
         version,
         actual
       ),
       do: forwarded_callback_result(state, source, frame, version, actual)

  defp callback_result(
         state,
         %{mfa: {:tls_sender, :send_application_data, 4}} = source,
         %{callback_form: _form} = frame,
         version,
         actual
       ),
       do: forwarded_callback_result(state, source, frame, version, actual)

  defp callback_result(
         state,
         %{mfa: {:tls_sender, :hibernate_after, 3}} = source,
         _frame,
         version,
         actual
       ),
       do: callback_result_exact(state, source, actual, sender_hibernate_result(version, []))

  defp callback_result(state, source, %{callback_expected: expected}, _version, actual)
       when not is_nil(expected),
       do: callback_result_exact(state, source, actual, expected)

  defp callback_result(state, _source, _frame, _version, _actual), do: state

  defp next_record_callback_result(state, source, version, actual) do
    [_current | parents] = state.frames[source.pid]

    actions =
      if source.mfa == {:tls_gen_connection, :next_event, 4},
        do: receiver_actions(parents, version),
        else: []

    case {actions, Map.get(state.parsed, source.pid)} do
      {actions, _parsed} when not is_list(actions) ->
        tls_failure(state, source, :tls_callback_input_origin)

      {_actions, nil} ->
        tls_failure(state, source, :tls_callback_origin)

      {actions, parsed} ->
        record = selected_record(parsed)

        if record == :no_record do
          tls_failure(state, source, :tls_callback_origin)
        else
          event =
            case record do
              {:ssl_tls, _, _, _, _} -> {:protocol_record, record}
              {:alert, _, _, _, _, _} -> record
            end

          expected =
            {:next_state, version.name, version.data, [{:next_event, :internal, event} | actions]}

          callback_result_exact(state, source, actual, expected)
        end
    end
  end

  defp forwarded_callback_result(state, source, frame, version, actual) do
    expected = sender_hibernate_result(version, [])

    case Map.get(frame, :callback_form) do
      %{value: source_form} ->
        state
        |> callback_result_exact(source, actual, source_form)
        |> put_in([:callback_results, source.index], expected)

      nil ->
        callback_result_exact(state, source, actual, expected)
    end
  end

  defp sender_hibernate_result(version, actions) do
    timeout = elem(elem(version.data, 1), 11)

    cond do
      version.name == :connection and timeout != :infinity ->
        {:next_state, version.name, version.data, [{:timeout, timeout, :hibernate} | actions]}

      actions == [] ->
        {:next_state, version.name, version.data}

      true ->
        {:next_state, version.name, version.data, actions}
    end
  end

  defp receiver_hibernate_result(version, actions) do
    case {version.name, Map.fetch(elem(version.data, 4), :hibernate_after)} do
      {:connection, {:ok, timeout}} when timeout != :infinity ->
        {:next_state, version.name, version.data, [{:timeout, timeout, :hibernate} | actions]}

      _ when actions == [] ->
        {:next_state, version.name, version.data}

      _ ->
        {:next_state, version.name, version.data, actions}
    end
  end

  defp callback_result_exact(state, source, actual, expected) do
    state
    |> tls_exact(source, :tls_callback_result, actual, expected)
    |> put_in([:callback_results, source.index], expected)
  end

  defp advance_worker(state, source, version, []) do
    version = %{version | origin: {:tls_callback_return, source.index}}
    put_in(state.pending[source.pid], version)
  end

  defp advance_worker(state, source, version, [parent | rest]),
    do: put_in(state.frames[source.pid], [%{parent | current: version} | rest])

  defp worker_output(
         state,
         _source,
         %{
           source: %{mfa: {:tls_sender, :send_tls_alert, 2}},
           alert_program: _encoded
         } = frame
       ) do
    case sender_alert(frame.event) do
      {:ok, alert} ->
        state = tls_exact(state, frame.source, :tls_alert_copy, hd(frame.arguments), alert)
        {state, frame.current}

      :error ->
        {tls_failure(state, frame.source, :tls_alert_origin), frame.current}
    end
  end

  defp worker_output(state, source, %{source: %{mfa: {:tls_sender, :send_tls_alert, 2}}} = frame),
    do: {tls_failure(state, source, :tls_alert_origin), frame.current}

  defp worker_output(
         state,
         source,
         %{
           source: %{mfa: {:tls_client_connection_1_3, :wait_cert_cr, 3}},
           receiver_alert: program
         } = frame
       ) do
    case receiver_certificate_refusal(state, source, frame, program) do
      {:ok, state, origin} -> {state, %{frame.input | origin: origin}}
      :error -> {tls_failure(state, source, :tls_certificate_refusal_origin), frame.current}
    end
  end

  defp worker_output(
         state,
         source,
         %{source: %{mfa: {:tls_gen_connection, :next_record_done, 4}}} = frame
       ) do
    case Map.fetch(state.parsed, source.pid) do
      {:ok, parsed} ->
        buffers = parsed.buffers |> put_elem(3, parsed.remaining)
        data = frame.input.data |> put_elem(10, parsed.states) |> put_elem(11, buffers)
        {state, %{frame.input | data: data, origin: {:tls_record_selection, source.index}}}

      :error ->
        {tls_failure(state, source, :tls_record_origin), frame.current}
    end
  end

  defp worker_output(
         state,
         source,
         %{source: %{mfa: {:tls_gen_connection, :next_record, 3}}} = frame
       ) do
    handshake = elem(frame.input.data, 6)
    outstanding = elem(handshake, 2)

    case Map.fetch(state.parsed, source.pid) do
      {:ok, parsed} ->
        buffers = parsed.buffers |> put_elem(3, parsed.remaining)
        data = put_elem(frame.current.data, 11, buffers)

        if outstanding > 0 do
          data = put_elem(data, 6, put_elem(handshake, 2, outstanding - 1))
          {state, %{frame.input | data: data, origin: {:tls_handshake_count, source.index}}}
        else
          {state, %{frame.current | data: data}}
        end

      :error ->
        {tls_failure(state, source, :tls_record_origin), frame.current}
    end
  end

  defp worker_output(
         state,
         source,
         %{source: %{mfa: {:ssl_gen_statem, :read_application_data, 2}}} = frame
       ) do
    case receiver_buffer(state, source.pid, frame) do
      {:ok, _version, expected} ->
        state = tls_exact(state, frame.source, :tls_plaintext_copy, hd(frame.arguments), expected)
        delivered_state(state, source, frame.input, expected)

      :error ->
        {tls_failure(state, source, :tls_plaintext_origin), frame.current}
    end
  end

  defp worker_output(
         state,
         source,
         %{
           source: %{mfa: {:tls_client_connection_1_3, :start, 3}},
           event: %{value: {:internal, {:server_hello, _, @hello_retry_random, _, _, extensions}}}
         } = frame
       ) do
    case retry_client_hello_output(state, source, frame, extensions) do
      {:ok, state, version} -> {state, version}
      :error -> {tls_failure(state, source, :tls_retry_hello_origin), frame.current}
    end
  end

  defp worker_output(
         state,
         source,
         %{
           source: %{mfa: {:tls_client_connection_1_3, name, 3}},
           event: %{value: {:enter, _}}
         } = frame
       )
       when name in [
              :start,
              :wait_sh,
              :wait_ee,
              :wait_cert_cr,
              :wait_cert,
              :wait_cv,
              :wait_finished
            ] do
    data = frame.input.data
    specific = Map.put(elem(data, 7), :change_cipher_spec, :ignore)

    version = %{
      frame.input
      | data: put_elem(data, 7, specific),
        origin: {:tls_middlebox, source.index}
    }

    {state, version}
  end

  defp worker_output(
         state,
         source,
         %{expected_handshake: %{packet: {handshake, raw}}} = frame
       ) do
    if ignored_hello_request?(handshake, frame.input) do
      {state, frame.input}
    else
      data = frame.input.data
      environment = elem(data, 6)
      {messages, _previous} = elem(environment, 3)
      history = {[raw | messages], messages}
      data = put_elem(data, 6, put_elem(environment, 3, history))
      {state, %{frame.input | data: data, origin: {:tls_handshake_history, source.index}}}
    end
  end

  defp worker_output(state, source, frame) do
    case {frame.source.mfa, frame.event} do
      {{:ssl_gen_statem, :connection, 3}, %{value: {{:call, _}, {:close, _}}}} ->
        data = frame.input.data
        environment = put_elem(elem(data, 3), 3, true)

        {state,
         %{frame.input | data: put_elem(data, 3, environment), origin: {:tls_close, source.index}}}

      _ ->
        {state, frame.current}
    end
  end

  defp certificate_alert_reply({:alert, 2, 42, %{file: file, line: line}, :client, reason}) do
    format =
      ~c"TLS client: In state wait_cert_cr at ~s:~B" ++
        ~c" generated CLIENT ALERT: Fatal - Bad Certificate~n ~P"

    message =
      format
      |> :io_lib.format([file, line, reason, 20])
      |> List.flatten()

    {:error, {:tls_alert, {:bad_certificate, message}}}
  end

  defp receiver_certificate_refusal(state, source, frame, record) do
    %{result: {encoded, states}, program: program} = record
    data = frame.input.data
    origin = {:tls_certificate_refusal, source.index}
    own_mfa = {:ssl_gen_statem, :handle_own_alert, 3}
    send_mfa = {:tls_gen_connection, :send_alert, 2}
    reply_mfa = {:gen_statem, :reply, 2}
    port = state.owners[source.pid].family.port

    with [own] <- tls_scoped_calls(state, program.pair.returned, source, own_mfa),
         [send] <- tls_scoped_calls(state, own.source, own.returned, send_mfa),
         [reply] <- tls_scoped_calls(state, send.returned, own.returned, reply_mfa),
         [write] <-
           Enum.filter(state.transport.writes, fn write ->
             write.port == port and write.source.pid == source.pid and
               send.source.index < write.source.index and
               write.returned.index < send.returned.index
           end) do
      state =
        state
        |> handshake_copy(
          program.pair.source,
          [2, 2],
          [program.certificate, data],
          frame.input.origin
        )
        |> handshake_copy(program.pair.returned, [3], {program.alert, data}, origin)
        |> handshake_copy(own.source, [2, 2], [program.alert, :wait_cert_cr, data], origin)
        |> handshake_copy(send.source, [2, 2], [program.send_alert, data], origin)
        |> handshake_copy(send.returned, [3], put_elem(data, 10, states), record.origin)
        |> handshake_copy(reply.returned, [3], :ok, origin)
        |> handshake_copy(own.returned, [3], {:stop, {:shutdown, :own_alert}, data}, origin)
        |> tls_exact(
          write.source,
          :tls_certificate_alert_write,
          write.bytes,
          IO.iodata_to_binary(encoded)
        )

      {:ok, state, origin}
    else
      _ -> :error
    end
  end

  defp ignored_hello_request?({:hello_request}, version),
    do: version.name != :connection and elem(elem(version.data, 2), 1) == :client

  defp ignored_hello_request?(_handshake, _version), do: false

  # This is the TLS-1.3 ServerHello branch of the pinned negotiation program.
  # The packet came from plaintext decoding and the options from the modeled
  # client. No checked negotiation helper or state callback supplies this result.
  defp server_hello_selection(%{
         event: %{
           value: {:internal, {:server_hello, {3, 3}, random, session, cipher, extensions} = hello}
         },
         input: input
       }) do
    options = elem(input.data, 4)

    with {:server_hello_selected_version, {3, 4} = selected} <-
           Map.get(extensions, :server_hello_selected_version, :undefined),
         true <- selected in Map.fetch!(options, :versions),
         true <- is_binary(random) and byte_size(random) == 32,
         true <- binary_part(random, 24, 8) != <<"DOWNGRD", 1>>,
         true <- elem(elem(input.data, 6), 12) != :pause do
      {:ok, hello, selected,
       %{configured: Map.has_key?(options, :stapling), status: :not_negotiated}}
    else
      :undefined -> legacy_server_hello(input.data, hello, session, cipher, random, extensions)
      _ -> :error
    end
  end

  defp server_hello_selection(_frame), do: :error

  defp legacy_server_hello(data, hello, id, cipher, random, extensions) do
    options = elem(data, 4)
    handshake = elem(data, 6)
    session = elem(data, 8)
    states = elem(data, 10)
    version = {3, 3}

    with true <- version in options.versions and cipher in options.ciphers,
         {false, _} <- elem(handshake, 5),
         true <- elem(handshake, 12) != :pause,
         false <- id != <<>> and id == elem(session, 1) and elem(session, 10) == true,
         true <- not legacy_downgrade?(options.versions, random),
         {:ok, parameters} <- legacy_cipher_parameters(cipher),
         {:ok, secure?} <- legacy_secure_renegotiation(Map.get(extensions, :renegotiation_info)),
         true <- legacy_fragment_limit?(extensions, states),
         {:ok, protocol_kind, protocol} <- legacy_application_protocol(extensions, options),
         {:ok, stapling} <- legacy_stapling(extensions, options) do
      states = legacy_pending_cipher(states, random, secure?, parameters)
      result = {version, id, states, protocol_kind, protocol, stapling}
      next = legacy_new_session(data, result, cipher, parameters.exchange)
      {:legacy, %{hello: hello, result: result, next: next}}
    else
      _ -> :error
    end
  end

  defp legacy_downgrade?([{3, 4} | _], <<_::binary-size(24), "DOWNGRD", 1>>), do: true
  defp legacy_downgrade?(_versions, _random), do: false

  defp legacy_secure_renegotiation({:renegotiation_info, <<0>>}), do: {:ok, true}
  defp legacy_secure_renegotiation(missing) when missing in [nil, :undefined], do: {:ok, false}
  defp legacy_secure_renegotiation(_renegotiation), do: :error

  defp legacy_fragment_limit?(extensions, states) do
    sizes = %{512 => 1, 1024 => 2, 2048 => 3, 4096 => 4}

    expected =
      case Map.fetch(sizes, Map.get(states, :max_fragment_length)) do
        {:ok, size} -> {:max_frag_enum, size}
        :error -> :undefined
      end

    Map.get(extensions, :max_frag_enum, :undefined) == expected
  end

  defp legacy_application_protocol(extensions, options) do
    case encrypted_extensions_alpn(Map.get(extensions, :alpn, :undefined)) do
      {:ok, :undefined} ->
        if Map.get(extensions, :next_protocol_negotiation, :undefined) == :undefined,
          do: {:ok, :npn, :undefined},
          else: :error

      {:ok, protocol} ->
        if protocol in Map.get(options, :alpn_advertised_protocols, []),
          do: {:ok, :alpn, protocol},
          else: :error

      :error ->
        :error
    end
  end

  defp legacy_stapling(extensions, options) do
    configured? = Map.has_key?(options, :stapling)

    case Map.get(extensions, :status_request, false) do
      false -> {:ok, %{configured: configured?, status: :not_negotiated}}
      :undefined when configured? -> {:ok, %{configured: true, status: :negotiated}}
      _ -> :error
    end
  end

  defp legacy_cipher_parameters(cipher) do
    hashes = %{
      null: {0, 0},
      aead: {:aead, 0},
      md5: {1, 16},
      sha: {2, 20},
      sha256: {4, 32},
      sha384: {5, 48},
      sha512: {6, 64}
    }

    with %{key_exchange: exchange, cipher: algorithm, mac: mac, prf: prf} <-
           :ssl_cipher_format.suite_bin_to_map(cipher),
         true <- exchange in [:ecdhe_rsa, :ecdhe_ecdsa, :dhe_rsa, :dhe_dss],
         {:ok, bulk, type, iv, key} <- legacy_cipher_shape(algorithm),
         {:ok, {mac, hash_size}} <- Map.fetch(hashes, mac),
         {:ok, {prf, _}} <- Map.fetch(hashes, if(prf == :default_prf, do: :sha256, else: prf)) do
      {:ok, %{exchange: exchange, parameters: [cipher, bulk, type, iv, key, mac, prf, hash_size]}}
    else
      _ -> :error
    end
  end

  defp legacy_cipher_shape(:chacha20_poly1305), do: {:ok, 9, 2, 12, 32}
  defp legacy_cipher_shape(:aes_128_cbc), do: {:ok, 7, 1, 16, 16}
  defp legacy_cipher_shape(:aes_256_cbc), do: {:ok, 7, 1, 16, 32}
  defp legacy_cipher_shape(:aes_128_gcm), do: {:ok, 8, 2, 4, 16}
  defp legacy_cipher_shape(:aes_256_gcm), do: {:ok, 8, 2, 4, 32}
  defp legacy_cipher_shape(:aes_128_ccm), do: {:ok, 10, 2, 4, 16}
  defp legacy_cipher_shape(:aes_256_ccm), do: {:ok, 10, 2, 4, 32}
  defp legacy_cipher_shape(:aes_128_ccm_8), do: {:ok, 11, 2, 4, 16}
  defp legacy_cipher_shape(:aes_256_ccm_8), do: {:ok, 11, 2, 4, 32}
  defp legacy_cipher_shape(_algorithm), do: :error

  defp legacy_pending_cipher(states, random, secure?, %{parameters: [cipher | fields]}) do
    Enum.reduce([:current_read, :current_write, :pending_read, :pending_write], states, fn
      direction, states when direction in [:current_read, :current_write] ->
        put_in(states, [direction, :reneg, :secure_renegotiation], secure?)

      direction, states ->
        parameters =
          states[direction].security_parameters
          |> put_elem(1, cipher)
          |> put_elem(15, random)

        parameters =
          fields
          |> Enum.with_index(3)
          |> Enum.reduce(parameters, fn {value, index}, record ->
            put_elem(record, index, value)
          end)

        states
        |> put_in([direction, :reneg, :secure_renegotiation], secure?)
        |> put_in([direction, :security_parameters], parameters)
    end)
  end

  defp legacy_new_session(
         data,
         {version, id, states, kind, protocol, stapling},
         cipher,
         exchange
       ) do
    handshake = elem(data, 6)
    name = if protocol == :undefined, do: elem(handshake, 18), else: protocol

    handshake =
      handshake
      |> put_elem(6, false)
      |> put_elem(15, kind == :npn and protocol != :undefined)
      |> put_elem(18, name)
      |> put_elem(21, exchange)
      |> put_elem(26, :undefined)
      |> put_elem(32, Map.merge(elem(handshake, 32), stapling))

    data
    |> put_elem(3, put_elem(elem(data, 3), 5, version))
    |> put_elem(6, handshake)
    |> put_elem(8, elem(data, 8) |> put_elem(1, id) |> put_elem(6, cipher))
    |> put_elem(10, states)
  end

  defp legacy_server_key_exchange(state, first, last, data, wire) do
    handshake = elem(data, 6)
    session = elem(data, 8)
    states = elem(data, 10)
    parameters = states.pending_read.security_parameters
    client_random = elem(parameters, 14)
    server_random = elem(parameters, 15)
    exchange = elem(handshake, 21)
    scope = %{source: first, returned: last}

    with {:ok, agreement, body, signature_scheme, signature} <- legacy_peer_key(exchange, wire),
         hash_sign = legacy_hash_sign(signature_scheme),
         true <-
           legacy_verify_signature(
             hash_sign,
             signature,
             [client_random, server_random, body],
             elem(handshake, 25)
           ),
         {:ok, keys, shared} <- legacy_shared_secret(state, scope, agreement),
         {:ok, hash} <- record_mac_algorithm(elem(parameters, 8)),
         master = legacy_prf(hash, shared, "master secret", [client_random, server_random], 48),
         {:ok, states} <- legacy_session_keys(state, first, last, states, master) do
      session = put_elem(session, 7, master)
      session =
        if elem(keys, 0) == :ECPrivateKey, do: put_elem(session, 12, elem(keys, 3)), else: session
      handshake = handshake |> put_elem(19, hash_sign) |> put_elem(22, keys)
      {:ok, data |> put_elem(6, handshake) |> put_elem(8, session) |> put_elem(10, states)}
    else
      _ -> :error
    end
  end

  defp legacy_peer_key(
         exchange,
         <<3, group::16, size, point::binary-size(size), scheme::16, length::16,
           signature::binary-size(length)>>
       )
       when exchange in [:ecdhe_rsa, :ecdhe_ecdsa] do
    case Map.fetch(@handshake_curve_oids, group) do
      {:ok, oid} ->
        {:ok, {:ecdh, oid, point}, <<3, group::16, size, point::binary>>, scheme, signature}

      :error ->
        :error
    end
  end

  defp legacy_peer_key(
         exchange,
         <<p_len::16, p::binary-size(p_len), g_len::16, g::binary-size(g_len), y_len::16,
           peer::binary-size(y_len), scheme::16, size::16, signature::binary-size(size)>>
       )
       when exchange in [:dhe_rsa, :dhe_dss] and p_len >= 128 do
    body = <<p_len::16, p::binary, g_len::16, g::binary, y_len::16, peer::binary>>
    parameters = [:binary.decode_unsigned(p), :binary.decode_unsigned(g)]
    {:ok, {:dh, parameters, peer}, body, scheme, signature}
  end

  defp legacy_peer_key(_exchange, _wire), do: :error

  defp legacy_hash_sign(scheme),
    do: handshake_signature_version(handshake_signature(scheme), scheme, {3, 3})

  defp legacy_verify_signature({hash, sign}, signature, body, key)
       when hash in [:sha, :sha224, :sha256, :sha384, :sha512] do
    options =
      if sign in [:rsa_pss_rsae, :rsa_pss_pss],
        do: [rsa_padding: :rsa_pkcs1_pss_padding, rsa_pss_saltlen: -1, rsa_mgf1_md: hash],
        else: []

    :public_key.verify(
      IO.iodata_to_binary(body),
      hash,
      signature,
      certificate_verify_key(key),
      options
    )
  rescue
    _invalid in [ArgumentError, FunctionClauseError] -> false
  end

  defp legacy_verify_signature(_scheme, _signature, _body, _key), do: false

  defp legacy_shared_secret(state, scope, {:ecdh, oid, peer}) do
    curve = :pubkey_cert_records.namedCurves(oid)

    with {:ok, {public, private}} <-
           handshake_crypto_origin(state, scope, {:crypto, :generate_key, 2}, [:ecdh, curve]),
         {:ok, shared} <-
           handshake_primitive(state, scope, {:crypto, :compute_key, 4}, [
             :ecdh,
             peer,
             private,
             curve
           ]) do
      keys = {:ECPrivateKey, :ecPrivkeyVer1, private, {:namedCurve, oid}, public, :asn1_NOVALUE}
      {:ok, keys, shared}
    else
      _ -> :error
    end
  end

  defp legacy_shared_secret(state, scope, {:dh, parameters, peer}) do
    with {:ok, {_public, private} = keys} <-
           handshake_crypto_origin(state, scope, {:crypto, :generate_key, 2}, [:dh, parameters]),
         {:ok, shared} <-
           handshake_primitive(state, scope, {:crypto, :compute_key, 4}, [
             :dh,
             peer,
             private,
             parameters
           ]) do
      {:ok, keys, shared}
    else
      _ -> :error
    end
  end

  defp legacy_session_keys(state, first, last, states, master) do
    parameters = states.pending_read.security_parameters
    bulk = elem(parameters, 3)
    iv_size = elem(parameters, 5)
    key_size = elem(parameters, 6)
    mac_size = elem(parameters, 9)
    randoms = [elem(parameters, 15), elem(parameters, 14)]

    with {:ok, hash} <- record_mac_algorithm(elem(parameters, 8)),
         {:ok, client_nonce, server_nonce} <- legacy_cipher_nonces(state, first, last, bulk) do
      size = 2 * (iv_size + key_size + mac_size)
      material = legacy_prf(hash, master, "key expansion", randoms, size)

      <<client_mac::binary-size(mac_size), server_mac::binary-size(mac_size),
        client_key::binary-size(key_size), server_key::binary-size(key_size),
        client_iv::binary-size(iv_size), server_iv::binary-size(iv_size)>> = material

      client = legacy_cipher_state(bulk, client_iv, client_key, client_nonce)
      server = legacy_cipher_state(bulk, server_iv, server_key, server_nonce)

      states =
        states
        |> update_in([:pending_read], &legacy_install_key(&1, master, server, server_mac))
        |> update_in([:pending_write], &legacy_install_key(&1, master, client, client_mac))

      {:ok, states}
    end
  end

  defp legacy_cipher_nonces(state, first, last, bulk) when bulk in [8, 10, 11] do
    case legacy_entropy(state, first, last, 8) do
      [<<client::64>>, <<server::64>>] -> {:ok, client, server}
      _ -> :error
    end
  end

  defp legacy_cipher_nonces(_state, _first, _last, _bulk), do: {:ok, :undefined, :undefined}

  defp legacy_cipher_state(bulk, iv, key, nonce) do
    tag = Map.get(%{8 => 16, 9 => 16, 10 => 16, 11 => 8}, bulk, :undefined)
    cache = if tag == :undefined, do: <<>>, else: :undefined
    {:cipher_state, iv, key, :undefined, nonce, cache, tag}
  end

  defp legacy_install_key(direction, master, cipher, mac) do
    %{
      direction
      | security_parameters: put_elem(direction.security_parameters, 10, master),
        cipher_state: cipher,
        mac_secret: mac
    }
  end

  defp legacy_prf(hash, key, label, seed, size) do
    seed = [label | seed]
    legacy_prf_blocks(hash, key, seed, seed, size, [])
  end

  defp legacy_prf_blocks(hash, key, seed, previous, remaining, blocks) do
    a = :crypto.mac(:hmac, hash, key, previous)
    block = :crypto.mac(:hmac, hash, key, [a, seed])

    if remaining > byte_size(block) do
      legacy_prf_blocks(hash, key, seed, a, remaining - byte_size(block), [block | blocks])
    else
      blocks
      |> Enum.reverse([binary_part(block, 0, remaining)])
      |> IO.iodata_to_binary()
    end
  end

  defp legacy_entropy(state, first, last, length) do
    mfa = {:crypto, :strong_rand_bytes, 1}

    calls = tls_scoped_calls(state, first, last, mfa)

    for %{source: %{event: {_, :call, {_, _, [^length]}}}, returned: result} <- calls,
        {_, :return_from, ^mfa, bytes} <- [result.event],
        is_binary(bytes) and byte_size(bytes) == length,
        do: bytes
  end

  defp legacy_activate(state, first, last, states, direction) do
    {active, pending} =
      if direction == :read,
        do: {:current_read, :pending_read},
        else: {:current_write, :pending_write}

    connection_end = elem(states[pending].security_parameters, 2)
    secure? = get_in(states, [active, :reneg, :secure_renegotiation])

    with [clock] <- certificate_clock_reads(state, first, last),
         [random] <- legacy_entropy(state, first, last, 28) do
      seconds = :calendar.datetime_to_gregorian_seconds(clock) - 62_167_219_200

      replacement =
        Tuple.duplicate(:undefined, 16)
        |> put_elem(0, :security_parameters)
        |> put_elem(2, connection_end)
        |> put_elem(if(connection_end == 1, do: 14, else: 15), <<seconds::32, random::binary>>)

      empty = %{
        security_parameters: replacement,
        cipher_state: :undefined,
        mac_secret: :undefined,
        early_data: %{
          pending_early_data_size: 0,
          trial_decryption: false,
          early_data_accepted: false
        },
        reneg: %{
          secure_renegotiation: secure?,
          client_verify_data: :undefined,
          server_verify_data: :undefined
        }
      }

      current = Map.put(states[pending], :sequence_number, 0)
      {:ok, states |> Map.put(active, current) |> Map.put(pending, empty)}
    else
      _ -> :error
    end
  end

  defp legacy_client_flight(state, frame, last) do
    data = frame.current.data
    handshake = elem(data, 6)
    master = elem(elem(data, 8), 7)
    queue_mfa = {:tls_gen_connection, :queue_handshake, 2}
    ccs_mfa = {:tls_gen_connection, :queue_change_cipher, 2}
    send_mfa = {:tls_gen_connection, :send_handshake_flight, 1}

    with true <- elem(handshake, 29) == :not_requested and elem(handshake, 15) == false,
         true <- is_binary(master) and byte_size(master) == 48,
         {:ok, key, body} <- legacy_client_key(elem(handshake, 22)),
         {:ok, states} <- legacy_session_keys(state, frame.source, last, elem(data, 10), master),
         [exchange, finished] <- tls_scoped_calls(state, frame.source, last, queue_mfa),
         [change] <- tls_scoped_calls(state, exchange.returned, finished.source, ccs_mfa),
         [send] <- tls_scoped_calls(state, finished.returned, last, send_mfa),
         {:ok, state, exchanged} <-
           legacy_queue_handshake(
             state,
             exchange,
             key,
             handshake_fragment(16, body),
             put_elem(data, 10, states)
           ),
         {:ok, state, queued} <- legacy_change_cipher(state, change, exchanged),
         {:ok, states} <-
           legacy_activate(state, change.returned, finished.source, elem(queued, 10), :write),
         {history, _} <- elem(elem(queued, 6), 3),
         {:ok, verify} <-
           legacy_finished(states.current_write, master, "client finished", history),
         updated = [:current_write, :pending_read],
         states = legacy_verify_data(states, updated, :client_verify_data, verify),
         {:ok, state, sent} <-
           legacy_queue_handshake(
             state,
             finished,
             {:finished, verify},
             handshake_fragment(20, verify),
             put_elem(queued, 10, states)
           ),
         {:ok, state, next} <- legacy_send_flight(state, send, sent) do
      {:ok, state, next}
    else
      _ -> :error
    end
  end

  defp legacy_client_key({:ECPrivateKey, _, _, _, public, _}) when is_binary(public),
    do: {:ok, {:client_key_exchange, {:client_ec_diffie_hellman_public, public}},
         <<byte_size(public), public::binary>>}

  defp legacy_client_key({public, _private}) when is_binary(public),
    do: {:ok, {:client_key_exchange, {:client_diffie_hellman_public, public}},
         <<byte_size(public)::16, public::binary>>}

  defp legacy_client_key(_key), do: :error

  defp handshake_fragment(type, body), do: [type, <<byte_size(body)::24>>, body]

  defp legacy_queue_handshake(state, pair, message, fragment, data) do
    mfa = {:tls_gen_connection, :encode_handshake, 4}
    handshake = elem(data, 6)
    states = elem(data, 10)
    {messages, _} = history = elem(handshake, 3)
    next_history = {[fragment | messages], messages}
    version = {3, 3}

    with [encoder] <- tls_scoped_calls(state, pair.source, pair.returned, mfa),
         {:ok, encoded, next_states} <-
           encode_handshake_records(state, encoder.source, fragment, version, states) do
      handshake =
        handshake |> put_elem(3, next_history) |> put_elem(31, [elem(handshake, 31), encoded])

      next = data |> put_elem(6, handshake) |> put_elem(10, next_states)
      origin = {:tls_legacy_handshake, pair.source.index}

      state =
        state
        |> handshake_copy(pair.source, [2, 2], [message, data], origin)
        |> handshake_copy(encoder.source, [2, 2], [message, version, states, history], origin)
        |> handshake_copy(encoder.returned, [3], {encoded, next_states, next_history}, origin)
        |> handshake_copy(pair.returned, [3], next, origin)

      {:ok, state, next}
    else
      _ -> :error
    end
  end

  defp legacy_change_cipher(state, pair, data) do
    handshake = elem(data, 6)

    with {:ok, encoded, states} <-
           encode_record(state, pair.source, <<1>>, {3, 3}, elem(data, 10), 20) do
      handshake = put_elem(handshake, 31, [elem(handshake, 31), encoded])
      next = data |> put_elem(6, handshake) |> put_elem(10, states)
      origin = {:tls_legacy_change_cipher, pair.source.index}

      state =
        state
        |> handshake_copy(pair.source, [2, 2], [{:change_cipher_spec, <<1>>}, data], origin)
        |> handshake_copy(pair.returned, [3], next, origin)

      {:ok, state, next}
    end
  end

  defp legacy_send_flight(state, pair, data) do
    pid = pair.source.pid
    port = state.owners[pid].family.port
    handshake = elem(data, 6)
    bytes = IO.iodata_to_binary(elem(handshake, 31))
    origin = {:tls_legacy_send_flight, pair.source.index}

    writes =
      Enum.filter(state.transport.writes, fn write ->
        write.port == port and write.source.pid == pid and
          pair.source.index < write.source.index and write.returned.index < pair.returned.index
      end)

    with [write] <- writes do
      next = put_elem(data, 6, put_elem(handshake, 31, []))

      state =
        state
        |> handshake_copy(pair.source, [2, 2], [data], origin)
        |> handshake_copy(pair.returned, [3], {next, []}, origin)
        |> tls_exact(write.source, :tls_legacy_handshake_write, write.bytes, bytes)

      {:ok, state, next}
    else
      _ -> :error
    end
  end

  defp legacy_finished(connection, master, label, reversed) when is_binary(master) do
    with {:ok, hash} <- record_mac_algorithm(elem(connection.security_parameters, 8)) do
      digest = :crypto.hash(hash, Enum.reverse(reversed))
      {:ok, legacy_prf(hash, master, label, [digest], 12)}
    end
  end

  defp legacy_finished(_connection, _master, _label, _reversed), do: :error

  defp legacy_verify_data(states, directions, field, verify),
    do: Enum.reduce(directions, states, &put_in(&2, [&1, :reneg, field], verify))

  defp legacy_finished_receiver(%{
         source: %{mfa: {:tls_client_connection, :cipher, 3}},
         event: %{value: {:internal, {:finished, verify}}}
       } = frame) do
    data = frame.current.data
    handshake = elem(data, 6)
    session = elem(data, 8)
    states = elem(data, 10)
    options = elem(data, 4)

    with true <- elem(handshake, 4),
         {_, history} <- elem(handshake, 3),
         {:ok, ^verify} <-
           legacy_finished(states.current_read, elem(session, 7), "server finished", history) do
      states =
        legacy_verify_data(states, [:current_write, :current_read], :server_verify_data, verify)

      session =
        if options.verify == :verify_peer and options.reuse_sessions != false and
             elem(session, 10) == false,
          do: put_elem(session, 10, true),
          else: session

      origin = {:tls_legacy_finished, frame.source.index}
      data = data |> put_elem(8, session) |> put_elem(10, states)
      {:ok, %{frame | current: %{frame.current | data: data, origin: origin}}}
    else
      _ -> :error
    end
  end

  defp legacy_finished_receiver(frame), do: {:ok, frame}

  # The decoded peer packet and the modeled client entry determine the entire
  # ServerHello transition. Crypto NIF returns are native origins only after
  # their arguments have been matched to that program; no state helper result
  # or checked callback is used to construct a subsequent expected state.
  defp retry_start_record(
         state,
         source,
         %{
           source: %{mfa: {:tls_client_connection_1_3, :start, 3}},
           event: %{
             value: {:internal, {:server_hello, _, random, session, cipher, extensions} = hello}
           }
         } = frame
       ) do
    options = elem(frame.current.data, 4)
    scope = Map.put(Map.fetch!(state.pairs, frame.source.index), :returned, source)

    with {:server_hello_selected_version, {3, 4}} <-
           Map.get(extensions, :server_hello_selected_version),
         true <- {3, 4} in Map.fetch!(options, :versions),
         true <- cipher in Map.fetch!(options, :ciphers),
         {:supported_groups, groups} <- Map.fetch!(options, :supported_groups),
         {:ok, group} <- retry_group(Map.get(extensions, :key_share), groups, options),
         {:ok, exchange} <- handshake_generated_share(state, scope, group),
         shares = {:key_share_client_hello, [{:key_share_entry, group, exchange}]},
         {:ok, profile} <- handshake_cipher(cipher) do
      updates = %{
        cipher: cipher,
        key_share: shares,
        session_id: session,
        group: group,
        random: random
      }

      data = server_hello_start(frame.current.data, hello, shares, group, :undefined, profile)
      origin = {:tls_retry_start, frame.source.index}

      state
      |> handshake_copy(source, [2, 2], [frame.current.data, updates], frame.current.origin)
      |> put_in([:records, source.index], %{kind: :handshake_state, result: data, origin: origin})
    else
      _ -> tls_failure(state, source, :tls_server_hello_helper_origin)
    end
  end

  defp retry_start_record(state, source, _frame),
    do: tls_failure(state, source, :tls_server_hello_helper_origin)

  defp retry_client_hello_output(state, source, frame, extensions) do
    original = frame.input.data
    current = frame.current.data
    handshake = elem(current, 6)
    session = elem(original, 8)
    options = elem(original, 4)
    specific = elem(original, 7)
    previous_states = elem(original, 10)

    with {3, 4} = version <- elem(elem(original, 3), 5),
         {[retry, first | _], _} <- elem(elem(original, 6), 3),
         {[^retry, [254, 0, 0, _, _] | _] = messages, _} = previous_history <- elem(handshake, 3),
         {:key_share_client_hello, [{:key_share_entry, group, private}]} <- elem(handshake, 30),
         {:key_share_hello_retry_request, ^group} <- Map.get(extensions, :key_share),
         {:ok, public} <- retry_public_key(private),
         {:ok, fragment} <-
           retry_client_hello_fragment(first, group, public, Map.get(extensions, :cookie)),
         {:ok, encoded, states} <-
           encode_handshake_records(state, source, fragment, version, previous_states),
         history = {[fragment | messages], messages},
         {:ok, state} <-
           retry_encoding_copy(
             state,
             frame,
             source,
             fragment,
             [version, previous_states, previous_history],
             {encoded, states, history}
           ),
         {handshake, flight} = retry_change_cipher_spec(handshake, elem(session, 1), encoded),
         [write] <-
           Enum.filter(state.transport.writes, fn write ->
             write.port == state.owners[source.pid].family.port and
               write.source.pid == source.pid and frame.source.index < write.source.index and
               write.returned.index < source.index
           end),
         true <- write.bytes === IO.iodata_to_binary(flight) do
      handshake = put_elem(handshake, 3, history)
      data = current |> put_elem(6, handshake) |> put_elem(8, session) |> put_elem(10, states)

      name =
        if Map.get(specific, :hello_retry, false) and Map.get(options, :middlebox_comp_mode, true),
          do: :hello_retry_middlebox_assert,
          else: :wait_sh

      version = %{
        frame.current
        | name: name,
          data: data,
          origin: {:tls_retry_hello, source.index}
      }

      {:ok, state, version}
    else
      _ -> :error
    end
  end

  defp retry_encoding_copy(state, frame, source, fragment, arguments, result) do
    mfa = {:tls_gen_connection, :encode_handshake, 4}
    calls = tls_scoped_calls(state, frame.source, source, mfa)

    with [%{source: call, returned: returned}] <- calls,
         {_, :call, {_, _, [hello | _]}} <- call.event do
      state =
        tls_exact(
          state,
          call,
          :tls_retry_hello_copy,
          client_hello_fragment(hello),
          {:ok, fragment}
        )

      state = tls_error_path(state, call, [2, 2, 0], :tls_retry_hello_copy)

      state =
        arguments
        |> Enum.with_index(1)
        |> Enum.reduce(state, fn {expected, position}, state ->
          handshake_copy(state, call, [2, 2, position], expected, frame.input.origin)
        end)

      {:ok, handshake_copy(state, returned, [3], result, frame.current.origin)}
    else
      _ -> :error
    end
  end

  defp retry_change_cipher_spec(handshake, session, encoded)
       when session != <<>> and elem(handshake, 8) == false do
    ccs = [record_packet(20, {3, 3}, <<1>>)]
    {put_elem(handshake, 8, true), [ccs | encoded]}
  end

  defp retry_change_cipher_spec(handshake, _session, encoded), do: {handshake, encoded}

  defp retry_public_key({:ECPrivateKey, _, _, _, public, _}) when is_binary(public),
    do: {:ok, public}

  defp retry_public_key({{:ECPrivateKey, _, _, _, curve, _}, {kem, _}})
       when is_binary(curve) and is_binary(kem),
       do: {:ok, curve <> kem}

  defp retry_public_key({{first, _}, {second, _}}) when is_binary(first) and is_binary(second),
    do: {:ok, first <> second}

  defp retry_public_key({public, _}) when is_binary(public), do: {:ok, public}
  defp retry_public_key(_private), do: :error

  # The second flight retains the first flight's encoded fields. Its fresh
  # public key and any cookie come from the modeled retry before the send.
  defp retry_client_hello_fragment(first, group, public, cookie) do
    with <<1, size::24, body::binary-size(size)>> <- IO.iodata_to_binary(first),
         <<header::binary-size(34), sid_size, session::binary-size(sid_size), suites_size::16,
           suites::binary-size(suites_size), methods_size, methods::binary-size(methods_size),
           size::16, extensions::binary-size(size)>> <- body,
         {:ok, extensions} <- retry_extensions(extensions, group, public, cookie) do
      body =
        IO.iodata_to_binary([
          header,
          <<sid_size>>,
          session,
          <<suites_size::16>>,
          suites,
          <<methods_size>>,
          methods,
          hello_vector(extensions, 16)
        ])

      {:ok, [1, <<byte_size(body)::24>>, body]}
    else
      _ -> :error
    end
  catch
    :unsupported_client_hello_extension -> :error
  end

  defp retry_extensions(extensions, group, public, cookie) do
    with {:ok, entries} <- retry_extension_entries(extensions, []),
         [{51, _}] <- Enum.filter(entries, &(elem(&1, 0) == 51)),
         false <- List.keymember?(entries, 41, 0),
         false <- List.keymember?(entries, 44, 0),
         key = [<<hello_enum(@handshake_groups, group)::16>>, hello_vector(public, 16)],
         entries = List.keyreplace(entries, 51, 0, {51, hello_vector(key, 16)}),
         {:ok, entries} <- retry_cookie(List.keydelete(entries, 42, 0), cookie) do
      {:ok, Enum.map(entries, fn {code, payload} -> hello_extension(code, payload) end)}
    else
      _ -> :error
    end
  end

  defp retry_extension_entries(<<>>, entries), do: {:ok, Enum.reverse(entries)}

  defp retry_extension_entries(
         <<code::16, size::16, value::binary-size(size), rest::binary>>,
         entries
       ),
       do: retry_extension_entries(rest, [{code, value} | entries])

  defp retry_extension_entries(_bytes, _entries), do: :error

  defp retry_cookie(entries, none) when none in [nil, :undefined], do: {:ok, entries}

  defp retry_cookie(entries, {:cookie, cookie}) when is_binary(cookie) do
    # The encoded ClientHello orders these extension keys after cookie.
    earlier = [0, 1, 5, 10, 11, 12, 13, 14, 42, 45, 50, 51, 13_172, 65_281]
    {before, remaining} = Enum.split_while(entries, &(elem(&1, 0) in earlier))
    {:ok, before ++ [{44, hello_vector(cookie, 16)} | remaining]}
  end

  defp retry_cookie(_entries, _cookie), do: :error

  defp retry_group({:key_share_hello_retry_request, group}, groups, options) do
    offered = Map.get(options, :psk_groups, [hd(groups)])
    if group in groups and group not in offered, do: {:ok, group}, else: :error
  end

  defp retry_group(
         {:key_share_server_hello, {:key_share_entry, group, _public}},
         groups,
         _options
       ),
       do: if(group in groups, do: {:ok, group}, else: :error)

  defp retry_group(_share, _groups, _options), do: :error

  defp handshake_generated_share(state, scope, group) when group in [:x25519, :x448],
    do: handshake_crypto_origin(state, scope, {:crypto, :generate_key, 2}, [:ecdh, group])

  defp handshake_generated_share(state, scope, group)
       when group in [:mlkem512, :mlkem768, :mlkem1024],
       do: handshake_crypto_origin(state, scope, {:crypto, :generate_key, 2}, [group, []])

  defp handshake_generated_share(state, scope, group)
       when is_map_key(@ffdhe_primes, group),
       do:
         handshake_crypto_origin(state, scope, {:crypto, :generate_key, 2}, [
           :dh,
           [Map.fetch!(@ffdhe_primes, group), 2]
         ])

  defp handshake_generated_share(state, scope, :x25519mlkem768) do
    with {:ok, kem} <- handshake_generated_share(state, scope, :mlkem768),
         {:ok, curve} <- handshake_generated_share(state, scope, :x25519) do
      {:ok, {kem, curve}}
    end
  end

  defp handshake_generated_share(state, scope, group)
       when group in [:secp256r1mlkem768, :secp384r1mlkem1024] do
    {curve, algorithm} =
      if group == :secp256r1mlkem768,
        do: {:secp256r1, :mlkem768},
        else: {:secp384r1, :mlkem1024}

    with {:ok, curve} <- handshake_generated_share(state, scope, curve),
         {:ok, kem} <- handshake_generated_share(state, scope, algorithm) do
      {:ok, {curve, kem}}
    end
  end

  defp handshake_generated_share(state, scope, group)
       when group in [
              :secp256r1,
              :secp384r1,
              :secp521r1,
              :brainpoolP256r1tls13,
              :brainpoolP384r1tls13,
              :brainpoolP512r1tls13
            ] do
    {curve, oid} = handshake_curve(group)

    with {:ok, {public, private}} <-
           handshake_crypto_origin(state, scope, {:crypto, :generate_key, 2}, [:ecdh, curve]) do
      {:ok, {:ECPrivateKey, :ecPrivkeyVer1, private, {:namedCurve, oid}, public, :asn1_NOVALUE}}
    end
  end

  defp handshake_generated_share(_state, _scope, _group), do: :error

  defp server_hello_program(
         _state,
         _source,
         %{
           event: %{
             value: {:internal, {:server_hello, _, @hello_retry_random, _, _, extensions} = hello}
           },
           current: current
         }
       ) do
    specific = elem(current.data, 7)

    with {:server_hello_selected_version, {3, 4}} <-
           Map.get(extensions, :server_hello_selected_version),
         false <- Map.get(specific, :hello_retry, false) do
      data = put_elem(current.data, 7, Map.put(specific, :hello_retry, true))

      {:ok,
       %{
         hello: hello,
         active: data,
         next_name: :start,
         result: {data, :start, hello},
         retry?: true
       }}
    else
      _ -> :error
    end
  end

  defp server_hello_program(state, source, frame) do
    data = frame.current.data
    options = elem(data, 4)
    handshake = elem(data, 6)
    scope = Map.fetch!(state.pairs, source.index)

    with %{value: {:internal, hello}} <- frame.event,
         {:server_hello, {3, 3}, random, session, cipher, extensions} <- hello,
         {:server_hello_selected_version, {3, 4}} <-
           Map.get(extensions, :server_hello_selected_version),
         true <- cipher in Map.fetch!(options, :ciphers),
         true <- session === elem(elem(data, 8), 1),
         :undefined <- Map.get(extensions, :pre_shared_key, :undefined),
         {:key_share_server_hello, {:key_share_entry, group, public}} <-
           Map.get(extensions, :key_share),
         {:supported_groups, groups} <- Map.fetch!(options, :supported_groups),
         true <- group in groups,
         {:key_share_client_hello, shares} = key_share <- elem(handshake, 30),
         {:key_share_entry, ^group, exchange} <- List.keyfind(shares, group, 1),
         {:ok, private} <- handshake_private_key(exchange),
         {:ok, profile} <- handshake_cipher(cipher),
         {:ok, shared} <- handshake_shared_secret(state, scope, group, public, private),
         start = server_hello_start(data, hello, key_share, group, public, profile),
         {:ok, secrets, psk} <- handshake_secrets(state, scope, start, shared, profile) do
      states = elem(secrets, 10)
      current = states |> Map.fetch!(:pending_read) |> Map.put(:sequence_number, 0)
      states = Map.put(states, :current_read, Map.delete(current, :aead_handle))

      {:ok,
       %{
         hello: hello,
         updates: %{
           cipher: cipher,
           key_share: key_share,
           session_id: session,
           group: group,
           peer_public_key: public,
           random: random
         },
         start: start,
         secrets: secrets,
         active: put_elem(secrets, 10, states),
         next_name: server_hello_next_name(options, elem(data, 7)),
         result: {put_elem(secrets, 10, states), :wait_ee},
         retry?: false,
         public: public,
         private: private,
         group: group,
         psk: psk
       }}
    else
      _ -> :error
    end
  end

  defp server_hello_next_name(options, specific) do
    if Map.get(options, :middlebox_comp_mode) == false or
         Map.get(specific, :hello_retry, false),
       do: :wait_ee,
       else: :hello_middlebox_assert
  end

  defp handshake_cipher(<<19, 1>>),
    do: {:ok, %{bulk: 8, hash: :sha256, size: 32, key: 16, tag: 16}}

  defp handshake_cipher(<<19, 2>>),
    do: {:ok, %{bulk: 8, hash: :sha384, size: 48, key: 32, tag: 16}}

  defp handshake_cipher(<<19, 3>>),
    do: {:ok, %{bulk: 9, hash: :sha256, size: 32, key: 32, tag: 16}}

  defp handshake_cipher(<<19, 4>>),
    do: {:ok, %{bulk: 10, hash: :sha256, size: 32, key: 16, tag: 16}}

  defp handshake_cipher(<<19, 5>>),
    do: {:ok, %{bulk: 11, hash: :sha256, size: 32, key: 16, tag: 8}}

  defp handshake_cipher(_cipher), do: :error

  defp server_hello_start(data, hello, key_share, group, public, profile) do
    {:server_hello, _, random, session_id, cipher, _} = hello

    states =
      Enum.reduce([:pending_read, :pending_write], elem(data, 10), fn direction, states ->
        pending = Map.fetch!(states, direction)

        parameters =
          pending
          |> Map.fetch!(:security_parameters)
          |> put_elem(1, cipher)
          |> put_elem(3, profile.bulk)
          |> put_elem(4, 2)
          |> put_elem(8, profile.hash)
          |> put_elem(15, random)

        Map.put(states, direction, Map.put(pending, :security_parameters, parameters))
      end)

    session =
      elem(data, 8)
      |> put_elem(1, session_id)
      |> put_elem(6, cipher)
      |> put_elem(12, group)
      |> put_elem(13, :undefined)
      |> put_elem(14, public)

    handshake = elem(data, 6) |> put_elem(17, :undefined) |> put_elem(30, key_share)

    data
    |> put_elem(3, put_elem(elem(data, 3), 5, {3, 4}))
    |> put_elem(6, handshake)
    |> put_elem(8, session)
    |> put_elem(10, states)
  end

  defp handshake_shared_secret(state, scope, group, public, private)
       when group in [:x25519, :x448],
       do:
         handshake_primitive(state, scope, {:crypto, :compute_key, 4}, [
           :ecdh,
           public,
           private,
           group
         ])

  defp handshake_shared_secret(state, scope, group, public, private)
       when is_map_key(@ffdhe_primes, group) do
    prime = Map.fetch!(@ffdhe_primes, group)
    size = byte_size(:binary.encode_unsigned(prime))

    with {:ok, shared} <-
           handshake_primitive(state, scope, {:crypto, :compute_key, 4}, [
             :dh,
             public,
             private,
             [prime, 2]
           ]),
         true <- byte_size(shared) <= size do
      {:ok, :binary.copy(<<0>>, size - byte_size(shared)) <> shared}
    else
      _ -> :error
    end
  end

  defp handshake_shared_secret(
         state,
         scope,
         group,
         public,
         {:ECPrivateKey, _version, private, {:namedCurve, oid}, _public, _attributes}
       )
       when group in [
              :secp256r1,
              :secp384r1,
              :secp521r1,
              :brainpoolP256r1tls13,
              :brainpoolP384r1tls13,
              :brainpoolP512r1tls13
            ] do
    {curve, expected_oid} = handshake_curve(group)

    if oid == expected_oid do
      handshake_primitive(state, scope, {:crypto, :compute_key, 4}, [
        :ecdh,
        public,
        private,
        curve
      ])
    else
      :error
    end
  end

  defp handshake_shared_secret(
         state,
         scope,
         :x25519mlkem768,
         {ciphertext, public},
         {kem, private}
       ) do
    with {:ok, kem} <-
           handshake_primitive(state, scope, {:crypto, :decapsulate_key, 3}, [
             :mlkem768,
             kem,
             ciphertext
           ]),
         {:ok, shared} <- handshake_shared_secret(state, scope, :x25519, public, private) do
      {:ok, kem <> shared}
    end
  end

  defp handshake_shared_secret(state, scope, group, ciphertext, private)
       when group in [:mlkem512, :mlkem768, :mlkem1024],
       do:
         handshake_primitive(state, scope, {:crypto, :decapsulate_key, 3}, [
           group,
           private,
           ciphertext
         ])

  defp handshake_shared_secret(state, scope, group, {public, ciphertext}, {private, kem})
       when group in [:secp256r1mlkem768, :secp384r1mlkem1024] do
    {curve, algorithm} =
      if group == :secp256r1mlkem768,
        do: {:secp256r1, :mlkem768},
        else: {:secp384r1, :mlkem1024}

    with {:ok, kem} <-
           handshake_primitive(state, scope, {:crypto, :decapsulate_key, 3}, [
             algorithm,
             kem,
             ciphertext
           ]),
         {:ok, shared} <- handshake_shared_secret(state, scope, curve, public, private) do
      {:ok, shared <> kem}
    end
  end

  defp handshake_shared_secret(_state, _scope, _group, _public, _private), do: :error

  defp handshake_private_key({:ECPrivateKey, _, _, _, _, _} = private), do: {:ok, private}

  defp handshake_private_key({{:ECPrivateKey, _, _, _, _, _} = private, {_public, kem}}),
    do: {:ok, {private, kem}}

  defp handshake_private_key({{_public1, private1}, {_public2, private2}}),
    do: {:ok, {private1, private2}}

  defp handshake_private_key({_public, private}), do: {:ok, private}
  defp handshake_private_key(_exchange), do: :error

  defp handshake_curve(:secp256r1), do: {:secp256r1, {1, 2, 840, 10045, 3, 1, 7}}
  defp handshake_curve(:secp384r1), do: {:secp384r1, {1, 3, 132, 0, 34}}
  defp handshake_curve(:secp521r1), do: {:secp521r1, {1, 3, 132, 0, 35}}

  defp handshake_curve(:brainpoolP256r1tls13),
    do: {:brainpoolP256r1, {1, 3, 36, 3, 3, 2, 8, 1, 1, 7}}

  defp handshake_curve(:brainpoolP384r1tls13),
    do: {:brainpoolP384r1, {1, 3, 36, 3, 3, 2, 8, 1, 1, 11}}

  defp handshake_curve(:brainpoolP512r1tls13),
    do: {:brainpoolP512r1, {1, 3, 36, 3, 3, 2, 8, 1, 1, 13}}

  defp reinitialized_receiver(data) do
    handshake =
      elem(data, 6)
      |> put_elem(3, {[], []})
      |> put_elem(4, false)
      |> put_elem(25, :undefined)
      |> put_elem(26, :undefined)

    put_elem(data, 6, handshake)
  end

  # The receiver constructs each update from its modeled write state. Native
  # sends and receives pair in FIFO order between this same receiver and sender;
  # neither the checked cast nor the checked sender state supplies any field.
  defp write_update_receipt(state, source, sender) do
    receiver = source.pid
    scope = Map.fetch!(state.pairs, source.index)

    sends =
      Enum.filter(state.events, fn
        %{event: {^receiver, :send, {:"$gen_cast", {:new_write, _, _, _}}, ^sender}} -> true
        _ -> false
      end)

    receipts =
      Enum.filter(state.events, fn
        %{event: {^sender, :receive, {:"$gen_cast", {:new_write, _, _, _}}}} -> true
        _ -> false
      end)

    with [sent] <-
           Enum.filter(sends, fn event ->
             source.index < event.index and event.index < scope.returned.index
           end),
         ordinal when is_integer(ordinal) <- Enum.find_index(sends, &(&1.index == sent.index)),
         %{} = receipt <- Enum.at(receipts, ordinal),
         true <- sent.index < receipt.index do
      {:ok, sent, receipt}
    else
      _ -> :error
    end
  end

  defp acknowledged_receiver(data) do
    handshake = elem(data, 6)
    recv = elem(data, 9)

    case {elem(handshake, 5), elem(recv, 1)} do
      {{true, initiator}, _from} when initiator in [:peer, :internal] ->
        {put_elem(data, 6, put_elem(handshake, 5, :undefined)), nil}

      {{true, from}, _recv_from} ->
        {put_elem(data, 6, put_elem(handshake, 5, :undefined)), {from, :ok}}

      {{false, :first}, from} when from != :undefined ->
        data =
          data
          |> put_elem(6, put_elem(handshake, 5, :undefined))
          |> put_elem(9, put_elem(recv, 1, :undefined))

        {data, {from, :connected}}

      _ ->
        {data, nil}
    end
  end

  defp handshake_connection_result(state, source, :validate_finished, frame) do
    data = frame.current.data

    with %{value: {:internal, {:finished, verify}}} <- frame.event,
         {:ok, expected} <- handshake_finished(state, source, data, :current_read, true),
         {:ok, valid?} <-
           record_primitive(state, source, {:crypto, :hash_equals, 2}, [expected, verify]),
         true <- is_boolean(valid?) do
      result =
        if valid?,
          do: :ok,
          else:
            {:error,
             record_alert({:tls_handshake_1_3, :compare_verify_data, 2}, 0, 51, :decrypt_error)}

      {:ok, [data, verify], :handshake_value, result}
    else
      _ -> :error
    end
  end

  defp handshake_connection_result(state, source, :finished, frame) do
    data = frame.current.data

    with {:ok, verify} <- handshake_finished(state, source, data, :current_write, false) do
      {:ok, [data], :handshake_value, {:finished, verify}}
    end
  end

  defp handshake_connection_result(state, source, function, frame)
       when function in [:calculate_read_traffic_secrets, :calculate_write_traffic_secrets] do
    data = frame.current.data

    direction =
      if function == :calculate_read_traffic_secrets, do: :pending_read, else: :pending_write

    with {:ok, pending} <- handshake_application_secret(state, source, data, direction) do
      states = Map.put(elem(data, 10), direction, pending)
      {:ok, [data], :handshake_state, put_elem(data, 10, states)}
    end
  end

  defp handshake_connection_result(
         state,
         source,
         :maybe_calculate_resumption_master_secret,
         frame
       ) do
    data = frame.current.data

    if Map.fetch!(elem(data, 4), :session_tickets) == :disabled do
      {:ok, [data], :handshake_state, data}
    else
      pending = Map.fetch!(elem(data, 10), :pending_read)
      parameters = pending.security_parameters
      {messages, _previous} = elem(elem(data, 6), 3)
      scope = Map.fetch!(state.pairs, source.index)

      with {:ok, profile} <- handshake_cipher(elem(parameters, 1)),
           {:master_secret, master} <- elem(parameters, 10),
           {:ok, transcript} <-
             handshake_primitive(state, scope, {:crypto, :hash, 2}, [
               profile.hash,
               Enum.reverse(messages)
             ]),
           {:ok, secret} <-
             handshake_expand(
               state,
               scope,
               profile,
               master,
               "res master",
               transcript,
               profile.size
             ) do
        states =
          Enum.reduce([:pending_read, :pending_write], elem(data, 10), fn direction, states ->
            pending = Map.fetch!(states, direction)
            parameters = put_elem(pending.security_parameters, 11, secret)
            Map.put(states, direction, %{pending | security_parameters: parameters})
          end)

        {:ok, [data], :handshake_state, put_elem(data, 10, states)}
      else
        _ -> :error
      end
    end
  end

  defp handshake_connection_result(state, source, :prepare_connection, frame) do
    data = frame.current.data
    pending = Map.fetch!(elem(data, 10), :pending_read)
    parameters = pending.security_parameters
    scope = Map.fetch!(state.pairs, source.index)

    with {:ok, profile} <- handshake_cipher(elem(parameters, 1)),
         {:master_secret, master} <- elem(parameters, 10),
         {:ok, transcript} <-
           handshake_primitive(state, scope, {:crypto, :hash, 2}, [
             profile.hash,
             handshake_context(data)
           ]),
         {:ok, secret} <-
           handshake_expand(state, scope, profile, master, "exp master", transcript, profile.size) do
      specific = Map.put(elem(data, 7), :exporter_master_secret, secret)
      role = elem(elem(data, 2), 1)
      keep = role == :client and match?({:keylog_hs, _}, Map.get(elem(data, 4), :keep_secrets))

      states =
        if keep do
          elem(data, 10)
        else
          Map.new(elem(data, 10), fn
            {direction, connection}
            when direction in [:pending_read, :pending_write, :current_read, :current_write] ->
              parameters = put_elem(connection.security_parameters, 10, {:master_secret, <<0>>})
              {direction, %{connection | security_parameters: parameters}}

            entry ->
              entry
          end)
        end

      {:ok, [data], :handshake_state, data |> put_elem(7, specific) |> put_elem(10, states)}
    else
      _ -> :error
    end
  end

  defp handshake_finished(state, source, data, direction, drop_peer?) do
    connection = Map.fetch!(elem(data, 10), direction)
    {messages, _previous} = elem(elem(data, 6), 3)
    messages = if drop_peer?, do: Enum.drop(messages, 1), else: messages
    scope = Map.fetch!(state.pairs, source.index)

    with {:cipher_state, _iv, _traffic_key, key, _nonce, _state, _tag_length} <-
           connection.cipher_state,
         hash = elem(connection.security_parameters, 8),
         true <- hash in [:sha256, :sha384, :sha512],
         {:ok, transcript} <-
           handshake_primitive(state, scope, {:crypto, :hash, 2}, [hash, Enum.reverse(messages)]) do
      handshake_mac(state, scope, hash, key, transcript)
    else
      _ -> :error
    end
  end

  defp handshake_application_secret(state, source, data, direction) do
    pending = Map.fetch!(elem(data, 10), direction)
    parameters = pending.security_parameters
    role = elem(elem(data, 2), 1)
    scope = Map.fetch!(state.pairs, source.index)

    label =
      if {role, direction} in [{:client, :pending_read}, {:server, :pending_write}],
        do: "s ap traffic",
        else: "c ap traffic"

    with {:ok, profile} <- handshake_cipher(elem(parameters, 1)),
         {:handshake_secret, handshake} <- elem(parameters, 10),
         {:ok, empty} <-
           handshake_primitive(state, scope, {:crypto, :hash, 2}, [profile.hash, <<>>]),
         {:ok, derived} <-
           handshake_expand(state, scope, profile, handshake, "derived", empty, profile.size),
         {:ok, master} <-
           handshake_mac(state, scope, profile.hash, derived, :binary.copy(<<0>>, profile.size)),
         {:ok, transcript} <-
           handshake_primitive(state, scope, {:crypto, :hash, 2}, [
             profile.hash,
             handshake_context(data)
           ]),
         {:ok, traffic} <-
           handshake_expand(state, scope, profile, master, label, transcript, profile.size),
         {:ok, key} <- handshake_expand(state, scope, profile, traffic, "key", <<>>, profile.key),
         {:ok, iv} <- handshake_expand(state, scope, profile, traffic, "iv", <<>>, 12) do
      parameters = parameters |> put_elem(10, {:master_secret, master}) |> put_elem(12, traffic)
      finished = elem(pending.cipher_state, 3)
      cipher = {:cipher_state, iv, key, finished, :undefined, :undefined, profile.tag}
      {:ok, %{pending | security_parameters: parameters, cipher_state: cipher}}
    else
      _ -> :error
    end
  end

  defp handshake_context(data) do
    {messages, _previous} = elem(elem(data, 6), 3)
    role = elem(elem(data, 2), 1)
    skip = if role == :client, do: &is_list/1, else: &is_binary/1
    messages |> Enum.drop_while(skip) |> Enum.reverse()
  end

  defp handshake_secrets(state, scope, data, shared, profile) do
    psk = :binary.copy(<<0>>, profile.size)
    {messages, _} = elem(elem(data, 6), 3)
    context = messages |> Enum.drop_while(&is_list/1) |> Enum.reverse()

    with {:ok, early} <- handshake_mac(state, scope, profile.hash, psk, psk),
         {:ok, empty} <-
           handshake_primitive(state, scope, {:crypto, :hash, 2}, [profile.hash, <<>>]),
         {:ok, derived} <-
           handshake_expand(state, scope, profile, early, "derived", empty, profile.size),
         {:ok, secret} <- handshake_mac(state, scope, profile.hash, derived, shared),
         {:ok, transcript} <-
           handshake_primitive(state, scope, {:crypto, :hash, 2}, [profile.hash, context]),
         master = {:handshake_secret, secret},
         {:ok, read} <-
           handshake_pending(state, scope, data, :pending_read, master, transcript, profile),
         {:ok, write} <-
           handshake_pending(state, scope, data, :pending_write, master, transcript, profile) do
      states = elem(data, 10) |> Map.put(:pending_read, read) |> Map.put(:pending_write, write)
      {:ok, put_elem(data, 10, states), psk}
    end
  end

  defp handshake_pending(state, scope, data, direction, master, transcript, profile) do
    {label, type} =
      if direction == :pending_read,
        do: {"s hs traffic", :server_handshake_traffic_secret},
        else: {"c hs traffic", :client_handshake_traffic_secret}

    with {:ok, traffic} <-
           handshake_expand(
             state,
             scope,
             profile,
             elem(master, 1),
             label,
             transcript,
             profile.size
           ),
         {:ok, key} <- handshake_expand(state, scope, profile, traffic, "key", <<>>, profile.key),
         {:ok, iv} <- handshake_expand(state, scope, profile, traffic, "iv", <<>>, 12),
         {:ok, finished} <-
           handshake_expand(state, scope, profile, traffic, "finished", <<>>, profile.size) do
      pending = Map.fetch!(elem(data, 10), direction)
      parameters = pending |> Map.fetch!(:security_parameters) |> put_elem(10, master)

      pending =
        pending
        |> Map.put(:security_parameters, parameters)
        |> Map.put(
          :cipher_state,
          {:cipher_state, iv, key, finished, :undefined, :undefined, profile.tag}
        )

      keep = Map.get(elem(data, 4), :keep_secrets, false)
      pending = if keep == false, do: pending, else: Map.put(pending, type, traffic)
      pending = if match?({:keylog, _}, keep), do: Map.delete(pending, type), else: pending
      {:ok, pending}
    end
  end

  defp handshake_expand(state, scope, profile, secret, label, context, size) do
    label = "tls13 " <> label
    info = <<size::16, byte_size(label), label::binary, byte_size(context), context::binary, 1>>

    with {:ok, bytes} <- handshake_mac(state, scope, profile.hash, secret, info),
         true <- byte_size(bytes) >= size do
      {:ok, binary_part(bytes, 0, size)}
    else
      _ -> :error
    end
  end

  defp handshake_mac(state, scope, hash, key, bytes),
    do: handshake_primitive(state, scope, {:crypto, :mac, 4}, [:hmac, hash, key, bytes])

  defp handshake_primitive(state, scope, mfa, arguments) do
    with {:ok, value} when is_binary(value) <-
           handshake_crypto_origin(state, scope, mfa, arguments) do
      {:ok, value}
    else
      _ -> :error
    end
  end

  defp handshake_crypto_origin(state, scope, {module, function, _} = mfa, arguments) do
    values =
      for pair <- Map.get(state.pair_index, {scope.source.pid, mfa}, []),
          scope.source.index < pair.source.index and pair.returned.index < scope.returned.index,
          pair.source.event === {scope.source.pid, :call, {module, function, arguments}},
          {_, :return_from, ^mfa, value} <- [pair.returned.event],
          do: value

    case Enum.uniq(values) do
      [value] ->
        {:ok, value}

      _ -> :error
    end
  end

  defp server_hello_helper(state, source, kind) do
    case hd(state.frames[source.pid]) do
      %{server_hello_program: program, input: input} ->
        arguments =
          case kind do
            :start ->
              [input.data, program.updates]

            :secrets ->
              [program.public, program.private, program.group, program.psk, program.start]

            :active ->
              [program.secrets]
          end

        server_hello_record(state, source, arguments, Map.fetch!(program, kind))

      _ ->
        tls_failure(state, source, :tls_server_hello_helper_origin)
    end
  end

  defp server_hello_record(state, source, arguments, result) do
    origin = {:tls_server_hello_program, hd(state.frames[source.pid]).source.index}

    state
    |> handshake_copy(source, [2, 2], arguments, origin)
    |> put_in([:records, source.index], %{kind: :handshake_value, result: result, origin: origin})
  end

  defp tls_callback_mode(:tls_client_connection_1_3),
    do: {:ok, [:state_functions, :state_enter], true}

  defp tls_callback_mode(:tls_client_connection), do: {:ok, :state_functions, false}
  defp tls_callback_mode(_module), do: :error

  defp sender_alert(%{value: {{:call, _from}, {:ack_alert, alert}}}), do: {:ok, alert}
  defp sender_alert(%{value: {:cast, alert}}), do: {:ok, alert}
  defp sender_alert(_event), do: :error

  defp delivered_state(state, source, version, plaintext) do
    data = version.data
    {:socket_options, :binary, packet, _max_packet, 0, false} = elem(data, 5)
    true = packet in [0, :raw]
    {front, size, rear} = elem(data, 12)

    consume_buffer(
      state,
      source,
      version,
      {front, size + byte_size(plaintext), [plaintext | rear]}
    )
  end

  defp consume_buffer(state, source, version, {_front, 0, _rear}) do
    data = put_elem(version.data, 12, {[], 0, []})
    {state, %{version | data: data, origin: {:tls_empty_buffer, source.index}}}
  end

  defp consume_buffer(state, source, version, {front, size, rear}) do
    {front, rear, bytes} = queued_binary(front, rear)
    recv = elem(version.data, 9)
    required = elem(recv, 2)
    buffer = {[bytes | front], size, rear}

    case required do
      :undefined -> buffered_state(state, source, version, buffer, recv)
      count when count > size -> buffered_state(state, source, version, buffer, recv)
      count -> consume_requested(state, source, version, bytes, front, rear, size, count)
    end
  end

  defp consume_requested(state, source, version, bytes, front, rear, size, required) do
    count = if required == 0, do: byte_size(bytes), else: required

    {front, rear, remaining} =
      if byte_size(bytes) >= count do
        <<_delivered::binary-size(^count), remaining::binary>> = bytes
        {front, rear, remaining}
      else
        {front, rear} = consume_queue(count - byte_size(bytes), front, rear)
        {front, rear, <<>>}
      end

    recv = elem(version.data, 9) |> put_elem(1, :undefined) |> put_elem(2, :undefined)
    buffered_state(state, source, version, {[remaining | front], size - count, rear}, recv)
  end

  defp buffered_state(state, source, version, buffer, recv) do
    data = version.data |> put_elem(9, recv) |> put_elem(12, buffer)
    {state, %{version | data: data, origin: {:tls_user_buffer, source.index}}}
  end

  defp queued_binary([<<>> | front], rear), do: queued_binary(front, rear)
  defp queued_binary([bytes | front], rear), do: {front, rear, bytes}
  defp queued_binary([], rear), do: queued_binary(Enum.reverse(rear), [])

  defp consume_queue(0, front, rear), do: {front, rear}
  defp consume_queue(count, [], rear), do: consume_queue(count, Enum.reverse(rear), [])

  defp consume_queue(count, [bytes | front], rear) when byte_size(bytes) <= count,
    do: consume_queue(count - byte_size(bytes), front, rear)

  defp consume_queue(count, [bytes | front], rear) do
    <<_consumed::binary-size(^count), rest::binary>> = bytes
    {[rest | front], rear}
  end

  defp sender_copies(events, pairs, binding) do
    parents =
      Map.get(pair_occurrences(pairs), {binding.sender, {:tls_sender, :connection, 3}}, [])

    Enum.reduce(events, %{terms: [], errors: []}, fn
      %{event: {pid, :call, {:tls_sender, :send_application_data, arguments}}} = source, state
      when pid == binding.sender ->
        sender_copy(state, source, arguments, parents)

      _source, state ->
        state
    end)
  end

  defp sender_copy(state, source, [data, from, :connection, actual], pairs) do
    parent =
      pairs
      |> Enum.filter(fn pair ->
        pair.source.pid == source.pid and pair.source.mfa == {:tls_sender, :connection, 3} and
          pair.source.index < source.index and pair.returned.index > source.index
      end)
      |> Enum.max_by(& &1.source.index, fn -> nil end)

    case parent do
      %{
        source:
          %{
            event:
              {_, :call,
               {_, _, [{:call, expected_from}, {:application_data, expected_data}, expected]}}
          } = origin
      } ->
        state
        |> tls_copy(source, [2, 2, 0], data, expected_data, origin.index)
        |> tls_copy(source, [2, 2, 1], from, expected_from, origin.index)
        |> tls_copy(source, [2, 2, 3], actual, expected, origin.index)

      _ ->
        tls_failure(state, source, :tls_state_origin)
    end
  end

  defp sender_copy(state, source, _arguments, _pairs),
    do: tls_failure(state, source, :tls_state_origin)

  defp tls_copy(state, source, path, actual, expected, origin) do
    state = tls_exact(state, source, :tls_state_copy, actual, expected)
    copy = %{index: source.index, path: path, origin: {:tls_callback, origin}}
    Map.update!(state, :terms, &[copy | &1])
  end

  defp tls_exact(state, _source, _rule, actual, expected) when actual === expected, do: state

  defp tls_exact(state, source, rule, _actual, _expected), do: tls_failure(state, source, rule)

  defp tls_failure(state, source, rule) do
    error = %{
      index: source.index,
      at: Map.take(source, [:mfa, :role, :stack]),
      rule: rule,
      actual: false,
      expected: true
    }

    Map.update!(state, :errors, &[error | &1])
  end

  defp write(state, source, port, bytes) do
    case Map.fetch(state.pairs, source.index) do
      {:ok, %{returned: %{event: {_, :return_from, {:ssl, :send, 2}, :ok}} = returned}} ->
        write = %{
          source: source,
          command: source,
          returned: returned,
          port: port,
          bytes: bytes,
          header_size: 0,
          copies: [copy(source, [2, 2, 1], bytes)]
        }

        %{state | writes: [write | state.writes]}

      _ ->
        tls_failure(state, source, :tls_write_return)
    end
  end

  defp read(state, source, port, length, timeout) do
    case Map.fetch(state.pairs, source.index) do
      {:ok, %{returned: %{event: {_, :return_from, {:ssl, :recv, 3}, {:ok, bytes}}} = returned}}
      when is_binary(bytes) ->
        read = %{
          source: source,
          returned: returned,
          delivered: returned,
          port: port,
          length: length,
          timeout: timeout,
          result: {:ok, bytes},
          bytes: bytes,
          provenance: source.index,
          copies: [copy(returned, [3, 1], bytes)]
        }

        %{state | reads: [read | state.reads]}

      _ ->
        tls_failure(state, source, :tls_read_return)
    end
  end

  defp copy(source, path, bytes),
    do: %{index: source.index, path: path, offset: 0, length: byte_size(bytes)}

  defp mismatch(errors, _rule, true), do: errors
  defp mismatch(errors, rule, false), do: errors ++ [rule]
end
