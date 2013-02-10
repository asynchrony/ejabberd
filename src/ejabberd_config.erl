%%%----------------------------------------------------------------------
%%% File    : ejabberd_config.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Load config file
%%% Created : 14 Dec 2002 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2012   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

-module(ejabberd_config).
-author('alexey@process-one.net').

-export([start/0,
	 add_global_option/2, add_local_option/2,
	 get_global_option/1, get_local_option/1]).
-export([get_vh_by_auth_method/1]).
-export([is_file_readable/1]).

-include("ejabberd.hrl").
-include("ejabberd_config.hrl").
-include_lib("kernel/include/file.hrl").


%% @type macro() = {macro_key(), macro_value()}

%% @type macro_key() = atom().
%% The atom must have all characters in uppercase.

%% @type macro_value() = term().


start() ->
    mnesia:create_table(config,
			[{disc_copies, [node()]},
			 {attributes, record_info(fields, config)}]),
    mnesia:add_table_copy(config, node(), ram_copies),
    mnesia:create_table(local_config,
			[{disc_copies, [node()]},
			 {local_content, true},
			 {attributes, record_info(fields, local_config)}]),
    mnesia:add_table_copy(local_config, node(), ram_copies),
    load_config(),
    %% This start time is used by mod_last:
    add_local_option(node_start, now()),
    ok.

%% @doc Load the ejabberd configuration from node config.
%% It also replaces macros.
%% This function will crash if finds some error in the configuration.
load_config() ->
    {ok, Terms} = application:get_env(config),
    State = lists:foldl(fun search_hosts/2, #state{}, Terms),
    Terms_macros = replace_macros(Terms),
    Res = lists:foldl(fun process_term/2, State, Terms_macros),
    set_opts(Res).

search_hosts(Term, State) ->
    case Term of
	{host, Host} ->
	    if
		State#state.hosts == [] ->
		    add_hosts_to_option([Host], State);
		true ->
		    ?ERROR_MSG("Can't load config file: "
			       "too many hosts definitions", []),
		    exit("too many hosts definitions")
	    end;
	{hosts, Hosts} ->
	    if
		State#state.hosts == [] ->
		    add_hosts_to_option(Hosts, State);
		true ->
		    ?ERROR_MSG("Can't load config file: "
			       "too many hosts definitions", []),
		    exit("too many hosts definitions")
	    end;
	_ ->
	    State
    end.

add_hosts_to_option(Hosts, State) ->
    PrepHosts = normalize_hosts(Hosts),
    add_option(hosts, PrepHosts, State#state{hosts = PrepHosts}).

normalize_hosts(Hosts) ->
    normalize_hosts(Hosts,[]).
normalize_hosts([], PrepHosts) ->
    lists:reverse(PrepHosts);
normalize_hosts([Host|Hosts], PrepHosts) ->
    case jlib:nodeprep(Host) of
	error ->
	    ?ERROR_MSG("Can't load config file: "
		       "invalid host name [~p]", [Host]),
	    exit("invalid hostname");
	PrepHost ->
	    normalize_hosts(Hosts, [PrepHost|PrepHosts])
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Support for Macro

%% @doc Replace the macros with their defined values.
%% @spec (Terms::[term()]) -> [term()]
replace_macros(Terms) ->
    {TermsOthers, Macros} = split_terms_macros(Terms),
    replace(TermsOthers, Macros).

%% @doc Split Terms into normal terms and macro definitions.
%% @spec (Terms) -> {Terms, Macros}
%%       Terms = [term()]
%%       Macros = [macro()]
split_terms_macros(Terms) ->
    lists:foldl(
      fun(Term, {TOs, Ms}) ->
	      case Term of
		  {define_macro, Key, Value} -> 
		      case is_atom(Key) and is_all_uppercase(Key) of
			  true -> 
			      {TOs, Ms++[{Key, Value}]};
			  false -> 
			      exit({macro_not_properly_defined, Term})
		      end;
		  Term ->
		      {TOs ++ [Term], Ms}
	      end
      end,
      {[], []},
      Terms).

%% @doc Recursively replace in Terms macro usages with the defined value.
%% @spec (Terms, Macros) -> Terms
%%       Terms = [term()]
%%       Macros = [macro()]
replace([], _) ->
    [];
replace([Term|Terms], Macros) ->
    [replace_term(Term, Macros) | replace(Terms, Macros)].

replace_term(Key, Macros) when is_atom(Key) ->
    case is_all_uppercase(Key) of
	true ->
	    case proplists:get_value(Key, Macros) of
		undefined -> exit({undefined_macro, Key});
		Value -> Value
	    end;
	false ->
	    Key
    end;
replace_term({use_macro, Key, Value}, Macros) ->
    proplists:get_value(Key, Macros, Value);
replace_term(Term, Macros) when is_list(Term) ->
    replace(Term, Macros);
replace_term(Term, Macros) when is_tuple(Term) ->
    List = tuple_to_list(Term),
    List2 = replace(List, Macros),
    list_to_tuple(List2);
replace_term(Term, _) ->
    Term.

is_all_uppercase(Atom) ->
    String = erlang:atom_to_list(Atom),
    lists:all(fun(C) when C >= $a, C =< $z -> false;
		 (_) -> true
	      end, String).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Process terms

process_term(Term, State) ->
    case Term of
	override_global ->
	    State#state{override_global = true};
	override_local ->
	    State#state{override_local = true};
	override_acls ->
	    State#state{override_acls = true};
	{acl, _ACLName, _ACLData} ->
	    process_host_term(Term, global, State);
	{access, _RuleName, _Rules} ->
	    process_host_term(Term, global, State);
	{shaper, _Name, _Data} ->
	    %%lists:foldl(fun(Host, S) -> process_host_term(Term, Host, S) end,
	    %%    	State, State#state.hosts);
	    process_host_term(Term, global, State);
	{host, _Host} ->
	    State;
	{hosts, _Hosts} ->
	    State;
	{fqdn, HostFQDN} ->
	    ?DEBUG("FQDN set to: ~p", [HostFQDN]),
	    add_option(fqdn, HostFQDN, State);
	{host_config, Host, Terms} ->
	    lists:foldl(fun(T, S) -> process_host_term(T, Host, S) end,
			State, Terms);
	{listen, Listeners} ->
	    Listeners2 =
		lists:map(
		  fun({PortIP, Module, Opts}) ->
			  {Port, IPT, _, _, Proto, OptsClean} =
			      ejabberd_listener:parse_listener_portip(PortIP, Opts),
			  {{Port, IPT, Proto}, Module, OptsClean}
		  end,
		  Listeners),
	    add_option(listen, Listeners2, State);
	{language, Val} ->
	    add_option(language, Val, State);
	{outgoing_s2s_port, Port} ->
	    add_option(outgoing_s2s_port, Port, State);
	{outgoing_s2s_options, Methods, Timeout} ->
	    add_option(outgoing_s2s_options, {Methods, Timeout}, State);
        {s2s_dns_options, PropList} ->
            add_option(s2s_dns_options, PropList, State);
	{s2s_use_starttls, Port} ->
	    add_option(s2s_use_starttls, Port, State);
	{s2s_certfile, CertFile} ->
	    case ejabberd_config:is_file_readable(CertFile) of
		true -> add_option(s2s_certfile, CertFile, State);
		false ->
		    ErrorText = "There is a problem in the configuration: "
			"the specified file is not readable: ",
		    throw({error, ErrorText ++ CertFile})
	    end;
	{domain_certfile, Domain, CertFile} ->
	    case ejabberd_config:is_file_readable(CertFile) of
		true -> add_option({domain_certfile, Domain}, CertFile, State);
		false ->
		    ErrorText = "There is a problem in the configuration: "
			"the specified file is not readable: ",
		    throw({error, ErrorText ++ CertFile})
	    end;
	{node_type, NodeType} ->
	    add_option(node_type, NodeType, State);
	{cluster_nodes, Nodes} ->
	    add_option(cluster_nodes, Nodes, State);
	{domain_balancing, Domain, Balancing} ->
	    add_option({domain_balancing, Domain}, Balancing, State);
	{domain_balancing_component_number, Domain, N} ->
	    add_option({domain_balancing_component_number, Domain}, N, State);
	{watchdog_admins, Admins} ->
	    add_option(watchdog_admins, Admins, State);
	{watchdog_large_heap, LH} ->
	    add_option(watchdog_large_heap, LH, State);
	{registration_timeout, Timeout} ->
	    add_option(registration_timeout, Timeout, State);
	{captcha_cmd, Cmd} ->
	    add_option(captcha_cmd, Cmd, State);
	{captcha_host, Host} ->
	    add_option(captcha_host, Host, State);
        {captcha_limit, Limit} ->
            add_option(captcha_limit, Limit, State);
	{ejabberdctl_access_commands, ACs} ->
	    add_option(ejabberdctl_access_commands, ACs, State);
	{loglevel, Loglevel} ->
	    ejabberd_loglevel:set(Loglevel),
	    State;
	{max_fsm_queue, N} ->
	    add_option(max_fsm_queue, N, State);
	{_Opt, _Val} ->
	    lists:foldl(fun(Host, S) -> process_host_term(Term, Host, S) end,
			State, State#state.hosts)
    end.

process_host_term(Term, Host, State) ->
    case Term of
	{acl, ACLName, ACLData} ->
	    State#state{opts =
			[acl:to_record(Host, ACLName, ACLData) | State#state.opts]};
	{access, RuleName, Rules} ->
	    State#state{opts = [#config{key = {access, RuleName, Host},
					value = Rules} |
				State#state.opts]};
	{shaper, Name, Data} ->
	    State#state{opts = [#config{key = {shaper, Name, Host},
					value = Data} |
				State#state.opts]};
	{host, Host} ->
	    State;
	{hosts, _Hosts} ->
	    State;
	{odbc_server, ODBC_server} ->
	    add_option({odbc_server, Host}, ODBC_server, State);
	{Opt, Val} ->
	    add_option({Opt, Host}, Val, State)
    end.

add_option(Opt, Val, State) ->
    Table = case Opt of
		hosts ->
		    config;
		language ->
		    config;
		_ ->
		    local_config
	    end,
    case Table of
	config ->
	    State#state{opts = [#config{key = Opt, value = Val} |
				State#state.opts]};
	local_config ->
	    case Opt of
		{{add, OptName}, Host} ->
		    State#state{opts = compact({OptName, Host}, Val,
					       State#state.opts, [])};
		_ ->
		    State#state{opts = [#local_config{key = Opt, value = Val} |
					State#state.opts]}
	    end
    end.

compact({OptName, Host} = Opt, Val, [], Os) ->
    ?WARNING_MSG("The option '~p' is defined for the host ~p using host_config "
    "before the global '~p' option. This host_config option may get overwritten.", [OptName, Host, OptName]),
    [#local_config{key = Opt, value = Val}] ++ Os;
%% Traverse the list of the options already parsed
compact(Opt, Val, [O | Os1], Os2) ->
    case catch O#local_config.key of
	%% If the key of a local_config matches the Opt that wants to be added
	Opt ->
	    %% Then prepend the new value to the list of old values
	    Os2 ++ [#local_config{key = Opt,
				  value = Val++O#local_config.value}
		   ] ++ Os1;
	_ ->
	    compact(Opt, Val, Os1, Os2++[O])
    end.


set_opts(State) ->
    Opts = lists:reverse(State#state.opts),
    F = fun() ->
		if
		    State#state.override_global ->
			Ksg = mnesia:all_keys(config),
			lists:foreach(fun(K) ->
					      mnesia:delete({config, K})
				      end, Ksg);
		    true ->
			ok
		end,
		if
		    State#state.override_local ->
			Ksl = mnesia:all_keys(local_config),
			lists:foreach(fun(K) ->
					      mnesia:delete({local_config, K})
				      end, Ksl);
		    true ->
			ok
		end,
		if
		    State#state.override_acls ->
			Ksa = mnesia:all_keys(acl),
			lists:foreach(fun(K) ->
					      mnesia:delete({acl, K})
				      end, Ksa);
		    true ->
			ok
		end,
		lists:foreach(fun(R) ->
				      mnesia:write(R)
			      end, Opts)
	end,
    case mnesia:transaction(F) of
	{atomic, _} -> ok;
	{aborted,{no_exists,Table}} ->
	    MnesiaDirectory = mnesia:system_info(directory),
	    ?ERROR_MSG("Error reading Mnesia database spool files:~n"
		       "The Mnesia database couldn't read the spool file for the table '~p'.~n"
		       "ejabberd needs read and write access in the directory:~n   ~s~n"
		       "Maybe the problem is a change in the computer hostname,~n"
		       "or a change in the Erlang node name, which is currently:~n   ~p~n"
		       "Check the ejabberd guide for details about changing the~n"
		       "computer hostname or Erlang node name.~n",
		       [Table, MnesiaDirectory, node()]),
	    exit("Error reading Mnesia database")
    end.


add_global_option(Opt, Val) ->
    mnesia:transaction(fun() ->
			       mnesia:write(#config{key = Opt,
						    value = Val})
		       end).

add_local_option(Opt, Val) ->
    mnesia:transaction(fun() ->
			       mnesia:write(#local_config{key = Opt,
							  value = Val})
		       end).


get_global_option(Opt) ->
    case ets:lookup(config, Opt) of
	[#config{value = Val}] ->
	    Val;
	_ ->
	    undefined
    end.

get_local_option(Opt) ->
    case ets:lookup(local_config, Opt) of
	[#local_config{value = Val}] ->
	    Val;
	_ ->
	    undefined
    end.

%% Return the list of hosts handled by a given module
get_vh_by_auth_method(AuthMethod) ->
    mnesia:dirty_select(local_config,
			[{#local_config{key = {auth_method, '$1'},
					value=AuthMethod},[],['$1']}]).

%% @spec (Path::string()) -> true | false
is_file_readable(Path) ->
    case file:read_file_info(Path) of
	{ok, FileInfo} ->
	    case {FileInfo#file_info.type, FileInfo#file_info.access} of
		{regular, read} -> true;
		{regular, read_write} -> true;
		_ -> false
	    end;
	{error, _Reason} ->
	    false
    end.
