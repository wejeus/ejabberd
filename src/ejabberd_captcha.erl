%%%-------------------------------------------------------------------
%%% File    : ejabberd_captcha.erl
%%% Author  : Evgeniy Khramtsov <xramtsov@gmail.com>
%%% Description : CAPTCHA processing.
%%%
%%% Created : 26 Apr 2008 by Evgeniy Khramtsov <xramtsov@gmail.com>
%%%-------------------------------------------------------------------
-module(ejabberd_captcha).

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-export([create_captcha/6, process_reply/1, process/2]).

-include("jlib.hrl").
-include("ejabberd.hrl").
-include("web/ejabberd_http.hrl").

-define(VFIELD(Type, Var, Value),
	{xmlelement, "field", [{"type", Type}, {"var", Var}],
	 [{xmlelement, "value", [], [Value]}]}).

-define(CAPTCHA_BODY(Lang, Room, URL),
	translate:translate(Lang, "Your messages to ") ++ Room
	++ translate:translate(Lang, " are being blocked. To unblock them, visit ")
	++ URL).

-define(CAPTCHA_TEXT(Lang), translate:translate(Lang, "Enter the text you see")).
-define(CAPTCHA_LIFETIME, 120000). % two minutes

-record(state, {}).
-record(captcha, {id, pid, key, tref, args}).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

create_captcha(Id, SID, From, To, Lang, Args)
  when is_list(Id), is_list(Lang), is_list(SID),
       is_record(From, jid), is_record(To, jid) ->
    gen_server:call(?MODULE, {create_captcha, Id, SID, From, To, Lang, Args}).

process_reply({xmlelement, "captcha", _, _} = El) ->
    gen_server:call(?MODULE, {process_reply, El});
process_reply(_) ->
    {error, malformed}.

process(_Handlers, Request) when is_record(Request, request) ->
    gen_server:call(?MODULE, Request).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([]) ->
    mnesia:create_table(captcha,
			[{ram_copies, [node()]},
			 {attributes, record_info(fields, captcha)}]),
    mnesia:add_table_copy(captcha, node(), ram_copies),
    {ok, #state{}}.

handle_call({create_captcha, Id, SID, From, To, Lang, Args}, {Pid, _}, State) ->
    Reply =
	case create_image() of
	    {ok, Type, Key, Image} ->
		B64Image = jlib:encode_base64(binary_to_list(Image)),
		JID = jlib:jid_to_string(From),
		CID = "sha1+" ++ sha:sha(Image) ++ "@bob.xmpp.org",
		Data = {xmlelement, "data",
			[{"xmlns", ?NS_BOB}, {"cid", CID},
			 {"max-age", "0"}, {"type", Type}],
			[{xmlcdata, B64Image}]},
		Captcha =
		    {xmlelement, "captcha", [{"xmlns", ?NS_CAPTCHA}],
		     [{xmlelement, "x", [{"xmlns", ?NS_XDATA}, {"type", "form"}],
		       [?VFIELD("hidden", "FORM_TYPE", {xmlcdata, ?NS_CAPTCHA}),
			?VFIELD("hidden", "from", {xmlcdata, jlib:jid_to_string(To)}),
			?VFIELD("hidden", "challenge", {xmlcdata, Id}),
			?VFIELD("hidden", "sid", {xmlcdata, SID}),
			{xmlelement, "field", [{"var", "ocr"}],
			 [{xmlelement, "media", [{"xmlns", ?NS_MEDIA}],
			   [{xmlelement, "uri", [{"type", Type}],
			     [{xmlcdata, "cid:" ++ CID}]}]}]}]}]},
		Body = {xmlelement, "body", [],
			[{xmlcdata, ?CAPTCHA_BODY(Lang, JID, get_url(Id))}]},
		OOB = {xmlelement, "x", [{"xmlns", ?NS_OOB}],
		       [{xmlelement, "url", [], [{xmlcdata, get_url(Id)}]}]},
		Tref = erlang:send_after(?CAPTCHA_LIFETIME, self(), {remove_id, Id}),
		mnesia:dirty_write(#captcha{id=Id, pid=Pid, key=Key,
					    tref=Tref, args=Args}),
		{ok, [Body, OOB, Captcha, Data]};
	    _Err ->
		error
	end,
    {reply, Reply, State};

handle_call({process_reply, Challenge}, _, State) ->
    Reply = case xml:get_subtag(Challenge, "x") of
		false ->
		    {error, malformed};
		Xdata ->
		    Fields = jlib:parse_xdata_submit(Xdata),
		    [Id | _] = proplists:get_value("challenge", Fields, [none]),
		    [OCR | _] = proplists:get_value("ocr", Fields, [none]),
		    case mnesia:dirty_read(captcha, Id) of
			[#captcha{pid=Pid, args=Args, key=Key, tref=Tref}] ->
			    mnesia:dirty_delete(captcha, Id),
			    erlang:cancel_timer(Tref),
			    if OCR == Key ->
				    Pid ! {captcha_succeed, Args},
				    ok;
			       true ->
				    Pid ! {captcha_failed, Args},
				    {error, bad_match}
			    end;
			_ ->
			    {error, not_found}
		    end
	    end,
    {reply, Reply, State};

handle_call(#request{method='GET', lang=Lang, path=[_, Id]}, _, State) ->
    Reply = case mnesia:dirty_read(captcha, Id) of
		[#captcha{}] ->
		    Form =
			{xmlelement, "div", [{"align", "center"}],
			 [{xmlelement, "form", [{"action", get_url(Id)},
						{"name", "captcha"},
						{"method", "POST"}],
			   [{xmlelement, "img", [{"src", get_url(Id ++ "/image")}], []},
			    {xmlelement, "br", [], []},
			    {xmlcdata, ?CAPTCHA_TEXT(Lang)},
			    {xmlelement, "br", [], []},
			    {xmlelement, "input", [{"type", "text"},
						   {"name", "key"},
						   {"size", "10"}], []},
			    {xmlelement, "br", [], []},
			    {xmlelement, "input", [{"type", "submit"},
						   {"name", "enter"},
						   {"value", "OK"}], []}]}]},
		    ejabberd_web:make_xhtml([Form]);
		_ ->
		    ejabberd_web:error(not_found)
	    end,
    {reply, Reply, State};

handle_call(#request{method='GET', path=[_, Id, "image"]}, _, State) ->
    Reply = case mnesia:dirty_read(captcha, Id) of
		[#captcha{key=Key}] ->
		    case create_image(Key) of
			{ok, Type, _, Img} ->
			    {200,
			     [{"Content-Type", Type},
			      {"Cache-Control", "no-cache"},
			      {"Last-Modified", httpd_util:rfc1123_date()}],
			     Img};
			_ ->
			    ejabberd_web:error(not_found)
		    end;
		_ ->
		    ejabberd_web:error(not_found)
	    end,
    {reply, Reply, State};

handle_call(#request{method='POST', q=Q, path=[_, Id]}, _, State) ->
    Reply = case mnesia:dirty_read(captcha, Id) of
		[#captcha{pid=Pid, args=Args, key=Key, tref=Tref}] ->
		    mnesia:dirty_delete(captcha, Id),
		    erlang:cancel_timer(Tref),
		    Input = proplists:get_value("key", Q, none),
		    if Input == Key ->
			    Pid ! {captcha_succeed, Args},
			    ejabberd_web:make_xhtml([]);
		       true ->
			    Pid ! {captcha_failed, Args},
			    ejabberd_web:error(not_allowed)
		    end;
		_ ->
		    ejabberd_web:error(not_found)
	    end,
    {reply, Reply, State};

handle_call(_Request, _From, State) ->
    {reply, bad_request, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({remove_id, Id}, State) ->
    F = fun() ->
		case mnesia:read(captcha, Id, write) of
		    [#captcha{args=Args, pid=Pid}] ->
			Pid ! {captcha_failed, Args},
			mnesia:delete({captcha, Id});
		    _ ->
			ok
		end
	end,
    mnesia:transaction(F),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
%%--------------------------------------------------------------------
%% Function: create_image() -> {ok, Type, Key, Image} | {error, Reason}
%% Type = "image/png" | "image/jpeg" | "image/gif"
%% Key = string()
%% Image = binary()
%% Reason = atom()
%%--------------------------------------------------------------------
create_image() ->
    %% Six numbers from 1 to 9.
    Key = string:substr(randoms:get_string(), 1, 6),
    create_image(Key).

create_image(Key) ->
    FileName = get_prog_name(),
    Cmd = lists:flatten(io_lib:format("~s ~s", [FileName, Key])),
    case cmd(Cmd) of
	{ok, <<16#89, $P, $N, $G, $\r, $\n, 16#1a, $\n, _/binary>> = Img} ->
	    {ok, "image/png", Key, Img};
	{ok, <<16#ff, 16#d8, _/binary>> = Img} ->
	    {ok, "image/jpeg", Key, Img};
	{ok, <<$G, $I, $F, $8, X, $a, _/binary>> = Img} when X==$7; X==$9 ->
	    {ok, "image/gif", Key, Img};
	{error, Reason} ->
	    ?ERROR_MSG("Failed to process an output from \"~s\": ~p",
		       [Cmd, Reason]),
	    {error, Reason};
	_ ->
	    Reason = malformed_image,
	    ?ERROR_MSG("Failed to process an output from \"~s\": ~p",
		       [Cmd, Reason]),
	    {error, Reason}
    end.

get_prog_name() ->
    case ejabberd_config:get_local_option(captcha_cmd) of
	FileName when is_list(FileName) ->
	    FileName;
	_ ->
	    ""
    end.

get_url(Str) ->
    case ejabberd_config:get_local_option(captcha_host) of
	Host when is_list(Host) ->
	    "http://" ++ Host ++ "/captcha/" ++ Str;
	_ ->
	    "http://" ++ ?MYNAME ++ "/captcha/" ++ Str
    end.

%%--------------------------------------------------------------------
%% Function: cmd(Cmd) -> Data | {error, Reason}
%% Cmd = string()
%% Data = binary()
%% Description: os:cmd/1 replacement
%%--------------------------------------------------------------------
-define(CMD_TIMEOUT, 5000).
-define(MAX_FILE_SIZE, 64*1024).

cmd(Cmd) ->
    Port = open_port({spawn, Cmd}, [stream, eof, binary]),
    TRef = erlang:start_timer(?CMD_TIMEOUT, self(), timeout),
    recv_data(Port, TRef, <<>>).

recv_data(Port, TRef, Buf) ->
    receive
	{Port, {data, Bytes}} ->
	    NewBuf = <<Buf/binary, Bytes/binary>>,
	    if size(NewBuf) > ?MAX_FILE_SIZE ->
		    return(Port, TRef, {error, efbig});
	       true ->
		    recv_data(Port, TRef, NewBuf)
	    end;
	{Port, {data, _}} ->
	    return(Port, TRef, {error, efbig});
	{Port, eof} when Buf /= <<>> ->
	    return(Port, TRef, {ok, Buf});
	{Port, eof} ->
	    return(Port, TRef, {error, enodata});
	{timeout, TRef, _} ->
	    return(Port, TRef, {error, timeout})
    end.

return(Port, TRef, Result) ->
    case erlang:cancel_timer(TRef) of
	false ->
	    receive
		{timeout, TRef, _} ->
		    ok
	    after 0 ->
		    ok
	    end;
	_ ->
	    ok
    end,
    catch port_close(Port),
    Result.