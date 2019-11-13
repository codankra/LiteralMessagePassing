-module(server).

-export([start_server/0]).

-include_lib("./defs.hrl").

-spec start_server() -> _.
-spec loop(_State) -> _.
-spec do_join(_ChatName, _ClientPID, _Ref, _State) -> _.
-spec do_leave(_ChatName, _ClientPID, _Ref, _State) -> _.
-spec do_new_nick(_State, _Ref, _ClientPID, _NewNick) -> _.
-spec do_client_quit(_State, _Ref, _ClientPID) -> _NewState.

start_server() ->
    catch(unregister(server)),
    register(server, self()),
    case whereis(testsuite) of
	undefined -> ok;
	TestSuitePID -> TestSuitePID!{server_up, self()}
    end,
    loop(
      #serv_st{
	 nicks = maps:new(), %% nickname map. client_pid => "nickname"
	 registrations = maps:new(), %% registration map. "chat_name" => [client_pids]
	 chatrooms = maps:new() %% chatroom map. "chat_name" => chat_pid
	}
     ).

loop(State) ->
    receive 
	%% initial connection
	{ClientPID, connect, ClientNick} ->
	    NewState =
		#serv_st{
		   nicks = maps:put(ClientPID, ClientNick, State#serv_st.nicks),
		   registrations = State#serv_st.registrations,
		   chatrooms = State#serv_st.chatrooms
		  },
	    loop(NewState);
	%% client requests to join a chat
	{ClientPID, Ref, join, ChatName} ->
	    NewState = do_join(ChatName, ClientPID, Ref, State),
	    loop(NewState);
	%% client requests to join a chat
	{ClientPID, Ref, leave, ChatName} ->
	    NewState = do_leave(ChatName, ClientPID, Ref, State),
	    loop(NewState);
	%% client requests to register a new nickname
	{ClientPID, Ref, nick, NewNick} ->
	    NewState = do_new_nick(State, Ref, ClientPID, NewNick),
	    loop(NewState);
	%% client requests to quit
	{ClientPID, Ref, quit} ->
	    NewState = do_client_quit(State, Ref, ClientPID),
	    loop(NewState);
	{TEST_PID, get_state} ->
	    TEST_PID!{get_state, State},
	    loop(State)
    end.

%% executes join protocol from server perspective
do_join(ChatName, ClientPID, Ref, State) ->
	{ChatPID, NewState} = 
	case maps:find(ChatName, State#serv_st.chatrooms) of 
		{ok, EPID} -> 
			{EPID, State};
		error->
			NewChatPID = spawn(chatroom, start_chatroom, [ChatName]),
			Chatroomss = maps:put(ChatName, NewChatPID, State#serv_st.chatrooms),
			Regs = maps:put(ChatName, [], State#serv_st.registrations),
			Nicks = State#serv_st.nicks,
			{NewChatPID, #serv_st{chatrooms = Chatroomss, registrations = Regs, nicks = Nicks}}
	end,
	Clients = maps:get(ChatName, NewState#serv_st.registrations),
	NList = maps:put(ChatName, [ClientPID] ++ [Clients], State#serv_st.registrations),
	UpdateState = #serv_st{chatrooms = NewState#serv_st.chatrooms, registrations = NList, nicks = NewState#serv_st.nicks},
	%  find clientNicks based on nicknames
	ClientNicks = maps:find(ChatName, NewState#serv_st.nicks),
	ChatPID ! {self(), Ref, register, ClientPID, ClientNicks},
	% return newnewstate
	{UpdateState}.


%% executes leave protocol from server perspective
do_leave(ChatName, ClientPID, Ref, State) ->
	% get ChatRoom pid
	ChatPID = maps:get(ChatName, State#serv_st.chatrooms), 
	% rm client from local record of chatroom regist
	NewRegistrationsForChat = lists:remove(ClientPID, maps:get(ChatName, State#serv_st.registrations)),
	NewState = State#serv_st{registrations = maps:put(ChatName, NewRegistrationsForChat, State#serv_st.registrations)},
	% send message 
	ChatPID!{self(), Ref, unregister, ClientPID},
	% send message 2
	ClientPID!{self(), Ref, ack_leave},
    NewState.

%% executes new nickname protocol from server perspective
do_new_nick(State, Ref, ClientPID, NewNick) ->
	AllNickNames = maps:values(State#serv_st.nicks),
	case lists:member(NewNick, AllNickNames) of 
		true -> ClientPID!{self(), Ref, err_nick_used},
				State;
		false -> 
			NewNicks = maps:put(ClientPID, NewNick, State#serv_st.nicks),
			Keys = maps:keys(State#serv_st.registrations),
			lists:foreach(
				fun (Elem) -> 	Val = maps:get(Elem, State#serv_st.registrations),
								case lists:member(ClientPID, Val) of 
									true -> 
										ChatPID = maps:get(Val, State#serv_st.chatrooms), 
										ChatPID!{self(), Ref, update_nick, ClientPID, NewNick};
									false -> 
										do_nothing
								end
							end, 

				Keys),
			NewState = State#serv_st{nicks = NewNicks},
			NewState 
	end.

%% executes client quit protocol from server perspective
do_client_quit(State, Ref, ClientPID) ->
	NewNicks = maps:remove(ClientPID, State#serv_st.nicks),
	lists:foreach(fun (Elem) -> 
				case lists:member(ClientPID, maps:get(Elem, State#serv_st.registrations)) of 
					false -> do_nothing;
					true -> 
						ChatPID = maps:get(Elem, State#serv_st.chatrooms),
						ChatPID!{self(), Ref, unreigster, ClientPID}
					end
				end, 
		maps:keys(State#serv_st.chatrooms)),
	NewReg = maps:map(fun (Key, Val) -> lists:delete(ClientPID, Val) end, State#serv_st.registrations),
	ClientPID!{self(), Ref, ack_quit},
	NewState = State#serv_st{nicks = NewNicks, registrations = NewReg},
	NewState. 
