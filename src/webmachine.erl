%% @author Justin Sheehy <justin@basho.com>
%% @author Andy Gross <andy@basho.com>
%% @copyright 2007-2014 Basho Technologies
%%
%%    Licensed under the Apache License, Version 2.0 (the "License");
%%    you may not use this file except in compliance with the License.
%%    You may obtain a copy of the License at
%%
%%        http://www.apache.org/licenses/LICENSE-2.0
%%
%%    Unless required by applicable law or agreed to in writing, software
%%    distributed under the License is distributed on an "AS IS" BASIS,
%%    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%    See the License for the specific language governing permissions and
%%    limitations under the License.

-module(webmachine).
-author('Justin Sheehy <justin@basho.com>').
-author('Andy Gross <andy@basho.com>').
-export([start/0, stop/0]).
-export([new_request/2]).

-include("webmachine_logger.hrl").
-include("wm_reqstate.hrl").
-include("wm_reqdata.hrl").

%% @spec start() -> ok
%% @doc Start the webmachine server.
start() ->
    %%确保所有的文件都被加载到系统中
    webmachine_deps:ensure(),
    ok = ensure_started(crypto),
    ok = ensure_started(webmachine).

ensure_started(App) ->
    case application:start(App) of
        ok ->
            ok;
        {error, {already_started, App}} ->
            ok;
        {error, _} = E ->
            E
    end.

%% @spec stop() -> ok
%% @doc Stop the webmachine server.
stop() ->
    application:stop(webmachine).

%% 处理新的请求
new_request(mochiweb, Request) ->
    %% 得到方法
    Method = Request:get(method),
    %% 得到协议
    Scheme = Request:get(scheme),
    %% 得到版本
    Version = Request:get(version),
    %% 得到重写模块
    {Headers, RawPath} = case application:get_env(webmachine, rewrite_module) of
        {ok, RewriteMod} ->
            %% 如果有重写模块，进行重写
            do_rewrite(RewriteMod,
                       Method,
                       Scheme,
                       Version,
                       Request:get(headers),
                       Request:get(raw_path));
        undefined ->
            %% 否则通过Mochiweb的方法获得请求头和原始的路径
            {Request:get(headers), Request:get(raw_path)}
    end,
    %% 得到请求原始的socket
    Socket = Request:get(socket),
    %% 创建原始的请求
    InitialReqData = wrq:create(Method,Scheme,Version,RawPath,Headers),
    InitialLogData = #wm_log_data{start_time=os:timestamp(),
                                  method=Method,
                                  headers=Headers,
                                  path=RawPath,
                                  version=Version,
                                  response_code=404,
                                  response_length=0},
    %% 创建原始的状态                                  
    InitState = #wm_reqstate{socket=Socket,
                             log_data=InitialLogData,
                             reqdata=InitialReqData},
    InitReq = {webmachine_request,InitState},
    %% 得到对端的信息
    case InitReq:get_peer() of
      {ErrorGetPeer = {error,_}, ErrorGetPeerReqState} ->
        % failed to get peer
        { ErrorGetPeer, webmachine_request:new (ErrorGetPeerReqState) };
      {Peer, _ReqState} ->
        case InitReq:get_sock() of
          {ErrorGetSock = {error,_}, ErrorGetSockReqState} ->
            LogDataWithPeer = InitialLogData#wm_log_data {peer=Peer},
            ReqStateWithSockErr =
              ErrorGetSockReqState#wm_reqstate{log_data=LogDataWithPeer},
            { ErrorGetSock, webmachine_request:new (ReqStateWithSockErr) };
          {Sock, ReqState} ->
            ReqData = wrq:set_sock(Sock, wrq:set_peer(Peer, InitialReqData)),
            LogData =
              InitialLogData#wm_log_data {peer=Peer, sock=Sock},
            webmachine_request:new(ReqState#wm_reqstate{log_data=LogData,
                                                        reqdata=ReqData})
        end
    end.

%% 使用重写模块进行重写
do_rewrite(RewriteMod, Method, Scheme, Version, Headers, RawPath) ->
    case RewriteMod:rewrite(Method, Scheme, Version, Headers, RawPath) of
        %% only raw path has been rewritten (older style rewriting)
        NewPath when is_list(NewPath) -> {Headers, NewPath};

        %% headers and raw path rewritten (new style rewriting)
        {NewHeaders, NewPath} -> {NewHeaders,NewPath}
    end.

%%
%% TEST
%%
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

start_mochiweb() ->
    webmachine_util:ensure_all_started(mochiweb).

start_stop_test() ->
    {Res, Apps} = start_mochiweb(),
    ?assertEqual(ok, Res),
    ?assertEqual(ok, webmachine:start()),
    ?assertEqual(ok, webmachine:stop()),
    [application:stop(App) || App <- Apps],
    ok.

-endif.
