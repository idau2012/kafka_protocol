%%%
%%%   Copyright (c) 2014-2018, Klarna AB
%%%
%%%   Licensed under the Apache License, Version 2.0 (the "License");
%%%   you may not use this file except in compliance with the License.
%%%   You may obtain a copy of the License at
%%%
%%%       http://www.apache.org/licenses/LICENSE-2.0
%%%
%%%   Unless required by applicable law or agreed to in writing, software
%%%   distributed under the License is distributed on an "AS IS" BASIS,
%%%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%%   See the License for the specific language governing permissions and
%%%   limitations under the License.
%%%

-module(kpro_connection).

%% API
-export([ all_cfg_keys/0
        , get_tcp_sock/1
        , init/4
        , loop/2
        , request_sync/3
        , request_async/2
        , start/3
        , stop/1
        , debug/2
        ]).

%% system calls support for worker process
-export([ system_continue/3
        , system_terminate/4
        , system_code_change/4
        , format_status/2
        ]).

-export_type([ config/0
             , connection/0
             ]).

-include("kpro.hrl").

-define(DEFAULT_CONNECT_TIMEOUT, timer:seconds(5)).
-define(DEFAULT_REQUEST_TIMEOUT, timer:minutes(4)).
-define(SIZE_HEAD_BYTES, 4).

%% try not to use 0 corr ID for the first few requests
%% as they are usually used by upper level callers
-define(SASL_AUTH_REQ_CORRID, ((1 bsl 31) - 1)).

-type cfg_key() :: connect_timeout
                 | client_id
                 | debug
                 | nolink
                 | request_timeout
                 | sasl
                 | ssl.
-type cfg_val() :: term().
-type config() :: #{cfg_key() => cfg_val()}.
-type requests() :: kpro_sent_reqs:requests().
-type byte_count() :: non_neg_integer().
-type hostname() :: kpro:hostname().
-type portnum()  :: kpro:portnum().
-type client_id() :: kpro:client_id().
-type connection() :: pid().

-record(acc, { expected_size = error(bad_init) :: byte_count()
             , acc_size = 0 :: byte_count()
             , acc_buffer = [] :: [binary()] %% received bytes in reversed order
             }).

-type acc() :: binary() | #acc{}.

-define(undef, undefined).

-record(state, { client_id   :: client_id()
               , parent      :: pid()
               , sock        :: ?undef | port()
               , acc = <<>>  :: acc()
               , requests    :: ?undef | requests()
               , mod         :: ?undef | gen_tcp | ssl
               , req_timeout :: ?undef | timeout()
               }).

-type state() :: #state{}.

%%%_* API ======================================================================

%% @doc Return all config keys make client config management easy.
-spec all_cfg_keys() -> [cfg_key()].
all_cfg_keys() ->
  [connect_timeout, debug, client_id, request_timeout, sasl, ssl, nolink].

%% @doc Connect to the given endpoint.
%% The started connection pid is linked to caller
%% unless `nolink := true' is found in `Config'
-spec start(hostname(), portnum(), config()) -> {ok, pid()} | {error, any()}.
start(Host, Port, #{nolink := true} = Config) ->
  proc_lib:start(?MODULE, init, [self(), host(Host), Port, Config]);
start(Host, Port, Config) ->
  proc_lib:start_link(?MODULE, init, [self(), host(Host), Port, Config]).

%% @doc Send a request. Caller should expect to receive a response
%% having `Rsp#kpro_rsp.ref' the same as `Request#kpro_req.ref'
%% unless `Request#kpro_req.no_ack' is set to 'true'
-spec request_async(connection(), kpro:req()) -> ok | {error, any()}.
request_async(Pid, Request) ->
  call(Pid, {send, Request}).

%% @doc Send a request and wait for response for at most Timeout milliseconds.
-spec request_sync(connection(), kpro:req(), timeout()) ->
        ok | {ok, kpro:rsp()} | {error, any()}.
request_sync(Pid, Request, Timeout) ->
  case request_async(Pid, Request) of
    ok when Request#kpro_req.no_ack ->
      ok;
    ok ->
      wait_for_rsp(Pid, Request, Timeout);
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Stop socket process.
-spec stop(connection()) -> ok | {error, any()}.
stop(Pid) when is_pid(Pid) ->
  call(Pid, stop);
stop(_) ->
  ok.

%% @hidden
-spec get_tcp_sock(pid()) -> {ok, port()}.
get_tcp_sock(Pid) ->
  call(Pid, get_tcp_sock).

%% @doc Enable/disable debugging on the socket process.
%%      debug(Pid, pring) prints debug info on stdout
%%      debug(Pid, File) prints debug info into a File
%%      debug(Pid, none) stops debugging
-spec debug(connection(), print | string() | none) -> ok.
debug(Pid, none) ->
  system_call(Pid, {debug, no_debug});
debug(Pid, print) ->
  system_call(Pid, {debug, {trace, true}});
debug(Pid, File) when is_list(File) ->
  system_call(Pid, {debug, {log_to_file, File}}).

%%%_* Internal functions =======================================================

-spec init(pid(), hostname(), portnum(), config()) -> no_return().
init(Parent, Host, Port, Config) ->
  Timeout = get_connect_timeout(Config),
  SockOpts = [{active, once}, {packet, raw}, binary, {nodelay, true}],
  case gen_tcp:connect(Host, Port, SockOpts, Timeout) of
    {ok, Sock} ->
      State = #state{ client_id = get_client_id(Config)
                    , parent    = Parent
                    },
      try
        do_init(State, Sock, Host, Config)
      catch
        error : Reason ->
          IsSsl = maps:get(ssl, Config, false),
          SaslOpt = get_sasl_opt(Config),
          ok = maybe_log_hint(Host, Port, Reason, IsSsl, SaslOpt),
          erlang:exit({Reason, erlang:get_stacktrace()})
      end;
    {error, Reason} ->
      %% exit instead of {error, Reason}
      %% otherwise exit reason will be 'normal'
      erlang:exit({connection_failure, Reason})
  end.

-spec do_init(state(), port(), hostname(), config()) -> no_return().
do_init(State0, Sock, Host, Config) ->
  #state{parent = Parent, client_id = ClientId} = State0,
  Debug = sys:debug_options(maps:get(debug, Config, [])),
  Timeout = get_connect_timeout(Config),
  %% adjusting buffer size as per recommendation at
  %% http://erlang.org/doc/man/inet.html#setopts-2
  %% idea is from github.com/epgsql/epgsql
  {ok, [{recbuf, RecBufSize}, {sndbuf, SndBufSize}]} =
    inet:getopts(Sock, [recbuf, sndbuf]),
    ok = inet:setopts(Sock, [{buffer, max(RecBufSize, SndBufSize)}]),
  SslOpts = maps:get(ssl, Config, false),
  Mod = get_tcp_mod(SslOpts),
  NewSock = maybe_upgrade_to_ssl(Sock, Mod, SslOpts, Timeout),
  ok = sasl_auth(Host, NewSock, Mod, ClientId, Timeout, get_sasl_opt(Config)),
  State = State0#state{mod = Mod, sock = NewSock},
  proc_lib:init_ack(Parent, {ok, self()}),
  ReqTimeout = get_request_timeout(Config),
  ok = send_assert_max_req_age(self(), ReqTimeout),
  Requests = kpro_sent_reqs:new(),
  loop(State#state{requests = Requests, req_timeout = ReqTimeout}, Debug).

% Send request to active = false socket, and wait for response.
inactive_request_sync(#kpro_req{api = API, vsn = Vsn} = Req,
                      Sock, Mod, ClientId, CorrId, Timeout, ErrorTag) ->
  ReqBin = kpro:encode_request(ClientId, ?SASL_AUTH_REQ_CORRID, Req),
  try
    ok = Mod:send(Sock, ReqBin),
    {ok, <<Len:32>>} = Mod:recv(Sock, 4, Timeout),
    {ok, RspBin} = Mod:recv(Sock, Len, Timeout),
    {[{CorrId, Rsp}], <<>>} =
      kpro_rsp_lib:decode_corr_id(<<Len:32, RspBin/binary>>),
    kpro_rsp_lib:decode_body(API, Vsn, Rsp)
  catch
    error : Reason ->
      Stack = erlang:get_stacktrace(),
      erlang:raise(error, {ErrorTag, Reason}, Stack)
  end.

get_tcp_mod(_SslOpts = true)  -> ssl;
get_tcp_mod(_SslOpts = [_|_]) -> ssl;
get_tcp_mod(_)                -> gen_tcp.

maybe_upgrade_to_ssl(Sock, _Mod = ssl, SslOpts0, Timeout) ->
  SslOpts = case SslOpts0 of
              true -> [];
              [_|_] -> SslOpts0
            end,
  case ssl:connect(Sock, SslOpts, Timeout) of
    {ok, NewSock} -> NewSock;
    {error, Reason} -> erlang:error({failed_to_upgrade_to_ssl, Reason})
  end;
maybe_upgrade_to_ssl(Sock, _Mod, _SslOpts, _Timeout) ->
  Sock.

sasl_auth(_Host, _Sock, _Mod, _ClientId, _Timeout, ?undef) ->
  %% no auth
  ok;
sasl_auth(_Host, Sock, Mod, ClientId, Timeout,
          {_Method = plain, SaslUser, SaslPassword}) ->
  ok = setopts(Sock, Mod, [{active, false}]),
  Req = kpro:make_request(sasl_handshake, _V = 0, [{mechanism, <<"PLAIN">>}]),
  Rsp = inactive_request_sync(Req, Sock, Mod, ClientId,
                              ?SASL_AUTH_REQ_CORRID, Timeout, sasl_auth_error),
  #kpro_rsp{api = sasl_handshake, vsn = 0, msg = Body} = Rsp,
  ErrorCode = kpro:find(error_code, Body),
  case kpro_error_code:is_error(ErrorCode) of
    true ->
      erlang:error({sasl_auth_error, ErrorCode});
    false ->
      ok = Mod:send(Sock, sasl_plain_token(SaslUser, SaslPassword)),
      case Mod:recv(Sock, 4, Timeout) of
        {ok, <<0:32>>} ->
          ok;
        {error, closed} ->
          erlang:error({sasl_auth_error, bad_credentials});
        Unexpected ->
          erlang:error({sasl_auth_error, Unexpected})
      end
  end;
sasl_auth(Host, Sock, Mod, ClientId, Timeout,
          {callback, ModuleName, Opts}) ->
  case kpro_auth_backend:auth(ModuleName, Host, Sock, Mod,
                              ClientId, Timeout, Opts) of
    ok ->
      ok;
    {error, Reason} ->
      erlang:error({sasl_auth_error, Reason})
  end.

sasl_plain_token(User, Password) ->
  Message = list_to_binary([0, unicode:characters_to_binary(User),
                            0, unicode:characters_to_binary(Password)]),
  <<(byte_size(Message)):32, Message/binary>>.

setopts(Sock, _Mod = gen_tcp, Opts) -> inet:setopts(Sock, Opts);
setopts(Sock, _Mod = ssl, Opts)     ->  ssl:setopts(Sock, Opts).

-spec wait_for_rsp(connection(), kpro:req(), timeout()) ->
        {ok, term()} | {error, any()}.
wait_for_rsp(Pid, #kpro_req{ref = Ref}, Timeout) ->
  Mref = erlang:monitor(process, Pid),
  receive
    {msg, Pid, #kpro_rsp{ref = Ref} = Rsp} ->
      erlang:demonitor(Mref, [flush]),
      {ok, Rsp};
    {'DOWN', Mref, _, _, Reason} ->
      {error, {sock_down, Reason}}
  after
    Timeout ->
      erlang:demonitor(Mref, [flush]),
      {error, timeout}
  end.

system_call(Pid, Request) ->
  Mref = erlang:monitor(process, Pid),
  erlang:send(Pid, {system, {self(), Mref}, Request}),
  receive
    {Mref, Reply} ->
      erlang:demonitor(Mref, [flush]),
      Reply;
    {'DOWN', Mref, _, _, Reason} ->
      {error, {sock_down, Reason}}
  end.

call(Pid, Request) ->
  Mref = erlang:monitor(process, Pid),
  erlang:send(Pid, {{self(), Mref}, Request}),
  receive
    {Mref, Reply} ->
      erlang:demonitor(Mref, [flush]),
      Reply;
    {'DOWN', Mref, _, _, Reason} ->
      {error, {sock_down, Reason}}
  end.

reply({To, Tag}, Reply) ->
  To ! {Tag, Reply}.

loop(#state{sock = Sock, mod = Mod} = State, Debug) ->
  ok = setopts(Sock, Mod, [{active, once}]),
  Msg = receive Input -> Input end,
  decode_msg(Msg, State, Debug).

decode_msg({system, From, Msg}, #state{parent = Parent} = State, Debug) ->
  sys:handle_system_msg(Msg, From, Parent, ?MODULE, Debug, State);
decode_msg(Msg, State, [] = Debug) ->
  handle_msg(Msg, State, Debug);
decode_msg(Msg, State, Debug0) ->
  Debug = sys:handle_debug(Debug0, fun print_msg/3, State, Msg),
  handle_msg(Msg, State, Debug).

handle_msg({_, Sock, Bin}, #state{ sock     = Sock
                                 , acc      = Acc0
                                 , requests = Requests
                                 , mod      = Mod
                                 } = State, Debug) when is_binary(Bin) ->
  case Mod of
    gen_tcp -> ok = inet:setopts(Sock, [{active, once}]);
    ssl     -> ok = ssl:setopts(Sock, [{active, once}])
  end,
  Acc1 = acc_recv_bytes(Acc0, Bin),
  {Responses, Acc} = decode_response(Acc1),
  NewRequests =
    lists:foldl(
      fun({CorrId, Body}, Reqs) ->
        {Caller, Ref, API, Vsn} = kpro_sent_reqs:get_req(Reqs, CorrId),
        Rsp = kpro_rsp_lib:decode_body(API, Vsn, Body),
        ok = cast(Caller, {msg, self(), Rsp#kpro_rsp{ref = Ref}}),
        kpro_sent_reqs:del(Reqs, CorrId)
      end, Requests, Responses),
  ?MODULE:loop(State#state{acc = Acc, requests = NewRequests}, Debug);
handle_msg(assert_max_req_age, #state{ requests = Requests
                                     , req_timeout = ReqTimeout
                                     } = State, Debug) ->
  SockPid = self(),
  erlang:spawn_link(fun() ->
                        ok = assert_max_req_age(Requests, ReqTimeout),
                        ok = send_assert_max_req_age(SockPid, ReqTimeout)
                    end),
  ?MODULE:loop(State, Debug);
handle_msg({tcp_closed, Sock}, #state{sock = Sock}, _) ->
  exit({shutdown, tcp_closed});
handle_msg({ssl_closed, Sock}, #state{sock = Sock}, _) ->
  exit({shutdown, ssl_closed});
handle_msg({tcp_error, Sock, Reason}, #state{sock = Sock}, _) ->
  exit({tcp_error, Reason});
handle_msg({ssl_error, Sock, Reason}, #state{sock = Sock}, _) ->
  exit({ssl_error, Reason});
handle_msg({From, {send, Request}},
           #state{ client_id = ClientId
                 , mod       = Mod
                 , sock      = Sock
                 , requests  = Requests
                 } = State, Debug) ->
  {Caller, _Ref} = From,
  {CorrId, NewRequests} =
    case Request of
      #kpro_req{no_ack = true} ->
        kpro_sent_reqs:increment_corr_id(Requests);
      #kpro_req{ref = Ref, api = API, vsn = Vsn} ->
        kpro_sent_reqs:add(Requests, Caller, Ref, API, Vsn)
    end,
  RequestBin = kpro:encode_request(ClientId, CorrId, Request),
  Res = case Mod of
          gen_tcp -> gen_tcp:send(Sock, RequestBin);
          ssl     -> ssl:send(Sock, RequestBin)
        end,
  case Res of
    ok ->
      _ = reply(From, ok),
      ok;
    {error, Reason} ->
      exit({send_error, Reason})
  end,
  ?MODULE:loop(State#state{requests = NewRequests}, Debug);
handle_msg({From, get_tcp_sock}, State, Debug) ->
  _ = reply(From, {ok, State#state.sock}),
  ?MODULE:loop(State, Debug);
handle_msg({From, stop}, #state{mod = Mod, sock = Sock}, _Debug) ->
  Mod:close(Sock),
  _ = reply(From, ok),
  ok;
handle_msg(Msg, #state{} = State, Debug) ->
  error_logger:warning_msg("[~p] ~p got unrecognized message: ~p",
                          [?MODULE, self(), Msg]),
  ?MODULE:loop(State, Debug).

cast(Pid, Msg) ->
  try
    Pid ! Msg,
    ok
  catch _ : _ ->
    ok
  end.

system_continue(_Parent, Debug, State) ->
  ?MODULE:loop(State, Debug).

-spec system_terminate(any(), _, _, _) -> no_return().
system_terminate(Reason, _Parent, Debug, _Misc) ->
  sys:print_log(Debug),
  exit(Reason).

system_code_change(State, _Module, _Vsn, _Extra) ->
  {ok, State}.

format_status(Opt, Status) ->
  {Opt, Status}.

print_msg(Device, {_From, {send, Request}}, State) ->
  do_print_msg(Device, "send: ~p", [Request], State);
print_msg(Device, {tcp, _Sock, Bin}, State) ->
  do_print_msg(Device, "tcp: ~p", [Bin], State);
print_msg(Device, {tcp_closed, _Sock}, State) ->
  do_print_msg(Device, "tcp_closed", [], State);
print_msg(Device, {tcp_error, _Sock, Reason}, State) ->
  do_print_msg(Device, "tcp_error: ~p", [Reason], State);
print_msg(Device, {_From, stop}, State) ->
  do_print_msg(Device, "stop", [], State);
print_msg(Device, Msg, State) ->
  do_print_msg(Device, "unknown msg: ~p", [Msg], State).

do_print_msg(Device, Fmt, Args, State) ->
  CorrId = kpro_sent_reqs:get_corr_id(State#state.requests),
  io:format(Device, "[~s] ~p [~10..0b] " ++ Fmt ++ "~n",
            [ts(), self(), CorrId] ++ Args).

ts() ->
  Now = os:timestamp(),
  {_, _, MicroSec} = Now,
  {{Y, M, D}, {HH, MM, SS}} = calendar:now_to_local_time(Now),
  lists:flatten(io_lib:format("~.4.0w-~.2.0w-~.2.0w ~.2.0w:~.2.0w:~.2.0w.~w",
                              [Y, M, D, HH, MM, SS, MicroSec])).

-spec get_connect_timeout(config()) -> timeout().
get_connect_timeout(Config) ->
  maps:get(connect_timeout, Config, ?DEFAULT_CONNECT_TIMEOUT).

%% Get request timeout from config.
-spec get_request_timeout(config()) -> timeout().
get_request_timeout(Config) ->
  maps:get(request_timeout, Config, ?DEFAULT_REQUEST_TIMEOUT).

-spec assert_max_req_age(requests(), timeout()) -> ok | no_return().
assert_max_req_age(Requests, Timeout) ->
  case kpro_sent_reqs:scan_for_max_age(Requests) of
    Age when Age > Timeout ->
      erlang:exit(request_timeout);
    _ ->
      ok
  end.

%% Send the 'assert_max_req_age' message to connection process.
%% The send interval is set to a half of configured timeout.
-spec send_assert_max_req_age(connection(), timeout()) -> ok.
send_assert_max_req_age(Pid, Timeout) when Timeout >= 1000 ->
  %% Check every 1 minute
  %% or every half of the timeout value if it's less than 2 minute
  SendAfter = erlang:min(Timeout div 2, timer:minutes(1)),
  _ = erlang:send_after(SendAfter, Pid, assert_max_req_age),
  ok.

%% Accumulate newly received bytes.
-spec acc_recv_bytes(acc(), binary()) -> acc().
acc_recv_bytes(Acc, NewBytes) when is_binary(Acc) ->
  case <<Acc/binary, NewBytes/binary>> of
    <<Size:32/signed-integer, _/binary>> = AccBytes ->
      do_acc(#acc{expected_size = Size + ?SIZE_HEAD_BYTES}, AccBytes);
    AccBytes ->
      AccBytes
  end;
acc_recv_bytes(#acc{} = Acc, NewBytes) ->
  do_acc(Acc, NewBytes).

%% Add newly received bytes to buffer.
-spec do_acc(acc(), binary()) -> acc().
do_acc(#acc{acc_size = AccSize, acc_buffer = AccBuffer} = Acc, NewBytes) ->
  Acc#acc{ acc_size = AccSize + size(NewBytes)
         , acc_buffer = [NewBytes | AccBuffer]
         }.

%% Decode response when accumulated enough bytes.
-spec decode_response(acc()) -> {[kpro:rsp()], acc()}.
decode_response(#acc{ expected_size = ExpectedSize
                    , acc_size = AccSize
                    , acc_buffer = AccBuffer
                    }) when AccSize >= ExpectedSize ->
  kpro_rsp_lib:decode_corr_id(iolist_to_binary(lists:reverse(AccBuffer)));
decode_response(Acc) ->
  {[], Acc}.

%% So far supported endpoint is tuple {Hostname, Port}
%% which lacks of hint on which protocol to use.
%% It would be a bit nicer if we support endpoint formats like below:
%%    PLAINTEX://hostname:port
%%    SSL://hostname:port
%%    SASL_PLAINTEXT://hostname:port
%%    SASL_SSL://hostname:port
%% which may give some hint for early config validation before trying to
%% connect to the endpoint.
%%
%% However, even with the hint, it is still quite easy to misconfig and endup
%% with a clueless crash report.  Here we try to make a guess on what went
%% wrong in case there was an error during connection estabilishment.
maybe_log_hint(Host, Port, Reason, IsSsl, SaslOpt) ->
  case hint_msg(Reason, IsSsl, SaslOpt) of
    ?undef ->
      ok;
    Msg ->
      error_logger:error_msg("Failed to connect to ~s:~p\n~s\n",
                             [Host, Port, Msg])
  end.

hint_msg({failed_to_upgrade_to_ssl, R}, _IsSsl, SaslOpt) when R =:= closed;
                                                              R =:= timeout ->
  case SaslOpt of
    ?undef -> "Make sure connecting to a 'SSL://' listener";
    _      -> "Make sure connecting to 'SASL_SSL://' listener"
  end;
hint_msg({sasl_auth_error, 'IllegalSaslState'}, true, _SaslOpt) ->
  "Make sure connecting to 'SASL_SSL://' listener";
hint_msg({sasl_auth_error, 'IllegalSaslState'}, false, _SaslOpt) ->
  "Make sure connecting to 'SASL_PLAINTEXT://' listener";
hint_msg({sasl_auth_error, {badmatch, {error, enomem}}}, false, _SaslOpts) ->
  %% This happens when KAFKA is expecting SSL handshake
  %% but client started SASL handshake instead
  "Make sure 'ssl' option is in client config, \n"
  "or make sure connecting to 'SASL_PLAINTEXT://' listener";
hint_msg(_, _, _) ->
  %% Sorry, I have no clue, please read the crash log
  ?undef.

%% Get sasl options from connection config.
-spec get_sasl_opt(config()) -> cfg_val().
get_sasl_opt(Config) ->
  case maps:get(sasl, Config, ?undef) of
    {plain, User, PassFun} when is_function(PassFun) ->
      {plain, User, PassFun()};
    {plain, File} ->
      {User, Pass} = read_sasl_file(File),
      {plain, User, Pass};
    Other ->
      Other
  end.

%% Read a regular file, assume it has two lines:
%% First line is the sasl-plain username
%% Second line is the password
-spec read_sasl_file(file:name_all()) -> {binary(), binary()}.
read_sasl_file(File) ->
  {ok, Bin} = file:read_file(File),
  Lines = binary:split(Bin, <<"\n">>, [global]),
  [User, Pass] = lists:filter(fun(Line) -> Line =/= <<>> end, Lines),
  {User, Pass}.

%% Ensure string() hostname
host(Host) when is_binary(Host) -> binary_to_list(Host);
host(Host) when is_list(Host) -> Host.

%% Ensure binary client id
get_client_id(Config) ->
  ClientId = maps:get(client_id, Config, <<"kpro_default">>),
  case is_atom(ClientId) of
    true -> atom_to_binary(ClientId, utf8);
    false -> ClientId
  end.

%%%_* Eunit ====================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

acc_test_() ->
  [{"clean start flow",
    fun() ->
        Acc0 = acc_recv_bytes(<<>>, <<0, 0>>),
        ?assertEqual(Acc0, <<0, 0>>),
        Acc1 = acc_recv_bytes(Acc0, <<0, 1, 0, 0>>),
        ?assertEqual(#acc{expected_size = 5,
                          acc_size = 6,
                          acc_buffer = [<<0, 0, 0, 1, 0, 0>>]
                         }, Acc1)
    end},
   {"old tail leftover",
    fun() ->
        Acc0 = acc_recv_bytes(<<0, 0>>, <<0, 4>>),
        ?assertEqual(#acc{expected_size = 8,
                          acc_size = 4,
                          acc_buffer = [<<0, 0, 0, 4>>]
                         }, Acc0),
        Acc1 = acc_recv_bytes(Acc0, <<0, 0>>),
        ?assertEqual(#acc{expected_size = 8,
                          acc_size = 6,
                          acc_buffer = [<<0, 0>>, <<0, 0, 0, 4>>]
                         }, Acc1),
        Acc2 = acc_recv_bytes(Acc1, <<1, 1>>),
        ?assertEqual(#acc{expected_size = 8,
                          acc_size = 8,
                          acc_buffer = [<<1, 1>>, <<0, 0>>, <<0, 0, 0, 4>>]
                         }, Acc2)
    end
   }
  ].

-endif.

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End: