%%--------------------------------------------------------------------
%% Copyright (c) 2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_oracle).

-behaviour(emqx_resource).

-include_lib("emqx/include/logger.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-define(UNHEALTHY_TARGET_MSG,
    "Oracle table is invalid. Please check if the table exists in Oracle Database."
).

%%====================================================================
%% Exports
%%====================================================================

%% callbacks for behaviour emqx_resource
-export([
    callback_mode/0,
    on_start/2,
    on_stop/2,
    on_query/3,
    on_batch_query/3,
    on_get_status/2
]).

%% callbacks for ecpool
-export([connect/1, prepare_sql_to_conn/3]).

%% Internal exports used to execute code with ecpool worker
-export([
    query/3,
    execute_batch/3,
    do_get_status/1
]).

-export([
    oracle_host_options/0
]).

-define(ORACLE_DEFAULT_PORT, 1521).
-define(SYNC_QUERY_MODE, no_handover).
-define(DEFAULT_POOL_SIZE, 8).
-define(OPT_TIMEOUT, 30000).
-define(MAX_CURSORS, 10).
-define(ORACLE_HOST_OPTIONS, #{
    default_port => ?ORACLE_DEFAULT_PORT
}).

-type prepares() :: #{atom() => binary()}.
-type params_tokens() :: #{atom() => list()}.

-type state() ::
    #{
        pool_name := binary(),
        prepare_sql := prepares(),
        params_tokens := params_tokens(),
        batch_params_tokens := params_tokens()
    }.

% As ecpool is not monitoring the worker's PID when doing a handover_async, the
% request can be lost if worker crashes. Thus, it's better to force requests to
% be sync for now.
callback_mode() -> always_sync.

-spec on_start(binary(), hoconsc:config()) -> {ok, state()} | {error, _}.
on_start(
    InstId,
    #{
        server := Server,
        username := User
    } = Config
) ->
    ?SLOG(info, #{
        msg => "starting_oracle_connector",
        connector => InstId,
        config => emqx_utils:redact(Config)
    }),
    ?tp(oracle_bridge_started, #{instance_id => InstId, config => Config}),
    {ok, _} = application:ensure_all_started(ecpool),
    {ok, _} = application:ensure_all_started(jamdb_oracle),
    jamdb_oracle_conn:set_max_cursors_number(?MAX_CURSORS),

    #{hostname := Host, port := Port} = emqx_schema:parse_server(Server, oracle_host_options()),
    Sid = maps:get(sid, Config, ""),
    ServiceName =
        case maps:get(service_name, Config, undefined) of
            undefined -> undefined;
            ServiceName0 -> emqx_utils_conv:str(ServiceName0)
        end,
    Options = [
        {host, Host},
        {port, Port},
        {user, emqx_utils_conv:str(User)},
        {password, jamdb_secret:wrap(maps:get(password, Config, ""))},
        {sid, emqx_utils_conv:str(Sid)},
        {service_name, ServiceName},
        {pool_size, maps:get(<<"pool_size">>, Config, ?DEFAULT_POOL_SIZE)},
        {timeout, ?OPT_TIMEOUT},
        {app_name, "EMQX Data To Oracle Database Action"}
    ],
    PoolName = InstId,
    Prepares = parse_prepare_sql(Config),
    InitState = #{pool_name => PoolName},
    State = maps:merge(InitState, Prepares),
    case emqx_resource_pool:start(InstId, ?MODULE, Options) of
        ok ->
            {ok, init_prepare(State)};
        {error, Reason} ->
            ?tp(
                oracle_connector_start_failed,
                #{error => Reason}
            ),
            {error, Reason}
    end.

on_stop(InstId, #{pool_name := PoolName}) ->
    ?SLOG(info, #{
        msg => "stopping_oracle_connector",
        connector => InstId
    }),
    ?tp(oracle_bridge_stopped, #{instance_id => InstId}),
    emqx_resource_pool:stop(PoolName).

on_query(InstId, {TypeOrKey, NameOrSQL}, #{pool_name := _PoolName} = State) ->
    on_query(InstId, {TypeOrKey, NameOrSQL, []}, State);
on_query(
    InstId,
    {TypeOrKey, NameOrSQL, Params},
    #{pool_name := PoolName} = State
) ->
    ?SLOG(debug, #{
        msg => "oracle database connector received sql query",
        connector => InstId,
        type => TypeOrKey,
        sql => NameOrSQL,
        state => State
    }),
    Type = query,
    {NameOrSQL2, Data} = proc_sql_params(TypeOrKey, NameOrSQL, Params, State),
    Res = on_sql_query(InstId, PoolName, Type, ?SYNC_QUERY_MODE, NameOrSQL2, Data),
    handle_result(Res).

on_batch_query(
    InstId,
    BatchReq,
    #{pool_name := PoolName, params_tokens := Tokens, prepare_sql := Sts} = State
) ->
    case BatchReq of
        [{Key, _} = Request | _] ->
            BinKey = to_bin(Key),
            case maps:get(BinKey, Tokens, undefined) of
                undefined ->
                    Log = #{
                        connector => InstId,
                        first_request => Request,
                        state => State,
                        msg => "batch prepare not implemented"
                    },
                    ?SLOG(error, Log),
                    {error, {unrecoverable_error, batch_prepare_not_implemented}};
                TokenList ->
                    {_, Datas} = lists:unzip(BatchReq),
                    Datas2 = [emqx_placeholder:proc_sql(TokenList, Data) || Data <- Datas],
                    St = maps:get(BinKey, Sts),
                    case
                        on_sql_query(InstId, PoolName, execute_batch, ?SYNC_QUERY_MODE, St, Datas2)
                    of
                        {ok, Results} ->
                            handle_batch_result(Results, 0);
                        Result ->
                            Result
                    end
            end;
        _ ->
            Log = #{
                connector => InstId,
                request => BatchReq,
                state => State,
                msg => "invalid request"
            },
            ?SLOG(error, Log),
            {error, {unrecoverable_error, invalid_request}}
    end.

proc_sql_params(query, SQLOrKey, Params, _State) ->
    {SQLOrKey, Params};
proc_sql_params(TypeOrKey, SQLOrData, Params, #{
    params_tokens := ParamsTokens, prepare_sql := PrepareSql
}) ->
    Key = to_bin(TypeOrKey),
    case maps:get(Key, ParamsTokens, undefined) of
        undefined ->
            {SQLOrData, Params};
        Tokens ->
            case maps:get(Key, PrepareSql, undefined) of
                undefined ->
                    {SQLOrData, Params};
                Sql ->
                    {Sql, emqx_placeholder:proc_sql(Tokens, SQLOrData)}
            end
    end.

on_sql_query(InstId, PoolName, Type, ApplyMode, NameOrSQL, Data) ->
    case ecpool:pick_and_do(PoolName, {?MODULE, Type, [NameOrSQL, Data]}, ApplyMode) of
        {error, Reason} = Result ->
            ?tp(
                oracle_connector_query_return,
                #{error => Reason}
            ),
            ?SLOG(error, #{
                msg => "oracle database connector do sql query failed",
                connector => InstId,
                type => Type,
                sql => NameOrSQL,
                reason => Reason
            }),
            case Reason of
                ecpool_empty ->
                    {error, {recoverable_error, Reason}};
                _ ->
                    Result
            end;
        Result ->
            ?tp(
                oracle_connector_query_return,
                #{result => Result}
            ),
            Result
    end.

on_get_status(_InstId, #{pool_name := Pool} = State) ->
    case emqx_resource_pool:health_check_workers(Pool, fun ?MODULE:do_get_status/1) of
        true ->
            case do_check_prepares(State) of
                ok ->
                    connected;
                {ok, NState} ->
                    %% return new state with prepared statements
                    {connected, NState};
                {error, {undefined_table, NState}} ->
                    %% return new state indicating that we are connected but the target table is not created
                    {disconnected, NState, {unhealthy_target, ?UNHEALTHY_TARGET_MSG}};
                {error, _Reason} ->
                    %% do not log error, it is logged in prepare_sql_to_conn
                    connecting
            end;
        false ->
            disconnected
    end.

do_get_status(Conn) ->
    ok == element(1, jamdb_oracle:sql_query(Conn, "select 1 from dual")).

do_check_prepares(
    #{
        pool_name := PoolName,
        prepare_sql := #{<<"send_message">> := SQL},
        params_tokens := #{<<"send_message">> := Tokens}
    } = State
) ->
    % it's already connected. Verify if target table still exists
    Workers = [Worker || {_WorkerName, Worker} <- ecpool:workers(PoolName)],
    lists:foldl(
        fun
            (WorkerPid, ok) ->
                case ecpool_worker:client(WorkerPid) of
                    {ok, Conn} ->
                        case check_if_table_exists(Conn, SQL, Tokens) of
                            {error, undefined_table} -> {error, {undefined_table, State}};
                            _ -> ok
                        end;
                    _ ->
                        ok
                end;
            (_, Acc) ->
                Acc
        end,
        ok,
        Workers
    );
do_check_prepares(
    State = #{pool_name := PoolName, prepare_sql := {error, Prepares}, params_tokens := TokensMap}
) ->
    case prepare_sql(Prepares, PoolName, TokensMap) of
        %% remove the error
        {ok, Sts} ->
            {ok, State#{prepare_sql => Sts}};
        {error, undefined_table} ->
            %% indicate the error
            {error, {undefined_table, State#{prepare_sql => {error, Prepares}}}};
        {error, _Reason} = Error ->
            Error
    end.

%% ===================================================================

oracle_host_options() ->
    ?ORACLE_HOST_OPTIONS.

connect(Opts) ->
    jamdb_oracle:start_link(Opts).

sql_query_to_str(SqlQuery) ->
    emqx_utils_conv:str(SqlQuery).

sql_params_to_str(Params) when is_list(Params) ->
    lists:map(
        fun
            (false) -> "0";
            (true) -> "1";
            (Value) -> emqx_utils_conv:str(Value)
        end,
        Params
    ).

query(Conn, SQL, Params) ->
    Ret = jamdb_oracle:sql_query(Conn, {sql_query_to_str(SQL), sql_params_to_str(Params)}),
    ?tp(oracle_query, #{conn => Conn, sql => SQL, params => Params, result => Ret}),
    handle_result(Ret).

execute_batch(Conn, SQL, ParamsList) ->
    ParamsListStr = lists:map(fun sql_params_to_str/1, ParamsList),
    Ret = jamdb_oracle:sql_query(Conn, {batch, sql_query_to_str(SQL), ParamsListStr}),
    ?tp(oracle_batch_query, #{conn => Conn, sql => SQL, params => ParamsList, result => Ret}),
    handle_result(Ret).

parse_prepare_sql(Config) ->
    SQL =
        case maps:get(prepare_statement, Config, undefined) of
            undefined ->
                case maps:get(sql, Config, undefined) of
                    undefined -> #{};
                    Template -> #{<<"send_message">> => Template}
                end;
            Any ->
                Any
        end,
    parse_prepare_sql(maps:to_list(SQL), #{}, #{}).

parse_prepare_sql([{Key, H} | T], Prepares, Tokens) ->
    {PrepareSQL, ParamsTokens} = emqx_placeholder:preproc_sql(H, ':n'),
    parse_prepare_sql(
        T, Prepares#{Key => PrepareSQL}, Tokens#{Key => ParamsTokens}
    );
parse_prepare_sql([], Prepares, Tokens) ->
    #{
        prepare_sql => Prepares,
        params_tokens => Tokens
    }.

init_prepare(State = #{prepare_sql := Prepares, pool_name := PoolName, params_tokens := TokensMap}) ->
    case prepare_sql(Prepares, PoolName, TokensMap) of
        {ok, Sts} ->
            State#{prepare_sql := Sts};
        Error ->
            LogMeta = #{
                msg => <<"Oracle Database init prepare statement failed">>, error => Error
            },
            ?SLOG(error, LogMeta),
            %% mark the prepare_sql as failed
            State#{prepare_sql => {error, Prepares}}
    end.

prepare_sql(Prepares, PoolName, TokensMap) when is_map(Prepares) ->
    prepare_sql(maps:to_list(Prepares), PoolName, TokensMap);
prepare_sql(Prepares, PoolName, TokensMap) ->
    case do_prepare_sql(Prepares, PoolName, TokensMap) of
        {ok, _Sts} = Ok ->
            %% prepare for reconnect
            ecpool:add_reconnect_callback(PoolName, {?MODULE, prepare_sql_to_conn, [Prepares]}),
            Ok;
        Error ->
            Error
    end.

do_prepare_sql(Prepares, PoolName, TokensMap) ->
    do_prepare_sql(ecpool:workers(PoolName), Prepares, PoolName, TokensMap, #{}).

do_prepare_sql([{_Name, Worker} | T], Prepares, PoolName, TokensMap, _LastSts) ->
    {ok, Conn} = ecpool_worker:client(Worker),
    case prepare_sql_to_conn(Conn, Prepares, TokensMap) of
        {ok, Sts} ->
            do_prepare_sql(T, Prepares, PoolName, TokensMap, Sts);
        Error ->
            Error
    end;
do_prepare_sql([], _Prepares, _PoolName, _TokensMap, LastSts) ->
    {ok, LastSts}.

prepare_sql_to_conn(Conn, Prepares, TokensMap) ->
    prepare_sql_to_conn(Conn, Prepares, TokensMap, #{}).

prepare_sql_to_conn(Conn, [], _TokensMap, Statements) when is_pid(Conn) -> {ok, Statements};
prepare_sql_to_conn(Conn, [{Key, SQL} | PrepareList], TokensMap, Statements) when is_pid(Conn) ->
    LogMeta = #{msg => "Oracle Database Prepare Statement", name => Key, prepare_sql => SQL},
    Tokens = maps:get(Key, TokensMap, []),
    ?SLOG(info, LogMeta),
    case check_if_table_exists(Conn, SQL, Tokens) of
        ok ->
            ?SLOG(info, LogMeta#{result => success}),
            prepare_sql_to_conn(Conn, PrepareList, TokensMap, Statements#{Key => SQL});
        {error, undefined_table} = Error ->
            %% Target table is not created
            ?SLOG(error, LogMeta#{result => failed, reason => "table does not exist"}),
            ?tp(oracle_undefined_table, #{}),
            Error;
        Error ->
            Error
    end.

check_if_table_exists(Conn, SQL, Tokens0) ->
    % Discard nested tokens for checking if table exist. As payload here is defined as
    % a single string, it would fail if Token is, for instance, ${payload.msg}, causing
    % bridge probe to fail.
    Tokens = lists:map(
        fun
            ({var, [Token | _DiscardedDeepTokens]}) ->
                {var, [Token]};
            (Token) ->
                Token
        end,
        Tokens0
    ),
    {Event, _Headers} = emqx_rule_events:eventmsg_publish(
        emqx_message:make(<<"t/opic">>, "test query")
    ),
    SqlQuery = "begin " ++ binary_to_list(SQL) ++ "; rollback; end;",
    Params = emqx_placeholder:proc_sql(Tokens, Event),
    case jamdb_oracle:sql_query(Conn, {SqlQuery, Params}) of
        {ok, [{proc_result, 0, _Description}]} ->
            ok;
        {ok, [{proc_result, 6550, _Description}]} ->
            %% Target table is not created
            {error, undefined_table};
        Reason ->
            {error, Reason}
    end.

to_bin(Bin) when is_binary(Bin) ->
    Bin;
to_bin(Atom) when is_atom(Atom) ->
    erlang:atom_to_binary(Atom).

handle_result({error, {recoverable_error, _Error}} = Res) ->
    Res;
handle_result({error, {unrecoverable_error, _Error}} = Res) ->
    Res;
handle_result({error, disconnected}) ->
    {error, {recoverable_error, disconnected}};
handle_result({error, Error}) ->
    {error, {unrecoverable_error, Error}};
handle_result({error, socket, closed} = Error) ->
    {error, {recoverable_error, Error}};
handle_result({error, Type, Reason}) ->
    {error, {unrecoverable_error, {Type, Reason}}};
handle_result({ok, [{proc_result, RetCode, Reason}]}) when RetCode =/= 0 ->
    {error, {unrecoverable_error, {RetCode, Reason}}};
handle_result(Res) ->
    Res.

handle_batch_result([{affected_rows, RowCount} | Rest], Acc) ->
    handle_batch_result(Rest, Acc + RowCount);
handle_batch_result([{proc_result, RetCode, _Rows} | Rest], Acc) when RetCode =:= 0 ->
    handle_batch_result(Rest, Acc);
handle_batch_result([{proc_result, RetCode, Reason} | _Rest], _Acc) ->
    {error, {unrecoverable_error, {RetCode, Reason}}};
handle_batch_result([], Acc) ->
    {ok, Acc}.
