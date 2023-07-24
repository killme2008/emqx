%%--------------------------------------------------------------------
%% Copyright (c) 2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_bridge_iotdb_impl).

-include("emqx_bridge_iotdb.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

%% `emqx_resource' API
-export([
    callback_mode/0,
    on_start/2,
    on_stop/2,
    on_get_status/2,
    on_query/3,
    on_query_async/4
]).

-type config() ::
    #{
        base_url := #{
            scheme := http | https,
            host := iolist(),
            port := inet:port_number(),
            path := _
        },
        connect_timeout := pos_integer(),
        pool_type := random | hash,
        pool_size := pos_integer(),
        request => undefined | map(),
        is_aligned => boolean(),
        iotdb_version => binary(),
        device_id => binary() | undefined,
        atom() => _
    }.

-type state() ::
    #{
        base_path := _,
        base_url := #{
            scheme := http | https,
            host := iolist(),
            port := inet:port_number(),
            path := _
        },
        connect_timeout := pos_integer(),
        pool_type := random | hash,
        pool_size := pos_integer(),
        request => undefined | map(),
        is_aligned => boolean(),
        iotdb_version => binary(),
        device_id => binary() | undefined,
        atom() => _
    }.

-type manager_id() :: binary().

%%-------------------------------------------------------------------------------------
%% `emqx_resource' API
%%-------------------------------------------------------------------------------------
callback_mode() -> async_if_possible.

-spec on_start(manager_id(), config()) -> {ok, state()} | no_return().
on_start(InstanceId, Config) ->
    %% [FIXME] The configuration passed in here is pre-processed and transformed
    %% in emqx_bridge_resource:parse_confs/2.
    case emqx_bridge_http_connector:on_start(InstanceId, Config) of
        {ok, State} ->
            ?SLOG(info, #{
                msg => "iotdb_bridge_started",
                instance_id => InstanceId,
                request => maps:get(request, State, <<>>)
            }),
            ?tp(iotdb_bridge_started, #{instance_id => InstanceId}),
            {ok, maps:merge(Config, State)};
        {error, Reason} ->
            ?SLOG(error, #{
                msg => "failed_to_start_iotdb_bridge",
                instance_id => InstanceId,
                base_url => maps:get(request, Config, <<>>),
                reason => Reason
            }),
            throw(failed_to_start_iotdb_bridge)
    end.

-spec on_stop(manager_id(), state()) -> ok | {error, term()}.
on_stop(InstanceId, State) ->
    ?SLOG(info, #{
        msg => "stopping_iotdb_bridge",
        connector => InstanceId
    }),
    Res = emqx_bridge_http_connector:on_stop(InstanceId, State),
    ?tp(iotdb_bridge_stopped, #{instance_id => InstanceId}),
    Res.

-spec on_get_status(manager_id(), state()) ->
    {connected, state()} | {disconnected, state(), term()}.
on_get_status(InstanceId, State) ->
    emqx_bridge_http_connector:on_get_status(InstanceId, State).

-spec on_query(manager_id(), {send_message, map()}, state()) ->
    {ok, pos_integer(), [term()], term()}
    | {ok, pos_integer(), [term()]}
    | {error, term()}.
on_query(InstanceId, {send_message, Message}, State) ->
    ?tp(iotdb_bridge_on_query, #{instance_id => InstanceId}),
    ?SLOG(debug, #{
        msg => "iotdb_bridge_on_query_called",
        instance_id => InstanceId,
        send_message => Message,
        state => emqx_utils:redact(State)
    }),
    case make_iotdb_insert_request(Message, State) of
        {ok, IoTDBPayload} ->
            handle_response(
                emqx_bridge_http_connector:on_query(
                    InstanceId, {send_message, IoTDBPayload}, State
                )
            );
        Error ->
            Error
    end.

-spec on_query_async(manager_id(), {send_message, map()}, {function(), [term()]}, state()) ->
    {ok, pid()} | {error, empty_request}.
on_query_async(InstanceId, {send_message, Message}, ReplyFunAndArgs0, State) ->
    ?tp(iotdb_bridge_on_query_async, #{instance_id => InstanceId}),
    ?SLOG(debug, #{
        msg => "iotdb_bridge_on_query_async_called",
        instance_id => InstanceId,
        send_message => Message,
        state => emqx_utils:redact(State)
    }),
    case make_iotdb_insert_request(Message, State) of
        {ok, IoTDBPayload} ->
            ReplyFunAndArgs =
                {
                    fun(Result) ->
                        Response = handle_response(Result),
                        emqx_resource:apply_reply_fun(ReplyFunAndArgs0, Response)
                    end,
                    []
                },
            emqx_bridge_http_connector:on_query_async(
                InstanceId, {send_message, IoTDBPayload}, ReplyFunAndArgs, State
            );
        Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% Internal Functions
%%--------------------------------------------------------------------

get_payload(#{payload := Payload}) ->
    Payload;
get_payload(#{<<"payload">> := Payload}) ->
    Payload.

parse_payload(ParsedPayload) when is_map(ParsedPayload) ->
    ParsedPayload;
parse_payload(UnparsedPayload) when is_binary(UnparsedPayload) ->
    emqx_utils_json:decode(UnparsedPayload);
parse_payload(UnparsedPayloads) when is_list(UnparsedPayloads) ->
    lists:map(fun parse_payload/1, UnparsedPayloads).

preproc_data_list(DataList) ->
    lists:foldl(
        fun preproc_data/2,
        [],
        DataList
    ).

preproc_data(
    #{
        <<"measurement">> := Measurement,
        <<"data_type">> := DataType,
        <<"value">> := Value
    } = Data,
    Acc
) ->
    [
        #{
            timestamp => maybe_preproc_tmpl(
                maps:get(<<"timestamp">>, Data, <<"now">>)
            ),
            measurement => emqx_placeholder:preproc_tmpl(Measurement),
            data_type => DataType,
            value => maybe_preproc_tmpl(Value)
        }
        | Acc
    ];
preproc_data(_NoMatch, Acc) ->
    ?SLOG(
        warning,
        #{
            msg => "iotdb_bridge_preproc_data_failed",
            required_fields => ['measurement', 'data_type', 'value'],
            received => _NoMatch
        }
    ),
    Acc.

maybe_preproc_tmpl(Value) when is_binary(Value) ->
    emqx_placeholder:preproc_tmpl(Value);
maybe_preproc_tmpl(Value) ->
    Value.

proc_data(PreProcessedData, Msg) ->
    NowNS = erlang:system_time(nanosecond),
    Nows = #{
        now_ms => erlang:convert_time_unit(NowNS, nanosecond, millisecond),
        now_us => erlang:convert_time_unit(NowNS, nanosecond, microsecond),
        now_ns => NowNS
    },
    lists:map(
        fun(
            #{
                timestamp := TimestampTkn,
                measurement := Measurement,
                data_type := DataType,
                value := ValueTkn
            }
        ) ->
            #{
                timestamp => iot_timestamp(TimestampTkn, Msg, Nows),
                measurement => emqx_placeholder:proc_tmpl(Measurement, Msg),
                data_type => DataType,
                value => proc_value(DataType, ValueTkn, Msg)
            }
        end,
        PreProcessedData
    ).

iot_timestamp(Timestamp, _, _) when is_integer(Timestamp) ->
    Timestamp;
iot_timestamp(TimestampTkn, Msg, Nows) ->
    iot_timestamp(emqx_placeholder:proc_tmpl(TimestampTkn, Msg), Nows).

iot_timestamp(Timestamp, #{now_ms := NowMs}) when
    Timestamp =:= <<"now">>; Timestamp =:= <<"now_ms">>; Timestamp =:= <<>>
->
    NowMs;
iot_timestamp(Timestamp, #{now_us := NowUs}) when Timestamp =:= <<"now_us">> ->
    NowUs;
iot_timestamp(Timestamp, #{now_ns := NowNs}) when Timestamp =:= <<"now_ns">> ->
    NowNs;
iot_timestamp(Timestamp, _) when is_binary(Timestamp) ->
    binary_to_integer(Timestamp).

proc_value(<<"TEXT">>, ValueTkn, Msg) ->
    case emqx_placeholder:proc_tmpl(ValueTkn, Msg) of
        <<"undefined">> -> null;
        Val -> Val
    end;
proc_value(<<"BOOLEAN">>, ValueTkn, Msg) ->
    convert_bool(replace_var(ValueTkn, Msg));
proc_value(Int, ValueTkn, Msg) when Int =:= <<"INT32">>; Int =:= <<"INT64">> ->
    convert_int(replace_var(ValueTkn, Msg));
proc_value(Int, ValueTkn, Msg) when Int =:= <<"FLOAT">>; Int =:= <<"DOUBLE">> ->
    convert_float(replace_var(ValueTkn, Msg)).

replace_var(Tokens, Data) when is_list(Tokens) ->
    [Val] = emqx_placeholder:proc_tmpl(Tokens, Data, #{return => rawlist}),
    Val;
replace_var(Val, _Data) ->
    Val.

convert_bool(B) when is_boolean(B) -> B;
convert_bool(null) -> null;
convert_bool(1) -> true;
convert_bool(0) -> false;
convert_bool(<<"1">>) -> true;
convert_bool(<<"0">>) -> false;
convert_bool(<<"true">>) -> true;
convert_bool(<<"True">>) -> true;
convert_bool(<<"TRUE">>) -> true;
convert_bool(<<"false">>) -> false;
convert_bool(<<"False">>) -> false;
convert_bool(<<"FALSE">>) -> false.

convert_int(Int) when is_integer(Int) -> Int;
convert_int(Float) when is_float(Float) -> floor(Float);
convert_int(Str) when is_binary(Str) ->
    try
        binary_to_integer(Str)
    catch
        _:_ ->
            convert_int(binary_to_float(Str))
    end;
convert_int(undefined) ->
    null.

convert_float(Float) when is_float(Float) -> Float;
convert_float(Int) when is_integer(Int) -> Int * 10 / 10;
convert_float(Str) when is_binary(Str) ->
    try
        binary_to_float(Str)
    catch
        _:_ ->
            convert_float(binary_to_integer(Str))
    end;
convert_float(undefined) ->
    null.

make_iotdb_insert_request(Message, State) ->
    Payloads = to_list(parse_payload(get_payload(Message))),
    IsAligned = maps:get(is_aligned, State, false),
    IotDBVsn = maps:get(iotdb_version, State, ?VSN_1_1_X),
    case {device_id(Message, Payloads, State), preproc_data_list(Payloads)} of
        {undefined, _} ->
            {error, device_id_missing};
        {_, []} ->
            {error, invalid_data};
        {DeviceId, PreProcessedData} ->
            DataList = proc_data(PreProcessedData, Message),
            InitAcc = #{timestamps => [], measurements => [], dtypes => [], values => []},
            Rows = replace_dtypes(aggregate_rows(DataList, InitAcc), IotDBVsn),
            {ok,
                maps:merge(Rows, #{
                    iotdb_field_key(is_aligned, IotDBVsn) => IsAligned,
                    iotdb_field_key(device_id, IotDBVsn) => DeviceId
                })}
    end.

replace_dtypes(Rows0, IotDBVsn) ->
    {Types, Rows} = maps:take(dtypes, Rows0),
    Rows#{iotdb_field_key(data_types, IotDBVsn) => Types}.

aggregate_rows(DataList, InitAcc) ->
    lists:foldr(
        fun(
            #{
                timestamp := Timestamp,
                measurement := Measurement,
                data_type := DataType,
                value := Data
            },
            #{
                timestamps := AccTs,
                measurements := AccM,
                dtypes := AccDt,
                values := AccV
            } = Acc
        ) ->
            Timestamps = [Timestamp | AccTs],
            case index_of(Measurement, AccM) of
                0 ->
                    Acc#{
                        timestamps => Timestamps,
                        values => [pad_value(Data, length(AccTs)) | pad_existing_values(AccV)],
                        measurements => [Measurement | AccM],
                        dtypes => [DataType | AccDt]
                    };
                Index ->
                    Acc#{
                        timestamps => Timestamps,
                        values => insert_value(Index, Data, AccV),
                        measurements => AccM,
                        dtypes => AccDt
                    }
            end
        end,
        InitAcc,
        DataList
    ).

pad_value(Data, N) ->
    [Data | lists:duplicate(N, null)].

pad_existing_values(Values) ->
    [[null | Value] || Value <- Values].

index_of(E, List) ->
    string:str(List, [E]).

insert_value(_Index, _Data, []) ->
    [];
insert_value(1, Data, [Value | Values]) ->
    [[Data | Value] | insert_value(0, Data, Values)];
insert_value(Index, Data, [Value | Values]) ->
    [[null | Value] | insert_value(Index - 1, Data, Values)].

iotdb_field_key(is_aligned, ?VSN_1_1_X) ->
    <<"is_aligned">>;
iotdb_field_key(is_aligned, ?VSN_1_0_X) ->
    <<"is_aligned">>;
iotdb_field_key(is_aligned, ?VSN_0_13_X) ->
    <<"isAligned">>;
iotdb_field_key(device_id, ?VSN_1_1_X) ->
    <<"device">>;
iotdb_field_key(device_id, ?VSN_1_0_X) ->
    <<"device">>;
iotdb_field_key(device_id, ?VSN_0_13_X) ->
    <<"deviceId">>;
iotdb_field_key(data_types, ?VSN_1_1_X) ->
    <<"data_types">>;
iotdb_field_key(data_types, ?VSN_1_0_X) ->
    <<"data_types">>;
iotdb_field_key(data_types, ?VSN_0_13_X) ->
    <<"dataTypes">>.

to_list(List) when is_list(List) -> List;
to_list(Data) -> [Data].

device_id(Message, Payloads, State) ->
    case maps:get(device_id, State, undefined) of
        undefined ->
            %% [FIXME] there could be conflicting device-ids in the Payloads
            maps:get(<<"device_id">>, hd(Payloads), undefined);
        DeviceId ->
            DeviceIdTkn = emqx_placeholder:preproc_tmpl(DeviceId),
            emqx_placeholder:proc_tmpl(DeviceIdTkn, Message)
    end.

handle_response({ok, 200, _Headers, Body} = Resp) ->
    eval_response_body(Body, Resp);
handle_response({ok, 200, Body} = Resp) ->
    eval_response_body(Body, Resp);
handle_response({ok, Code, _Headers, Body}) ->
    {error, #{code => Code, body => Body}};
handle_response({ok, Code, Body}) ->
    {error, #{code => Code, body => Body}};
handle_response({error, _} = Error) ->
    Error.

eval_response_body(Body, Resp) ->
    case emqx_utils_json:decode(Body) of
        #{<<"code">> := 200} -> Resp;
        Reason -> {error, Reason}
    end.
