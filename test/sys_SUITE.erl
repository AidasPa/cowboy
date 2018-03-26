%% Copyright (c) 2018, Loïc Hoguin <essen@ninenines.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(sys_SUITE).
-compile(export_all).
-compile(nowarn_export_all).

-import(ct_helper, [config/2]).
-import(ct_helper, [doc/1]).
-import(cowboy_test, [gun_open/1]).

all() ->
	[{group, sys}].

groups() ->
	[{sys, [parallel], ct_helper:all(?MODULE)}].

init_per_suite(Config) ->
	ct:print("This test suite will produce error reports about "
		"EXIT signals for unknown processes."),
	ProtoOpts = #{
		env => #{dispatch => init_dispatch(Config)}
	},
	%% Clear listener.
	{ok, _} = cowboy:start_clear(clear, [{port, 0}], ProtoOpts),
	ClearPort = ranch:get_port(clear),
	%% TLS listener.
	TLSOpts = ct_helper:get_certs_from_ets(),
	{ok, _} = cowboy:start_tls(tls, TLSOpts ++ [{port, 0}], ProtoOpts),
	TLSPort = ranch:get_port(tls),
	[
		{clear_port, ClearPort},
		%% @todo Add the h2 stuff to the opts.
		{tls_opts, TLSOpts},
		{tls_port, TLSPort}
	|Config].

end_per_suite(_) ->
	ok = cowboy:stop_listener(clear),
	ok = cowboy:stop_listener(tls).

init_dispatch(_) ->
	cowboy_router:compile([{"[...]", [
		{"/", hello_h, []},
		{"/loop", long_polling_sys_h, []},
		{"/ws", ws_echo, []}
	]}]).

do_get_remote_pid_tcp(Socket) when is_port(Socket) ->
	do_get_remote_pid_tcp(inet:sockname(Socket));
do_get_remote_pid_tcp(SockName) ->
	AllPorts = [{P, erlang:port_info(P)} || P <- erlang:ports()],
	[Pid] = [
		proplists:get_value(connected, I)
	|| {P, I} <- AllPorts,
		I =/= undefined,
		proplists:get_value(name, I) =:= "tcp_inet",
		inet:peername(P) =:= SockName],
	Pid.

-include_lib("ssl/src/ssl_connection.hrl").

do_get_remote_pid_tls(Socket) ->
	%% This gives us the pid of the sslsocket process.
	%% We must introspect this process in order to retrieve the connection pid.
	TLSPid = do_get_remote_pid_tcp(ssl:sockname(Socket)),
	{_, #state{user_application={_, UserPid}}} = sys:get_state(TLSPid),
	UserPid.

do_get_parent_pid(Pid) ->
	{_, ProcDict} = process_info(Pid, dictionary),
	{_, [Parent|_]} = lists:keyfind('$ancestors', 1, ProcDict),
	Parent.

%% proc_lib.

proc_lib_initial_call_clear(Config) ->
	doc("Confirm that clear connection processes are started using proc_lib."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config), []),
	timer:sleep(100),
	Pid = do_get_remote_pid_tcp(Socket),
	{cowboy_clear, _, _} = proc_lib:initial_call(Pid),
	ok.

proc_lib_initial_call_tls(Config) ->
	doc("Confirm that TLS connection processes are started using proc_lib."),
	{ok, Socket} = ssl:connect("localhost", config(tls_port, Config), config(tls_opts, Config)),
	timer:sleep(100),
	Pid = do_get_remote_pid_tls(Socket),
	{cowboy_tls, _, _} = proc_lib:initial_call(Pid),
	ok.

%% System messages.
%%
%% Plain system messages are received as {system, From, Msg}.
%% The content and meaning of this message are not interpreted by
%% the receiving process module. When a system message is received,
%% function handle_system_msg/6 is called to handle the request.

bad_system_from_h1(Config) ->
	doc("h1: Sending a system message with a bad From value results in a process crash."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config), [{active, false}]),
	timer:sleep(100),
	Pid = do_get_remote_pid_tcp(Socket),
	ct_helper_error_h:ignore(Pid, gen, reply, 2),
	Pid ! {system, bad, get_state},
	{error, closed} = gen_tcp:recv(Socket, 0, 1000),
	false = is_process_alive(Pid),
	ok.

bad_system_from_h2(Config) ->
	doc("h2: Sending a system message with a bad From value results in a process crash."),
	{ok, Socket} = ssl:connect("localhost", config(tls_port, Config),
		[{active, false}, binary, {alpn_advertised_protocols, [<<"h2">>]}]),
	%% Skip the SETTINGS frame.
	{ok, <<_,_,_,4,_/bits>>} = ssl:recv(Socket, 0, 1000),
	timer:sleep(100),
	Pid = do_get_remote_pid_tls(Socket),
	ct_helper_error_h:ignore(Pid, gen, reply, 2),
	Pid ! {system, bad, get_state},
	{error, closed} = ssl:recv(Socket, 0, 1000),
	false = is_process_alive(Pid),
	ok.

bad_system_from_ws(Config) ->
	doc("ws: Sending a system message with a bad From value results in a process crash."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config),
		[binary, {active, false}]),
	ok = gen_tcp:send(Socket,
		"GET /ws HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"Connection: Upgrade\r\n"
		"Origin: http://localhost\r\n"
		"Sec-WebSocket-Version: 13\r\n"
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
		"Upgrade: websocket\r\n"
		"\r\n"),
	{ok, Handshake} = gen_tcp:recv(Socket, 0, 5000),
	{ok, {http_response, {1, 1}, 101, _}, _} = erlang:decode_packet(http, Handshake, []),
	timer:sleep(100),
	Pid = do_get_remote_pid_tcp(Socket),
	ct_helper_error_h:ignore(Pid, gen, reply, 2),
	Pid ! {system, bad, get_state},
	{error, closed} = gen_tcp:recv(Socket, 0, 1000),
	false = is_process_alive(Pid),
	ok.

bad_system_from_loop(Config) ->
	doc("loop: Sending a system message with a bad From value results in a process crash."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config), [{active, false}]),
	ok = gen_tcp:send(Socket,
		"GET /loop HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"\r\n"),
	timer:sleep(100),
	SupPid = do_get_remote_pid_tcp(Socket),
	[{_, Pid, _, _}] = supervisor:which_children(SupPid),
	ct_helper_error_h:ignore(Pid, gen, reply, 2),
	Pid ! {system, bad, get_state},
	{ok, "HTTP/1.1 500 "} = gen_tcp:recv(Socket, 13, 1000),
	false = is_process_alive(Pid),
	ok.

bad_system_message_h1(Config) ->
	doc("h1: Sending a system message with a bad Request value results in an error."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config), []),
	timer:sleep(100),
	Pid = do_get_remote_pid_tcp(Socket),
	Ref = make_ref(),
	Pid ! {system, {self(), Ref}, hello},
	receive
		{Ref, {error, {unknown_system_msg, hello}}} ->
			ok
	after 1000 ->
		error(timeout)
	end.

bad_system_message_h2(Config) ->
	doc("h2: Sending a system message with a bad Request value results in an error."),
	{ok, Socket} = ssl:connect("localhost", config(tls_port, Config),
		[{active, false}, binary, {alpn_advertised_protocols, [<<"h2">>]}]),
	%% Skip the SETTINGS frame.
	{ok, <<_,_,_,4,_/bits>>} = ssl:recv(Socket, 0, 1000),
	timer:sleep(100),
	Pid = do_get_remote_pid_tls(Socket),
	Ref = make_ref(),
	Pid ! {system, {self(), Ref}, hello},
	receive
		{Ref, {error, {unknown_system_msg, hello}}} ->
			ok
	after 1000 ->
		error(timeout)
	end.

bad_system_message_ws(Config) ->
	doc("ws: Sending a system message with a bad Request value results in an error."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config),
		[binary, {active, false}]),
	ok = gen_tcp:send(Socket,
		"GET /ws HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"Connection: Upgrade\r\n"
		"Origin: http://localhost\r\n"
		"Sec-WebSocket-Version: 13\r\n"
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
		"Upgrade: websocket\r\n"
		"\r\n"),
	{ok, Handshake} = gen_tcp:recv(Socket, 0, 5000),
	{ok, {http_response, {1, 1}, 101, _}, _} = erlang:decode_packet(http, Handshake, []),
	timer:sleep(100),
	Pid = do_get_remote_pid_tcp(Socket),
	Ref = make_ref(),
	Pid ! {system, {self(), Ref}, hello},
	receive
		{Ref, {error, {unknown_system_msg, hello}}} ->
			ok
	after 1000 ->
		error(timeout)
	end.

bad_system_message_loop(Config) ->
	doc("loop: Sending a system message with a bad Request value results in an error."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config), [{active, false}]),
	ok = gen_tcp:send(Socket,
		"GET /loop HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"\r\n"),
	timer:sleep(100),
	SupPid = do_get_remote_pid_tcp(Socket),
	[{_, Pid, _, _}] = supervisor:which_children(SupPid),
	Ref = make_ref(),
	Pid ! {system, {self(), Ref}, hello},
	receive
		{Ref, {error, {unknown_system_msg, hello}}} ->
			ok
	after 1000 ->
		error(timeout)
	end.

good_system_message_h1(Config) ->
	doc("h1: System messages are handled properly."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config), []),
	timer:sleep(100),
	Pid = do_get_remote_pid_tcp(Socket),
	Ref = make_ref(),
	Pid ! {system, {self(), Ref}, get_state},
	receive
		{Ref, Result} when element(1, Result) =/= error ->
			ok
	after 1000 ->
		error(timeout)
	end.

good_system_message_h2(Config) ->
	doc("h2: System messages are handled properly."),
	{ok, Socket} = ssl:connect("localhost", config(tls_port, Config),
		[{active, false}, binary, {alpn_advertised_protocols, [<<"h2">>]}]),
	%% Skip the SETTINGS frame.
	{ok, <<_,_,_,4,_/bits>>} = ssl:recv(Socket, 0, 1000),
	timer:sleep(100),
	Pid = do_get_remote_pid_tls(Socket),
	Ref = make_ref(),
	Pid ! {system, {self(), Ref}, get_state},
	receive
		{Ref, Result} when element(1, Result) =/= error ->
			ok
	after 1000 ->
		error(timeout)
	end.

good_system_message_ws(Config) ->
	doc("ws: Sending a system message with a bad Request value results in an error."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config),
		[binary, {active, false}]),
	ok = gen_tcp:send(Socket,
		"GET /ws HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"Connection: Upgrade\r\n"
		"Origin: http://localhost\r\n"
		"Sec-WebSocket-Version: 13\r\n"
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
		"Upgrade: websocket\r\n"
		"\r\n"),
	{ok, Handshake} = gen_tcp:recv(Socket, 0, 5000),
	{ok, {http_response, {1, 1}, 101, _}, _} = erlang:decode_packet(http, Handshake, []),
	timer:sleep(100),
	Pid = do_get_remote_pid_tcp(Socket),
	Ref = make_ref(),
	Pid ! {system, {self(), Ref}, get_state},
	receive
		{Ref, Result} when element(1, Result) =/= error ->
			ok
	after 1000 ->
		error(timeout)
	end.

good_system_message_loop(Config) ->
	doc("loop: Sending a system message with a bad Request value results in an error."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config), [{active, false}]),
	ok = gen_tcp:send(Socket,
		"GET /loop HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"\r\n"),
	timer:sleep(100),
	SupPid = do_get_remote_pid_tcp(Socket),
	[{_, Pid, _, _}] = supervisor:which_children(SupPid),
	Ref = make_ref(),
	Pid ! {system, {self(), Ref}, get_state},
	receive
		{Ref, Result} when element(1, Result) =/= error ->
			ok
	after 1000 ->
		error(timeout)
	end.

%% 'EXIT'.
%%
%% Shutdown messages. If the process traps exits, it must be able
%% to handle a shutdown request from its parent, the supervisor.
%% The message {'EXIT', Parent, Reason} from the parent is an order
%% to terminate. The process must terminate when this message is
%% received, normally with the same Reason as Parent.

trap_exit_parent_exit_h1(Config) ->
	doc("h1: A process trapping exits must stop when receiving "
		"an 'EXIT' message from its parent."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config),
		[{active, false}]),
	timer:sleep(100),
	Pid = do_get_remote_pid_tcp(Socket),
	Parent = do_get_parent_pid(Pid),
	Pid ! {'EXIT', Parent, shutdown},
	{error, closed} = gen_tcp:recv(Socket, 0, 1000),
	false = is_process_alive(Pid),
	ok.

trap_exit_parent_exit_h2(Config) ->
	doc("h2: A process trapping exits must stop when receiving "
		"an 'EXIT' message from its parent."),
	{ok, Socket} = ssl:connect("localhost", config(tls_port, Config),
		[{active, false}, binary, {alpn_advertised_protocols, [<<"h2">>]}]),
	%% Skip the SETTINGS frame.
	{ok, <<_,_,_,4,_/bits>>} = ssl:recv(Socket, 0, 1000),
	timer:sleep(100),
	Pid = do_get_remote_pid_tls(Socket),
	Parent = do_get_parent_pid(Pid),
	Pid ! {'EXIT', Parent, shutdown},
	{error, closed} = ssl:recv(Socket, 0, 1000),
	false = is_process_alive(Pid),
	ok.

trap_exit_parent_exit_ws(Config) ->
	doc("ws: A process trapping exits must stop when receiving "
		"an 'EXIT' message from its parent."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config),
		[binary, {active, false}]),
	ok = gen_tcp:send(Socket,
		"GET /ws HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"Connection: Upgrade\r\n"
		"Origin: http://localhost\r\n"
		"Sec-WebSocket-Version: 13\r\n"
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
		"Upgrade: websocket\r\n"
		"\r\n"),
	{ok, Handshake} = gen_tcp:recv(Socket, 0, 5000),
	{ok, {http_response, {1, 1}, 101, _}, _} = erlang:decode_packet(http, Handshake, []),
	timer:sleep(100),
	Pid = do_get_remote_pid_tcp(Socket),
	Parent = do_get_parent_pid(Pid),
	Pid ! {'EXIT', Parent, shutdown},
	{error, closed} = gen_tcp:recv(Socket, 0, 1000),
	false = is_process_alive(Pid),
	ok.

trap_exit_parent_exit_loop(Config) ->
	doc("loop: A process trapping exits must stop when receiving "
		"an 'EXIT' message from its parent."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config), [{active, false}]),
	ok = gen_tcp:send(Socket,
		"GET /loop HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"\r\n"),
	timer:sleep(100),
	Parent = do_get_remote_pid_tcp(Socket),
	[{_, Pid, _, _}] = supervisor:which_children(Parent),
	Pid ! {'EXIT', Parent, shutdown},
	%% We exit normally but didn't send a response.
	{ok, "HTTP/1.1 204 "} = gen_tcp:recv(Socket, 13, 1000),
	false = is_process_alive(Pid),
	ok.

trap_exit_other_exit_h1(Config) ->
	doc("h1: A process trapping exits must ignore "
		"'EXIT' messages from unknown processes."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config),
		[{active, false}]),
	timer:sleep(100),
	Pid = do_get_remote_pid_tcp(Socket),
	Pid ! {'EXIT', self(), shutdown},
	ok = gen_tcp:send(Socket,
		"GET / HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"\r\n"),
	{ok, "HTTP/1.1 200 "} = gen_tcp:recv(Socket, 13, 1000),
	true = is_process_alive(Pid),
	ok.

trap_exit_other_exit_h2(Config) ->
	doc("h2: A process trapping exits must ignore "
		"'EXIT' messages from unknown processes."),
	{ok, Socket} = ssl:connect("localhost", config(tls_port, Config),
		[{active, false}, binary, {alpn_advertised_protocols, [<<"h2">>]}]),
	%% Do the handshake.
	ok = ssl:send(Socket, ["PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", cow_http2:settings(#{})]),
	{ok, <<_,_,_,4,_/bits>>} = ssl:recv(Socket, 0, 1000),
	ok = ssl:send(Socket, cow_http2:settings_ack()),
	{ok, << 0:24, 4:8, 1:8, 0:32 >>} = ssl:recv(Socket, 9, 1000),
	timer:sleep(100),
	Pid = do_get_remote_pid_tls(Socket),
	Pid ! {'EXIT', self(), shutdown},
	%% Send a HEADERS frame as a request.
	{HeadersBlock, _} = cow_hpack:encode([
		{<<":method">>, <<"GET">>},
		{<<":scheme">>, <<"https">>},
		{<<":authority">>, <<"localhost">>}, %% @todo Correct port number.
		{<<":path">>, <<"/">>}
	]),
	ok = ssl:send(Socket, cow_http2:headers(1, fin, HeadersBlock)),
	%% Receive a HEADERS frame as a response.
	{ok, << _:24, 1:8, _:40 >>} = ssl:recv(Socket, 9, 6000),
	true = is_process_alive(Pid),
	ok.

trap_exit_other_exit_ws(Config) ->
	doc("ws: A process trapping exits must ignore "
		"'EXIT' messages from unknown processes."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config),
		[binary, {active, false}]),
	ok = gen_tcp:send(Socket,
		"GET /ws HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"Connection: Upgrade\r\n"
		"Origin: http://localhost\r\n"
		"Sec-WebSocket-Version: 13\r\n"
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
		"Upgrade: websocket\r\n"
		"\r\n"),
	{ok, Handshake} = gen_tcp:recv(Socket, 0, 5000),
	{ok, {http_response, {1, 1}, 101, _}, _} = erlang:decode_packet(http, Handshake, []),
	timer:sleep(100),
	Pid = do_get_remote_pid_tcp(Socket),
	Pid ! {'EXIT', self(), shutdown},
	%% The process stays alive.
	{error, timeout} = gen_tcp:recv(Socket, 0, 1000),
	true = is_process_alive(Pid),
	ok.

trap_exit_other_exit_loop(Config) ->
	doc("loop: A process trapping exits must ignore "
		"'EXIT' messages from unknown processes."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config), [{active, false}]),
	ok = gen_tcp:send(Socket,
		"GET /loop HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"\r\n"),
	timer:sleep(100),
	Parent = do_get_remote_pid_tcp(Socket),
	[{_, Pid, _, _}] = supervisor:which_children(Parent),
	Pid ! {'EXIT', self(), shutdown},
	%% The process stays alive.
	{ok, "HTTP/1.1 299 "} = gen_tcp:recv(Socket, 13, 1000),
	true = is_process_alive(Pid),
	ok.

%% get_modules.
%%
%% If the modules used to implement the process change dynamically
%% during runtime, the process must understand one more message.
%% An example is the gen_event processes. The message is
%% {_Label, {From, Ref}, get_modules}. The reply to this message is
%% From ! {Ref, Modules}, where Modules is a list of the currently
%% active modules in the process.
%%
%% For example:
%%
%%   1> application:start(sasl).
%%   ok
%%   2> gen:call(alarm_handler, self(), get_modules).
%%   {ok,[alarm_handler]}
%%   3> whereis(alarm_handler) ! {'$gen', {self(), make_ref()}, get_modules}.
%%   {'$gen',{<0.61.0>,#Ref<0.2900144977.374865921.142102>},
%%           get_modules}
%%   4> flush().
%%   Shell got {#Ref<0.2900144977.374865921.142102>,[alarm_handler]}
%%
%% Cowboy's connection processes change dynamically: it starts with
%% cowboy_clear or cowboy_tls, then becomes cowboy_http or cowboy_http2
%% and may then become or involve cowboy_websocket. On top of that
%% it has various callback modules in the form of stream handlers.

%% @todo
%get_modules_h1(Config) ->
%get_modules_h2(Config) ->
%get_modules_ws(Config) ->
%get_modules_loop(Config) ->

%% @todo On top of this we will want to make the supervisor calls
%% in ranch_conns_sup return dynamic instead of a list of modules.

%% sys.

%% @todo sys:change_code/4,5 and Module:system_code_change/4
%sys_change_code_h1(Config) ->
%sys_change_code_h2(Config) ->
%sys_change_code_ws(Config) ->
%sys_change_code_loop(Config) ->

%% @todo sys:get_state/1,2 and Module:system_get_state/1
%sys_get_state_h1(Config) ->
%sys_get_state_h2(Config) ->
%sys_get_state_ws(Config) ->
%sys_get_state_loop(Config) ->

%% @todo sys:get_status/1,2
%sys_get_status_h1(Config) ->
%sys_get_status_h2(Config) ->
%sys_get_status_ws(Config) ->
%sys_get_status_loop(Config) ->

%% @todo sys:replace_state/2,3 and Module:replace_state/2
%sys_replace_state_h1(Config) ->
%sys_replace_state_h2(Config) ->
%sys_replace_state_ws(Config) ->
%sys_replace_state_loop(Config) ->

%% @todo sys:resume/1,2 and sys:suspend/1,2 and Module:system_continue/3
%sys_suspend_and_resume_h1(Config) ->
%sys_suspend_and_resume_h2(Config) ->
%sys_suspend_and_resume_ws(Config) ->
%sys_suspend_and_resume_loop(Config) ->

%% @todo sys:terminate/2,3 and Module:system_terminate/4
%sys_terminate_h1(Config) ->
%sys_terminate_h2(Config) ->
%sys_terminate_ws(Config) ->
%sys_terminate_loop(Config) ->

%% @todo Debugging functionality from sys.
%%
%% The functions make references to a debug structure.
%% The debug structure is a list of dbg_opt(), which is
%% an internal data type used by function handle_system_msg/6.
%% No debugging is performed if it is an empty list.
%%
%% Cowboy currently does not implement sys debugging.
%%
%% The following functions are concerned:
%%
%% * sys:install/2,3
%% * sys:log/2,3
%% * sys:log_to_file/2,3
%% * sys:no_debug/1,2
%% * sys:remove/2,3
%% * sys:statistics/2,3
%% * sys:trace/2,3
%% * call debug_options/1
%% * call get_debug/3
%% * call handle_debug/4
%% * call print_log/1

%% supervisor.
%%
%% The connection processes act as supervisors by default
%% so they must handle the supervisor messages.

%% supervisor:count_children/1.

supervisor_count_children_h1(Config) ->
	doc("h1: The function supervisor:count_children/1 must work."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config),
		[{active, false}]),
	timer:sleep(100),
	Pid = do_get_remote_pid_tcp(Socket),
	%% No request was sent so there's no children.
	Counts1 = supervisor:count_children(Pid),
	1 = proplists:get_value(specs, Counts1),
	0 = proplists:get_value(active, Counts1),
	0 = proplists:get_value(supervisors, Counts1),
	0 = proplists:get_value(workers, Counts1),
	%% Send a request, observe that a children exists.
	ok = gen_tcp:send(Socket,
		"GET /loop HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"\r\n"),
	timer:sleep(100),
	Counts2 = supervisor:count_children(Pid),
	1 = proplists:get_value(specs, Counts2),
	1 = proplists:get_value(active, Counts2),
	0 = proplists:get_value(supervisors, Counts2),
	1 = proplists:get_value(workers, Counts2),
	ok.

supervisor_count_children_h2(Config) ->
	doc("h2: The function supervisor:count_children/1 must work."),
	{ok, Socket} = ssl:connect("localhost", config(tls_port, Config),
		[{active, false}, binary, {alpn_advertised_protocols, [<<"h2">>]}]),
	%% Do the handshake.
	ok = ssl:send(Socket, ["PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", cow_http2:settings(#{})]),
	{ok, <<_,_,_,4,_/bits>>} = ssl:recv(Socket, 0, 1000),
	ok = ssl:send(Socket, cow_http2:settings_ack()),
	{ok, << 0:24, 4:8, 1:8, 0:32 >>} = ssl:recv(Socket, 9, 1000),
	timer:sleep(100),
	Pid = do_get_remote_pid_tls(Socket),
	%% No request was sent so there's no children.
	Counts1 = supervisor:count_children(Pid),
	1 = proplists:get_value(specs, Counts1),
	0 = proplists:get_value(active, Counts1),
	0 = proplists:get_value(supervisors, Counts1),
	0 = proplists:get_value(workers, Counts1),
	%% Send a request, observe that a children exists.
	{HeadersBlock, _} = cow_hpack:encode([
		{<<":method">>, <<"GET">>},
		{<<":scheme">>, <<"https">>},
		{<<":authority">>, <<"localhost">>}, %% @todo Correct port number.
		{<<":path">>, <<"/loop">>}
	]),
	ok = ssl:send(Socket, cow_http2:headers(1, fin, HeadersBlock)),
	timer:sleep(100),
	Counts2 = supervisor:count_children(Pid),
	1 = proplists:get_value(specs, Counts2),
	1 = proplists:get_value(active, Counts2),
	0 = proplists:get_value(supervisors, Counts2),
	1 = proplists:get_value(workers, Counts2),
	ok.

supervisor_count_children_ws(Config) ->
	doc("ws: The function supervisor:count_children/1 must work. "
		"Websocket connections never have children."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config),
		[binary, {active, false}]),
	ok = gen_tcp:send(Socket,
		"GET /ws HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"Connection: Upgrade\r\n"
		"Origin: http://localhost\r\n"
		"Sec-WebSocket-Version: 13\r\n"
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
		"Upgrade: websocket\r\n"
		"\r\n"),
	{ok, Handshake} = gen_tcp:recv(Socket, 0, 5000),
	{ok, {http_response, {1, 1}, 101, _}, _} = erlang:decode_packet(http, Handshake, []),
	timer:sleep(100),
	Pid = do_get_remote_pid_tcp(Socket),
	Counts = supervisor:count_children(Pid),
	1 = proplists:get_value(specs, Counts),
	0 = proplists:get_value(active, Counts),
	0 = proplists:get_value(supervisors, Counts),
	0 = proplists:get_value(workers, Counts),
	ok.

%% supervisor:delete_child/2.

supervisor_delete_child_not_found_h1(Config) ->
	doc("h1: The function supervisor:delete_child/2 must return {error, not_found}."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config),
		[{active, false}]),
	timer:sleep(100),
	Pid = do_get_remote_pid_tcp(Socket),
	%% When no children exist.
	{error, not_found} = supervisor:delete_child(Pid, cowboy_http),
	%% When a child exists.
	ok = gen_tcp:send(Socket,
		"GET /loop HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"\r\n"),
	timer:sleep(100),
	{error, not_found} = supervisor:delete_child(Pid, cowboy_http),
	ok.

supervisor_delete_child_not_found_h2(Config) ->
	doc("h2: The function supervisor:delete_child/2 must return {error, not_found}."),
	{ok, Socket} = ssl:connect("localhost", config(tls_port, Config),
		[{active, false}, binary, {alpn_advertised_protocols, [<<"h2">>]}]),
	%% Do the handshake.
	ok = ssl:send(Socket, ["PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", cow_http2:settings(#{})]),
	{ok, <<_,_,_,4,_/bits>>} = ssl:recv(Socket, 0, 1000),
	ok = ssl:send(Socket, cow_http2:settings_ack()),
	{ok, << 0:24, 4:8, 1:8, 0:32 >>} = ssl:recv(Socket, 9, 1000),
	timer:sleep(100),
	Pid = do_get_remote_pid_tls(Socket),
	%% When no children exist.
	{error, not_found} = supervisor:delete_child(Pid, cowboy_http2),
	%% When a child exists.
	{HeadersBlock, _} = cow_hpack:encode([
		{<<":method">>, <<"GET">>},
		{<<":scheme">>, <<"https">>},
		{<<":authority">>, <<"localhost">>}, %% @todo Correct port number.
		{<<":path">>, <<"/loop">>}
	]),
	ok = ssl:send(Socket, cow_http2:headers(1, fin, HeadersBlock)),
	timer:sleep(100),
	{error, not_found} = supervisor:delete_child(Pid, cowboy_http2),
	ok.

supervisor_delete_child_not_found_ws(Config) ->
	doc("ws: The function supervisor:delete_child/2 must return {error, not_found}."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config),
		[binary, {active, false}]),
	ok = gen_tcp:send(Socket,
		"GET /ws HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"Connection: Upgrade\r\n"
		"Origin: http://localhost\r\n"
		"Sec-WebSocket-Version: 13\r\n"
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
		"Upgrade: websocket\r\n"
		"\r\n"),
	{ok, Handshake} = gen_tcp:recv(Socket, 0, 5000),
	{ok, {http_response, {1, 1}, 101, _}, _} = erlang:decode_packet(http, Handshake, []),
	timer:sleep(100),
	Pid = do_get_remote_pid_tcp(Socket),
	{error, not_found} = supervisor:delete_child(Pid, cowboy_websocket),
	ok.

%% supervisor:get_childspec/2.

supervisor_get_childspec_not_found_h1(Config) ->
	doc("h1: The function supervisor:get_childspec/2 must return {error, not_found}."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config),
		[{active, false}]),
	timer:sleep(100),
	Pid = do_get_remote_pid_tcp(Socket),
	%% When no children exist.
	{error, not_found} = supervisor:get_childspec(Pid, cowboy_http),
	%% When a child exists.
	ok = gen_tcp:send(Socket,
		"GET /loop HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"\r\n"),
	timer:sleep(100),
	{error, not_found} = supervisor:get_childspec(Pid, cowboy_http),
	ok.

supervisor_get_childspec_not_found_h2(Config) ->
	doc("h2: The function supervisor:get_childspec/2 must return {error, not_found}."),
	{ok, Socket} = ssl:connect("localhost", config(tls_port, Config),
		[{active, false}, binary, {alpn_advertised_protocols, [<<"h2">>]}]),
	%% Do the handshake.
	ok = ssl:send(Socket, ["PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", cow_http2:settings(#{})]),
	{ok, <<_,_,_,4,_/bits>>} = ssl:recv(Socket, 0, 1000),
	ok = ssl:send(Socket, cow_http2:settings_ack()),
	{ok, << 0:24, 4:8, 1:8, 0:32 >>} = ssl:recv(Socket, 9, 1000),
	timer:sleep(100),
	Pid = do_get_remote_pid_tls(Socket),
	%% When no children exist.
	{error, not_found} = supervisor:get_childspec(Pid, cowboy_http2),
	%% When a child exists.
	{HeadersBlock, _} = cow_hpack:encode([
		{<<":method">>, <<"GET">>},
		{<<":scheme">>, <<"https">>},
		{<<":authority">>, <<"localhost">>}, %% @todo Correct port number.
		{<<":path">>, <<"/loop">>}
	]),
	ok = ssl:send(Socket, cow_http2:headers(1, fin, HeadersBlock)),
	timer:sleep(100),
	{error, not_found} = supervisor:get_childspec(Pid, cowboy_http2),
	ok.

supervisor_get_childspec_not_found_ws(Config) ->
	doc("ws: The function supervisor:get_childspec/2 must return {error, not_found}."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config),
		[binary, {active, false}]),
	ok = gen_tcp:send(Socket,
		"GET /ws HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"Connection: Upgrade\r\n"
		"Origin: http://localhost\r\n"
		"Sec-WebSocket-Version: 13\r\n"
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
		"Upgrade: websocket\r\n"
		"\r\n"),
	{ok, Handshake} = gen_tcp:recv(Socket, 0, 5000),
	{ok, {http_response, {1, 1}, 101, _}, _} = erlang:decode_packet(http, Handshake, []),
	timer:sleep(100),
	Pid = do_get_remote_pid_tcp(Socket),
	{error, not_found} = supervisor:get_childspec(Pid, cowboy_websocket),
	ok.

%% supervisor:restart_child/2.

supervisor_restart_child_not_found_h1(Config) ->
	doc("h1: The function supervisor:restart_child/2 must return {error, not_found}."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config),
		[{active, false}]),
	timer:sleep(100),
	Pid = do_get_remote_pid_tcp(Socket),
	%% When no children exist.
	{error, not_found} = supervisor:restart_child(Pid, cowboy_http),
	%% When a child exists.
	ok = gen_tcp:send(Socket,
		"GET /loop HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"\r\n"),
	timer:sleep(100),
	{error, not_found} = supervisor:restart_child(Pid, cowboy_http),
	ok.

supervisor_restart_child_not_found_h2(Config) ->
	doc("h2: The function supervisor:restart_child/2 must return {error, not_found}."),
	{ok, Socket} = ssl:connect("localhost", config(tls_port, Config),
		[{active, false}, binary, {alpn_advertised_protocols, [<<"h2">>]}]),
	%% Do the handshake.
	ok = ssl:send(Socket, ["PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", cow_http2:settings(#{})]),
	{ok, <<_,_,_,4,_/bits>>} = ssl:recv(Socket, 0, 1000),
	ok = ssl:send(Socket, cow_http2:settings_ack()),
	{ok, << 0:24, 4:8, 1:8, 0:32 >>} = ssl:recv(Socket, 9, 1000),
	timer:sleep(100),
	Pid = do_get_remote_pid_tls(Socket),
	%% When no children exist.
	{error, not_found} = supervisor:restart_child(Pid, cowboy_http2),
	%% When a child exists.
	{HeadersBlock, _} = cow_hpack:encode([
		{<<":method">>, <<"GET">>},
		{<<":scheme">>, <<"https">>},
		{<<":authority">>, <<"localhost">>}, %% @todo Correct port number.
		{<<":path">>, <<"/loop">>}
	]),
	ok = ssl:send(Socket, cow_http2:headers(1, fin, HeadersBlock)),
	timer:sleep(100),
	{error, not_found} = supervisor:restart_child(Pid, cowboy_http2),
	ok.

supervisor_restart_child_not_found_ws(Config) ->
	doc("ws: The function supervisor:restart_child/2 must return {error, not_found}."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config),
		[binary, {active, false}]),
	ok = gen_tcp:send(Socket,
		"GET /ws HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"Connection: Upgrade\r\n"
		"Origin: http://localhost\r\n"
		"Sec-WebSocket-Version: 13\r\n"
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
		"Upgrade: websocket\r\n"
		"\r\n"),
	{ok, Handshake} = gen_tcp:recv(Socket, 0, 5000),
	{ok, {http_response, {1, 1}, 101, _}, _} = erlang:decode_packet(http, Handshake, []),
	timer:sleep(100),
	Pid = do_get_remote_pid_tcp(Socket),
	{error, not_found} = supervisor:restart_child(Pid, cowboy_websocket),
	ok.

%% supervisor:start_child/2 must return {error, start_child_disabled}

supervisor_start_child_not_found_h1(Config) ->
	doc("h1: The function supervisor:start_child/2 must return {error, start_child_disabled}."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config),
		[{active, false}]),
	timer:sleep(100),
	Pid = do_get_remote_pid_tcp(Socket),
	{error, start_child_disabled} = supervisor:start_child(Pid, #{
		id => error,
		start => {error, error, []}
	}),
	ok.

supervisor_start_child_not_found_h2(Config) ->
	doc("h2: The function supervisor:start_child/2 must return {error, start_child_disabled}."),
	{ok, Socket} = ssl:connect("localhost", config(tls_port, Config),
		[{active, false}, binary, {alpn_advertised_protocols, [<<"h2">>]}]),
	%% Do the handshake.
	ok = ssl:send(Socket, ["PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", cow_http2:settings(#{})]),
	{ok, <<_,_,_,4,_/bits>>} = ssl:recv(Socket, 0, 1000),
	ok = ssl:send(Socket, cow_http2:settings_ack()),
	{ok, << 0:24, 4:8, 1:8, 0:32 >>} = ssl:recv(Socket, 9, 1000),
	timer:sleep(100),
	Pid = do_get_remote_pid_tls(Socket),
	{error, start_child_disabled} = supervisor:start_child(Pid, #{
		id => error,
		start => {error, error, []}
	}),
	ok.

supervisor_start_child_not_found_ws(Config) ->
	doc("ws: The function supervisor:start_child/2 must return {error, start_child_disabled}."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config),
		[binary, {active, false}]),
	ok = gen_tcp:send(Socket,
		"GET /ws HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"Connection: Upgrade\r\n"
		"Origin: http://localhost\r\n"
		"Sec-WebSocket-Version: 13\r\n"
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
		"Upgrade: websocket\r\n"
		"\r\n"),
	{ok, Handshake} = gen_tcp:recv(Socket, 0, 5000),
	{ok, {http_response, {1, 1}, 101, _}, _} = erlang:decode_packet(http, Handshake, []),
	timer:sleep(100),
	Pid = do_get_remote_pid_tcp(Socket),
	{error, start_child_disabled} = supervisor:start_child(Pid, #{
		id => error,
		start => {error, error, []}
	}),
	ok.

%% supervisor:terminate_child/2.

supervisor_terminate_child_not_found_h1(Config) ->
	doc("h1: The function supervisor:terminate_child/2 must return {error, not_found}."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config),
		[{active, false}]),
	timer:sleep(100),
	Pid = do_get_remote_pid_tcp(Socket),
	%% When no children exist.
	{error, not_found} = supervisor:terminate_child(Pid, cowboy_http),
	%% When a child exists.
	ok = gen_tcp:send(Socket,
		"GET /loop HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"\r\n"),
	timer:sleep(100),
	{error, not_found} = supervisor:terminate_child(Pid, cowboy_http),
	ok.

supervisor_terminate_child_not_found_h2(Config) ->
	doc("h2: The function supervisor:terminate_child/2 must return {error, not_found}."),
	{ok, Socket} = ssl:connect("localhost", config(tls_port, Config),
		[{active, false}, binary, {alpn_advertised_protocols, [<<"h2">>]}]),
	%% Do the handshake.
	ok = ssl:send(Socket, ["PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", cow_http2:settings(#{})]),
	{ok, <<_,_,_,4,_/bits>>} = ssl:recv(Socket, 0, 1000),
	ok = ssl:send(Socket, cow_http2:settings_ack()),
	{ok, << 0:24, 4:8, 1:8, 0:32 >>} = ssl:recv(Socket, 9, 1000),
	timer:sleep(100),
	Pid = do_get_remote_pid_tls(Socket),
	%% When no children exist.
	{error, not_found} = supervisor:terminate_child(Pid, cowboy_http2),
	%% When a child exists.
	{HeadersBlock, _} = cow_hpack:encode([
		{<<":method">>, <<"GET">>},
		{<<":scheme">>, <<"https">>},
		{<<":authority">>, <<"localhost">>}, %% @todo Correct port number.
		{<<":path">>, <<"/loop">>}
	]),
	ok = ssl:send(Socket, cow_http2:headers(1, fin, HeadersBlock)),
	timer:sleep(100),
	{error, not_found} = supervisor:terminate_child(Pid, cowboy_http2),
	ok.

supervisor_terminate_child_not_found_ws(Config) ->
	doc("ws: The function supervisor:terminate_child/2 must return {error, not_found}."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config),
		[binary, {active, false}]),
	ok = gen_tcp:send(Socket,
		"GET /ws HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"Connection: Upgrade\r\n"
		"Origin: http://localhost\r\n"
		"Sec-WebSocket-Version: 13\r\n"
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
		"Upgrade: websocket\r\n"
		"\r\n"),
	{ok, Handshake} = gen_tcp:recv(Socket, 0, 5000),
	{ok, {http_response, {1, 1}, 101, _}, _} = erlang:decode_packet(http, Handshake, []),
	timer:sleep(100),
	Pid = do_get_remote_pid_tcp(Socket),
	{error, not_found} = supervisor:terminate_child(Pid, cowboy_websocket),
	ok.

%% supervisor:which_children/1.
%%
%% @todo The list of modules returned is probably wrong. This will
%% need to be corrected when get_modules gets implemented.

supervisor_which_children_h1(Config) ->
	doc("h1: The function supervisor:which_children/1 must work."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config),
		[{active, false}]),
	timer:sleep(100),
	Pid = do_get_remote_pid_tcp(Socket),
	%% No request was sent so there's no children.
	[] = supervisor:which_children(Pid),
	%% Send a request, observe that a children exists.
	ok = gen_tcp:send(Socket,
		"GET /loop HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"\r\n"),
	timer:sleep(100),
	[{cowboy_http, Child, worker, [cowboy_http]}] = supervisor:which_children(Pid),
	true = is_pid(Child),
	ok.

supervisor_which_children_h2(Config) ->
	doc("h2: The function supervisor:which_children/1 must work."),
	{ok, Socket} = ssl:connect("localhost", config(tls_port, Config),
		[{active, false}, binary, {alpn_advertised_protocols, [<<"h2">>]}]),
	%% Do the handshake.
	ok = ssl:send(Socket, ["PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", cow_http2:settings(#{})]),
	{ok, <<_,_,_,4,_/bits>>} = ssl:recv(Socket, 0, 1000),
	ok = ssl:send(Socket, cow_http2:settings_ack()),
	{ok, << 0:24, 4:8, 1:8, 0:32 >>} = ssl:recv(Socket, 9, 1000),
	timer:sleep(100),
	Pid = do_get_remote_pid_tls(Socket),
	%% No request was sent so there's no children.
	[] = supervisor:which_children(Pid),
	%% Send a request, observe that a children exists.
	{HeadersBlock, _} = cow_hpack:encode([
		{<<":method">>, <<"GET">>},
		{<<":scheme">>, <<"https">>},
		{<<":authority">>, <<"localhost">>}, %% @todo Correct port number.
		{<<":path">>, <<"/loop">>}
	]),
	ok = ssl:send(Socket, cow_http2:headers(1, fin, HeadersBlock)),
	timer:sleep(100),
	[{cowboy_http2, Child, worker, [cowboy_http2]}] = supervisor:which_children(Pid),
	true = is_pid(Child),
	ok.

supervisor_which_children_ws(Config) ->
	doc("ws: The function supervisor:which_children/1 must work. "
		"Websocket connections never have children."),
	{ok, Socket} = gen_tcp:connect("localhost", config(clear_port, Config),
		[binary, {active, false}]),
	ok = gen_tcp:send(Socket,
		"GET /ws HTTP/1.1\r\n"
		"Host: localhost\r\n"
		"Connection: Upgrade\r\n"
		"Origin: http://localhost\r\n"
		"Sec-WebSocket-Version: 13\r\n"
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
		"Upgrade: websocket\r\n"
		"\r\n"),
	{ok, Handshake} = gen_tcp:recv(Socket, 0, 5000),
	{ok, {http_response, {1, 1}, 101, _}, _} = erlang:decode_packet(http, Handshake, []),
	timer:sleep(100),
	Pid = do_get_remote_pid_tcp(Socket),
	[] = supervisor:which_children(Pid),
	ok.
