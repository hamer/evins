%% Copyright (c) 2015, Oleksiy Kebkal <lesha@evologics.de>
%% 
%% Redistribution and use in source and binary forms, with or without 
%% modification, are permitted provided that the following conditions 
%% are met: 
%% 1. Redistributions of source code must retain the above copyright 
%%    notice, this list of conditions and the following disclaimer. 
%% 2. Redistributions in binary form must reproduce the above copyright 
%%    notice, this list of conditions and the following disclaimer in the 
%%    documentation and/or other materials provided with the distribution. 
%% 3. The name of the author may not be used to endorse or promote products 
%%    derived from this software without specific prior written permission. 
%% 
%% Alternatively, this software may be distributed under the terms of the 
%% GNU General Public License ("GPL") version 2 as published by the Free 
%% Software Foundation. 
%% 
%% THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR 
%% IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES 
%% OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. 
%% IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, 
%% INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT 
%% NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, 
%% DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY 
%% THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT 
%% (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF 
%% THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. 
-module(role_at).
-behaviour(role_worker).
-export([start/3, stop/1, to_term/3, from_term/2, ctrl/2]).

-include("fsm.hrl").

%% -record(config, {filter,mode,waitsync,request,telegram,eol,ext_networking,pid}).

stop(_) -> ok.

start(Role_ID, Mod_ID, MM) ->
  EOL = case lists:keyfind(eol,1,MM#mm.params) of
          {eol,Other} -> Other;
          _ -> "\n"
        end,
  Filter = case lists:keyfind(filter,1,MM#mm.params) of
             {filter,F} -> F;
             _ -> at
           end,
  Allow = case lists:keyfind(allow,1,MM#mm.params) of
            {allow,A} -> A;
            _ -> nobody
          end,
  Ext = case lists:keyfind(ext_networking,1,MM#mm.params) of
          {ext_networking,E} -> E;
          _ -> no
        end,
  Cfg = #{filter => Filter, mode => data, waitsync => no, request => "",
          telegram => "", eol => EOL, ext_networking => Ext, pid => 0,
          allow => Allow},
  role_worker:start(?MODULE, Role_ID, Mod_ID, MM, Cfg).

ctrl({filter, F}, Cfg)         -> Cfg#{filter => F};
ctrl({mode, M}, Cfg)           -> Cfg#{mode => M};
ctrl({waitsync, W}, Cfg)       -> Cfg#{waitsync => W};
ctrl({eol, E}, Cfg)            -> Cfg#{eol => E};
ctrl({ext_networking, N}, Cfg) -> Cfg#{ext_networking => N};
ctrl({pid, P}, Cfg)            -> Cfg#{pid => P};
ctrl({allow, A}, Cfg)          -> Cfg#{allow => A}.

%% Data stream from the modem may contain:
%% - binary data in async: RECV*
%% - binary data in sync: NOISE
%% - multiline sync answers (end of sync: \r\n\r\n)
%%
%% ASYNC:
%% RECV* SEND* BITRATE* SRCLEVEL* PHY* USBL*
%% DELIVERED* FAILED* CANCELED* EXPIRED*
%% RECVFAILED
%%
%% Config:
%% {filter,at|net,mode,command|data,waitsync,no|singleline|multiline|binary,request,Request,eol,EOL}
%%   
%% [TermList, ErrorList, Bin, More] = to_term(More, Chunk, Config)
%%
%% INPUT
%% More - binary with BES start
%% Chunk - next portion of binary data
%%
%% OUTPUT: [TermList, ErrorList, Bin, More]
%% TermList - list of {sync,Req,Sync} | {async,{pid,Pid},Rcv} | {async,Async}
%%  Sync = "string" | {noise,Len,i1,i2,i3,<<data[Len]>>} | {error, Reason} | {busy, Reason}
%%  Asyn = {recvstart} | {recvend,*} | {sendstart,*} | {sendend,*} | {recv,*} | {recvim,*}
%%         | {recvims,*} | {recvpbm,*} | {phyofF} | {phyon} | {usbllong,*} | {usblangles,*}
%%         | {usblphyp,*} | {usblphyd,*}
%% ErrorList - list of {error,Reason}
%% Bin - data, not containing BES <<data>>
%% More - not full data <<data>>
%%
%% Reason = {besParseError,<<B>>} | {parseError, Async, <<B>>} | {error, {binaryParseError, Recv, <<B>>}
%%          | {unexpectedSync, <<B>>} | {besUnexpectedSync,RRecv,RSent,<<B>>} | {error, {wrongAsync, <<B>>}
%%          | {wrongBinarySync, <<B>>}
to_term(More, Chunk, #{filter := at, mode := data, waitsync := Wait, request := Request, pid := Pid} = Cfg) ->
  BESs = bes_split(binary_to_list(More) ++ Chunk),
  [TermList, ErrorList, BinList, MoreList, _] = 
    lists:foldl(fun(Elem, [TermList, ErrorList, BinList, MoreList, Wait1]) ->
                    case Elem of
                      {raw, BinElem}             -> [TermList, ErrorList, [BinElem|BinList], MoreList, Wait1];
                      {more, MoreElem}           -> [TermList, ErrorList, BinList, [MoreElem|MoreList], Wait1];
                      {bes, BESHead, _, BESBody} -> 
                        FBody = list_to_binary([BESBody,"\r\n"]),
                        [_,BReq] = re:split(BESHead,"\\\+{3}AT"),
                        Req = binary_to_list(BReq),
                        {W, RunSplit} = case {Req,Request,Wait1} of
                                          {_,_,no}    -> {no, true};
                                          {"",_,_}    -> {Wait1, true};
                                          {Req,Req,_} -> {Wait1, true};
                                          _           -> {Wait1, false}
                                        end,
                        case RunSplit of
                          true ->
                            [H|_] = answer_split(FBody,W,Req,Pid),
                            case H of
                              {error,_} -> [TermList, [H|ErrorList], BinList, MoreList, Wait1];
                              {more,_} ->
                                E = {error,{besParseError,FBody}},
                                [TermList, [E|ErrorList], BinList, MoreList, Wait1];
                              {sync,_,_} -> [[H|TermList], ErrorList, BinList, MoreList, no];
                              {async,_,_} -> [[H|TermList], ErrorList, BinList, MoreList, Wait1];
                              {async,_} -> [[H|TermList], ErrorList, BinList, MoreList, Wait1]
                            end;
                          _ -> 
                            E = {error,{besUnexpectedSync,Req,Request,FBody}},
                            [TermList, [E|ErrorList], BinList, MoreList, Wait1]
                        end
                    end
                end, [[],[],[],[],Wait], BESs),
  NewCfg = update_cfg(Cfg, TermList),
  %% io:format("TermList: ~p~n",[TermList]),
  [lists:reverse(TermList), ErrorList, list_to_binary(lists:reverse(BinList)), list_to_binary(MoreList), NewCfg];

to_term(More, Chunk, #{waitsync := Wait, request := Request, pid := Pid} = Cfg) ->
  Answers = answer_split(list_to_binary([More,Chunk]),Wait,Request,Pid),
  [TermList, ErrorList, MoreList] = 
    lists:foldr(fun(Elem, [TermList, ErrorList, MoreList]) ->
                    case Elem of
                      {sync, _, _} ->
                        [[Elem | TermList], ErrorList, MoreList];
                      {async, _, _} ->
                        [[Elem | TermList], ErrorList, MoreList];
                      {async, _} ->
                        [[Elem | TermList], ErrorList, MoreList];
                      {more, <<>>} ->
                        [TermList, ErrorList, MoreList];
                      {more, MoreElem} -> 
                        [TermList, ErrorList, [MoreElem|MoreList]];
                      {error, _} ->
                        [TermList, [Elem|ErrorList], MoreList]
                    end
                end, [[],[],[]], Answers),
  NewCfg = update_cfg(Cfg, TermList),
  [TermList, ErrorList, [], list_to_binary(MoreList), NewCfg].

update_cfg(Cfg, TermList) ->
  lists:foldl(fun(Term, LCfg) ->
                  WCfg = case Term of
                           {sync, _, _} -> LCfg#{waitsync => no};
                           _ -> LCfg
                         end,
                  try
                    #{telegram := Telegram} = WCfg,
                    case {Term, Telegram} of
                      {{sync, "?ZF", "1"}, _} -> WCfg#{ext_networking => yes};
                      {{sync, "?ZF", "0"}, _} -> WCfg#{ext_networking => no};
                      {{sync, "@ZF", "OK"}, "AT@ZF1"} -> WCfg#{ext_networking => yes};
                      {{sync, "@ZF", "OK"}, "AT@ZF0"} -> WCfg#{ext_networking => no};
                      {{sync, "?PID", L}, _} -> WCfg#{pid => list_to_integer(L)};
                      {{sync, "!ZS", "OK"}, Telegram} -> WCfg#{pid => list_to_integer(lists:nthtail(5, Telegram))};
                      _ -> WCfg
                    end
                  catch E:R:Stk ->
                                 logger:warning("role at~nerror caught: ~p:~p~nstack_trace: ~p",
                                                [E, R, Stk]),
                                 WCfg
                  end
              end, Cfg, TermList).

answer_split(L,Wait,Request,Pid) ->
  case re:run(L,"\r\n") of
    {match, [{_Offset, _}]} ->
      case re:run(L,"^(RECV(|PBM|IM|IMS|JRP),)(p(\\d+),(\\d+)|(\\d+))(,.*)",[dotall,{capture,[1,2,3,4,5,6,7],binary}]) of
        {match, [Recv,_,_,BPid,BLen,<<>>,Tail]} ->
          recv_extract(L,Recv,binary_to_integer(BLen),Tail,Wait,Request,binary_to_integer(BPid));
        {match, [Recv,_,_,<<>>,<<>>,BLen,Tail]} ->
          recv_extract(L,Recv,binary_to_integer(BLen),Tail,Wait,Request,Pid);
        nomatch ->
          case re:run(L,"^(RECVPROBE,|RECVSTART|RECVEND,|RECVFAILED,|RECVSRV,|SEND[^,]*,|BITRATE,|RADDR,|SRCLEVEL,|PHYON|PHYOFF|USBL[^,]*,"
                      "|ECLK,|RTO,|DROPCNT,|DELIVERED|FAILED|EXPIRED|CANCELED|STATUS,|%)(.*?)\r\n(.*)",[dotall,{capture,[1,2,3],binary}]) of
            {match, [<<"RECVPROBE,">>,P,L1]} -> [recvprobe_extract(P)  | answer_split(L1,Wait,Request,Pid)];
            {match, [<<"RECVSTART">>,<<>>,L1]} -> [{async, {recvstart}}  | answer_split(L1,Wait,Request,Pid)];
            {match, [<<"RECVEND,">>,P,L1]}     -> [recvend_extract(P)    | answer_split(L1,Wait,Request,Pid)];
            {match, [<<"RECVFAILED,">>,P,L1]}  -> [recvfailed_extract(P) | answer_split(L1,Wait,Request,Pid)];
            {match, [<<"RECVSRV,">>,P,L1]}     -> [recvsrv_extract(P) | answer_split(L1,Wait,Request,Pid)];
            {match, [<<"PHYOFF">>,<<>>,L1]}    -> [{async, {phyoff}}     | answer_split(L1,Wait,Request,Pid)];
            {match, [<<"PHYON">>,<<>>,L1]}     -> [{async, {phyon}}      | answer_split(L1,Wait,Request,Pid)];
            {match, [<<"SENDSTART,">>,P,L1]}   -> [sendstart_extract(P)  | answer_split(L1,Wait,Request,Pid)];
            {match, [<<"SENDEND,">>,P,L1]}     -> [sendend_extract(P)    | answer_split(L1,Wait,Request,Pid)];
            {match, [<<"USBLLONG,">>,P,L1]}    -> [usbllong_extract(P)   | answer_split(L1,Wait,Request,Pid)];
            {match, [<<"USBLANGLES,">>,P,L1]}  -> [usblangles_extract(P) | answer_split(L1,Wait,Request,Pid)];
            {match, [<<"USBLPHYD,">>,P,L1]}    -> [usblphyd_extract(P)   | answer_split(L1,Wait,Request,Pid)];
            {match, [<<"USBLPHYP,">>,P,L1]}    -> [usblphyp_extract(P)   | answer_split(L1,Wait,Request,Pid)];
            {match, [<<"BITRATE,">>,P,L1]}     -> [bitrate_extract(P)    | answer_split(L1,Wait,Request,Pid)];
            {match, [<<"RADDR,">>,P,L1]}       -> [raddr_extract(P)      | answer_split(L1,Wait,Request,Pid)];
            {match, [<<"DELIVERED">>,P,L1]}    -> [delivered_extract(P)  | answer_split(L1,Wait,Request,Pid)];
            {match, [<<"FAILED">>,P,L1]}       -> [failed_extract(P)     | answer_split(L1,Wait,Request,Pid)];
            {match, [<<"CANCELED">>,P,L1]}     -> [canceled_extract(P)   | answer_split(L1,Wait,Request,Pid)];
            {match, [<<"EXPIRED">>,P,L1]}      -> [expired_extract(P)    | answer_split(L1,Wait,Request,Pid)];
            {match, [<<"SRCLEVEL,">>,P,L1]}    -> [srclevel_extract(P)   | answer_split(L1,Wait,Request,Pid)];
            {match, [<<"DROPCNT,">>,P,L1]}     -> [dropcnt_extract(P)    | answer_split(L1,Wait,Request,Pid)];
            {match, [<<"ECLK,">>,P,L1]}        -> [eclk_extract(P)       | answer_split(L1,Wait,Request,Pid)];
            {match, [<<"RTO,">>,P,L1]}         -> [rto_extract(P)        | answer_split(L1,Wait,Request,Pid)];
            {match, [<<"STATUS,">>,P,L1]}      -> [status_extract(P)     | answer_split(L1,Wait,Request,Pid)];
            {match, [<<"%">>,P,L1]}            -> [extended_extract(P)   | answer_split(L1,Wait,Request,Pid)];
            {match, [H, P, L1]}                -> [{error, {wrongAsync, binary_to_list(list_to_binary([H, P]))}} | answer_split(L1,Wait,Request,Pid)];
            nomatch ->
              case re:run(L,"^(ERROR|BUSY) (.*?)\r\n(.*)",[dotall,{capture,[1,2,3],binary}]) of
                {match, [<<"ERROR">>,Reason,L1]} when Reason == <<"EFAULT">>; Reason == <<"OVERLOAD">> -> 
                  [{async, {error, binary_to_list(Reason)}} | answer_split(L1,Wait,Request,Pid)];
                {match, [<<"ERROR">>,Reason,L1]} -> 
                  [{sync, Request, {error, binary_to_list(Reason)}} | answer_split(L1,no,"",Pid)];
                {match, [<<"BUSY">>,Reason,L1]} ->
                  [{sync, Request, {busy, binary_to_list(Reason)}} | answer_split(L1,no,"",Pid)];
                nomatch ->
                  %% the rest is sync answer, may be not yet full one
                  case Wait of
                    binary ->
                      %% NOISE,len,i1,i2,i3,data[len]\r\n
                      case re:run(L,"^NOISE,(\\d+),(\\d+),(\\d+),(-?\\d+),(.*)",[dotall,{capture,[1,2,3,4,5],binary}]) of
                        {match, [Blen,Bi1,Bi2,Bi3,Tail]} -> 
                          Len = binary_to_integer(Blen),
                          TLen = byte_size(Tail),
                          if
                            Len + 2 =< TLen ->
                              case re:run(Tail, "^(.{" ++ integer_to_list(Len) ++ "})\r\n(.*)",[dotall,{capture,[1,2],binary}]) of
                                {match, [Payload, Tail1]} ->
                                  [I1,I2,I3] = [binary_to_integer(X) || X <- [Bi1,Bi2,Bi3]], 
                                  [{sync, Request, {noise,Len,I1,I2,I3,Payload}} | answer_split(Tail1,no,"",Pid)];
                                nomatch ->
                                  [{error, {wrongBinarySync, L}}]
                              end;
                            true ->
                              [{more, L}]
                          end;
                        nomatch ->
                          [{error, {wrongBinarySync, L}}]
                      end;
                    singleline ->
                      [Sync,L1] = re:split(L,"\r\n",[{parts,2}]),
                      [{sync, Request, binary_to_list(Sync)} | answer_split(L1,no,"",Pid)];
                    multiline ->
                      case re:split(L,"\n\r\n",[{parts,2}]) of
                        [Sync,L1] -> [{sync, Request, binary_to_list(Sync) ++ "\n"} | answer_split(L1,no,"",Pid)];
                        _ -> [{more, L}]
                      end;
                    no when byte_size(L) > 0 ->
                      [{error, {unexpectedSync, binary_to_list(L)}}];
                    _ ->
                      []
                  end
              end
          end
      end;
    nomatch ->
      [{more, L}]
  end.

%% DELIVERED,cnt,dst
%% DELIVEREDIM,dst
delivered_extract(P) ->
  case re:split(P,",") of
    [<<>>,Bcnt,Bdst] ->
      {async, {delivered, binary_to_integer(Bcnt), binary_to_integer(Bdst)}};
    [<<"IM">>,Bdst] ->
      {async, {deliveredim, binary_to_integer(Bdst)}}
  end.

%% FAILED,cnt,dsp 
%% FAILEDIM,dst
failed_extract(P) ->
  case re:split(P,",") of
    [<<>>,Bcnt,Bdst] ->
      {async, {failed, binary_to_integer(Bcnt), binary_to_integer(Bdst)}};
    [<<"IM">>,Bdst] ->
      {async, {failedim, binary_to_integer(Bdst)}}
  end.

%% CANCELEDIM,dst
%% CANCELEDIMS,dst
%% CANCELEDPBM,dst
canceled_extract(P) ->
  case re:split(P,",") of
    [<<"IM">>,Bdst] ->
      {async, {canceledim, binary_to_integer(Bdst)}};
    [<<"IMS">>,Bdst] ->
      {async, {canceledims, binary_to_integer(Bdst)}};
    [<<"PBM">>,Bdst] ->
      {async, {canceledpbm, binary_to_integer(Bdst)}}
  end.

%% EXPIREDIMS,dst
expired_extract(P) ->
  case re:split(P,",") of
    [<<"IMS">>,Bdst] ->
      {async, {expiredims, binary_to_integer(Bdst)}}
  end.

%% USBLLONG,f1,f2,i1,f3,f4,f5,f6,f7,f8,f9,f10,f11,i2,i3,i4,f12
usbllong_extract(P) ->
  try
    [Bf1,Bf2,Bi1,Bf3,Bf4,Bf5,Bf6,Bf7,Bf8,Bf9,Bf10,Bf11,Bi2,Bi3,Bi4,Bf12] = re:split(P,","),
    [F1,F2,F3,F4,F5,F6,F7,F8,F9,F10,F11,F12] = [binary_to_float(X) || X <- [Bf1,Bf2,Bf3,Bf4,Bf5,Bf6,Bf7,Bf8,Bf9,Bf10,Bf11,Bf12]],
    [I1,I2,I3,I4] = [binary_to_integer(X) || X <- [Bi1,Bi2,Bi3,Bi4]],
    {async,{usbllong,F1,F2,I1,F3,F4,F5,F6,F7,F8,F9,F10,F11,I2,I3,I4,F12}}
  catch
    error:_ -> {error, {parseError, usbllong, binary_to_list(P)}}
  end.

%% USBLANGLES,f1,f2,i1,f3,f4,f5,f6,f7,f8,f9,i2,i3,f10
usblangles_extract(P) ->
  try
    [Bf1,Bf2,Bi1,Bf3,Bf4,Bf5,Bf6,Bf7,Bf8,Bf9,Bi2,Bi3,Bf10] = re:split(P,","),
    [F1,F2,F3,F4,F5,F6,F7,F8,F9,F10] = [binary_to_float(X) || X <- [Bf1,Bf2,Bf3,Bf4,Bf5,Bf6,Bf7,Bf8,Bf9,Bf10]],
    [I1,I2,I3] = [binary_to_integer(X) || X <- [Bi1,Bi2,Bi3]],
    {async,{usblangles,F1,F2,I1,F3,F4,F5,F6,F7,F8,F9,I2,I3,F10}}
  catch
    error:_ -> {error, {parseError, usblangles, binary_to_list(P)}}
  end.

%% USBLPHYD,f1,f2,i1,i2,i3,i4,i5,i6,i7,i8,i9,i10
usblphyd_extract(P) ->
  try
    [Bf1,Bf2,Bi1,Bi2,Bi3,Bi4,Bi5,Bi6,Bi7,Bi8,Bi9,Bi10] = re:split(P,","),
    [F1,F2] = [binary_to_float(X) || X <- [Bf1,Bf2]],
    [I1,I2,I3,I4,I5,I6,I7,I8,I9,I10] = [binary_to_integer(X) || X <- [Bi1,Bi2,Bi3,Bi4,Bi5,Bi6,Bi7,Bi8,Bi9,Bi10]],
    {async,{usblphyd,F1,F2,I1,I2,I3,I4,I5,I6,I7,I8,I9,I10}}
  catch
    error:_ -> {error, {parseError, usblphyd, binary_to_list(P)}}
  end.

%% USBLPHYP,f1,f2,i1,i2,f3,f4,f5,f6,f7,f8,f9,f10,f11,f12,f13,f14,f15,f16,f17,f18,f19,f20
usblphyp_extract(P) ->
  try
    [Bf1,Bf2,Bi1,Bi2,Bf3,Bf4,Bf5,Bf6,Bf7,Bf8,Bf9,Bf10,Bf11,Bf12,Bf13,Bf14,Bf15,Bf16,Bf17,Bf18,Bf19,Bf20] = re:split(P,","),
    [F1,F2,F3,F4,F5,F6,F7,F8,F9,F10,F11,F12,F13,F14,F15,F16,F17,F18,F19,F20] =
      [binary_to_float(X) || X <- [Bf1,Bf2,Bf3,Bf4,Bf5,Bf6,Bf7,Bf8,Bf9,Bf10,Bf11,Bf12,Bf13,Bf14,Bf15,Bf16,Bf17,Bf18,Bf19,Bf20]],
    [I1,I2] = [binary_to_integer(X) || X <- [Bi1,Bi2]],
    {async,{usblphyp,F1,F2,I1,I2,F3,F4,F5,F6,F7,F8,F9,F10,F11,F12,F13,F14,F15,F16,F17,F18,F19,F20}}
  catch
    error:_ -> {error, {parseError, usblphyp, binary_to_list(P)}}
  end.

%% BITRATE,local|remote,val
bitrate_extract(P) ->
  try
    {match, [Bdir,Bval]} = re:run(P,"^([^,]*),([^,]*)$",[dotall,{capture,[1,2],binary}]),
    Val = binary_to_integer(Bval),
    Dir = list_to_atom(binary_to_list(Bdir)),
    {async,{bitrate,Dir,Val}}
  catch
    error:_ -> {error, {parseError, bitrate, binary_to_list(P)}}
  end.

%% RADDR,val
raddr_extract(P) ->
  try
    Val = binary_to_integer(P),
    {async,{raddr,Val}}
  catch
    error:_ -> {error, {parseError, raddr, binary_to_list(P)}}
  end.

%% SRCLEVEL,val
srclevel_extract(P) ->
  try
    {match, [Bval]} = re:run(P,"^(.*)$",[dotall,{capture,[1],binary}]),
    Val = binary_to_integer(Bval),
    {async,{srclevel,Val}}
  catch
    error:_ -> {error, {parseError, srclevel, binary_to_list(P)}}
  end.

%% DROPCNT,val
dropcnt_extract(P) ->
  try
    {match, [Bval]} = re:run(P,"^(.*)$",[dotall,{capture,[1],binary}]),
    Val = binary_to_integer(Bval),
    {async,{dropcnt,Val}}
  catch
    error:_ -> {error, {parseError, dropcnt, binary_to_list(P)}}
  end.

%% ECLK,mono,phyclock,physteer,bite,gps
%% gps, mono %f in seconds
%% phy_clock %d in microseconds
%% phy_steer %d in nanoseconds per second
%% bite 0-7 bitmask, bit0 - atomic clock bite, bit1 - gps event, bit2 - power event
eclk_extract(P) ->
  try
    {match, [BMono,BClk,BSteer,BFlag,BGPS]} = re:run(P,"^([^,]*),([^,]*),([^,]*),([^,]*),([^,]*)$",[dotall,{capture,[1,2,3,4,5],binary}]),
    [Mono, GPS] = [round(binary_to_float(X)*1000000) || X <- [BMono, BGPS]],
    [Clk, Steer, Flag] = [binary_to_integer(X) || X <- [BClk, BSteer, BFlag]],
    <<_:5,Power:1,GPSevent:1,Bite:1>> = <<Flag:8>>,
    Event = case {Power, GPSevent, Bite} of
              {1, _, _} -> power;
              {_, 1, _} -> gps;
              {_, _, 1} -> unlocked;
              {_, _, 0} -> locked
            end,
    {async,{eclk,Mono,Clk,Steer,Event,GPS}}
  catch
    error:_ -> {error, {parseError, eclk, binary_to_list(P)}}
  end.

%% RTO,clock_offset
%% clock_offset in microseconds
rto_extract(P) ->
  try
    {match, [Bval]} = re:run(P,"^(.*)$",[dotall,{capture,[1],binary}]),
    Val = binary_to_integer(Bval),
    {async,{rto,Val}}
  catch
    error:_ -> {error, {parseError, rto, binary_to_list(P)}}
  end.

%% STATUS,modem_status,modem_status_parameter
status_extract(P) ->
  try
    [Status,Param] = [binary_to_atom(B, utf8) || B <- binary:split(P,<<",">>)],
    {async, {status, Status, Param}}
  catch
    error:_ -> {error, {parseError, status, binary_to_list(P)}}
  end.

extended_extract(P) ->
  try
    [Key,Params] = [binary_to_list(B) || B <- binary:split(P,<<",">>)],
    {async, {extended, [$% | Key], Params}}
  catch
    error:_ -> {error, {parseError, extended, binary_to_list(P)}}
  end.  

%% SENDEND,addr,type,usec,dur
sendend_extract(P) ->
  try
    {match, [Baddr,Btype,Busec,Bdur]} = re:run(P,"^([^,]*),([^,]*),([^,]*),([^,]*)$",[dotall,{capture,[1,2,3,4],binary}]),
    [Addr,Usec,Dur] = [binary_to_integer(X) || X <- [Baddr,Busec,Bdur]],
    {async,{sendend,Addr,binary_to_list(Btype),Usec,Dur}}
  catch
    error:_ -> {error, {parseError, sendend, binary_to_list(P)}}
  end.

%% SENDSTART,addr,type,dur,delay
sendstart_extract(P) ->
  try
    {match, [Baddr,Btype,Bdur,Bdelay]} = re:run(P,"^([^,]*),([^,]*),([^,]*),([^,]*)$",[dotall,{capture,[1,2,3,4],binary}]),
    [Addr,Dur,Delay] = [binary_to_integer(X) || X <- [Baddr,Bdur,Bdelay]],
    {async,{sendstart,Addr,binary_to_list(Btype),Dur,Delay}}
  catch
    error:_ -> {error, {parseError, sendstart, binary_to_list(P)}}
  end.

%% RECVEND,usec,dur,rssi,int
recvend_extract(P) ->
  try
    {match, [Busec,Bdur,Br,Bi]} = re:run(P,"^([^,]*),([^,]*),([^,]*),([^,]*)$",[dotall,{capture,[1,2,3,4],binary}]),
    [Usec,Dur,R,I] = [binary_to_integer(X) || X <- [Busec,Bdur,Br,Bi]],
    {async,{recvend,Usec,Dur,R,I}}
  catch
    error:_ -> {error, {parseError, recvend, binary_to_list(P)}}
  end.

%% RECVFAILED,speed,rssi,int
recvfailed_extract(P) ->
  try
    {match, [Bv,Br,Bi]} = re:run(P,"^([^,]*),([^,]*),([^,]*)$",[dotall,{capture,[1,2,3],binary}]),
    [R,I] = [binary_to_integer(X) || X <- [Br,Bi]],
    V = binary_to_float(Bv),
    {async,{recvfailed,V,R,I}}
  catch
    error:_ -> {error, {parseError, recvfailed, binary_to_list(P)}}
  end.

%% RECVSRV,src,dst,type,decode,transmitted,rssi,int
recvsrv_extract(P) ->
  try
    {match, [Bs,Bd,Btype,Bdecode,Btransm,Br,Bi]} =
      re:run(P,"^([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*)$",[dotall,{capture,[1,2,3,4,5,6,7],binary}]),
    [S,D,Decode,Transmit,R,I] = [binary_to_integer(X) || X <- [Bs,Bd,Bdecode,Btransm,Br,Bi]],
    {async,{recvsrv,S,D,binary_to_list(Btype),Decode,Transmit,R,I}}
  catch
    error:_ -> {error, {parseError, recvsrv, binary_to_list(P)}}
  end.

%% RECVPROBE,bit_value,timestamp,dur,rssi,int,vel
recvprobe_extract(P) ->
  try
    {match, [Bb,Busec,Bdur,Br,Bi,Bv]} =
      re:run(P,"^([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*)$",[dotall,{capture,[1,2,3,4,5,6],binary}]),
    [Bit,Usec,Dur,R,I] = [binary_to_integer(X) || X <- [Bb,Busec,Bdur,Br,Bi]],
    V = binary_to_float(Bv),
    {async,{recvprobe,Bit,Usec,Dur,R,I,V}}
  catch
    error:_ -> {error, {parseError, recvprobe, binary_to_list(P)}}
  end.
  
recv_extract(L,Brecv,Len,Tail,Wait,Request,Pid) ->
  Recv = case Brecv of
           <<"RECV,">> -> recv;
           <<"RECVIM,">> -> recvim;
           <<"RECVIMS,">> -> recvims;
           <<"RECVJRP,">> -> recvjrp;
           <<"RECVPBM,">> -> recvpbm
         end,
  try
    recv_extract_helper(L,Recv,Len,Tail,Wait,Request,Pid)
  catch
    error:_ -> [{error, {binaryParseError, Recv, Tail}}]
  end.

% RECVJRP,len,usec,dur,janus_rssi,vel,data\r\n
recv_extract_helper(L,recvjrp,Len,Tail,Wait,Request,Pid) ->
  {match, [Busec,Bdur,Br,Bv,PTail]} = re:run(Tail,"^,([^,]*),([^,]*),([^,]*),([^,]*),(.*)",[dotall,{capture,[1,2,3,4,5],binary}]),
  PLLen = byte_size(PTail),
  if
    Len + 2 =< PLLen ->
      {match, [Payload, Tail1]} = re:run(PTail, "^(.{" ++ integer_to_list(Len) ++ "})\r\n(.*)",[dotall,{capture,[1,2],binary}]),
      [Usec,Dur] = [binary_to_integer(X) || X <- [Busec,Bdur]],
      [R,V] = [binary_to_float(X) || X <- [Br,Bv]],
      Rcv = {recvjrp,Len,Usec,Dur,R,V,Payload},
      [{async, Rcv} | answer_split(Tail1,Wait,Request,Pid)];
    true ->
      [{more, L}]
  end;

%% RECVPBM,len,src,dst,dur,rssi,int,vel,data\r\n             RECVPBM,len,([^,]*,){6}.{len}\r\n
recv_extract_helper(L,recvpbm,Len,Tail,Wait,Request,Pid) ->
  {match, [Bs,Bd,Bdur,Br,Bi,Bv,PTail]} = re:run(Tail,"^,([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),(.*)",[dotall,{capture,[1,2,3,4,5,6,7],binary}]),
  PLLen = byte_size(PTail),
  if
    Len + 2 =< PLLen ->
      {match, [Payload, Tail1]} = re:run(PTail, "^(.{" ++ integer_to_list(Len) ++ "})\r\n(.*)",[dotall,{capture,[1,2],binary}]),
      [S,D,Dur,R,I] = [binary_to_integer(X) || X <- [Bs,Bd,Bdur,Br,Bi]], 
      V = binary_to_float(Bv),
      Rcv = {recvpbm,Len,S,D,Dur,R,I,V,Payload},
      [{async, {pid, Pid}, Rcv} | answer_split(Tail1,Wait,Request,Pid)];
    true ->
      [{more, L}]
  end;
%% RECVIM,len,src,dst,flag,dur,rssi,int,vel,data\r\n         RECVIM,len,([^,]*,){7}.{len}\r\n
recv_extract_helper(L,recvim,Len,Tail,Wait,Request,Pid) ->
  {match, [Bs,Bd,BFlag,Bdur,Br,Bi,Bv,PTail]} = re:run(Tail,"^,([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),(.*)",[dotall,{capture,[1,2,3,4,5,6,7,8],binary}]),
  PLLen = byte_size(PTail),
  if
    Len + 2 =< PLLen ->
      {match, [Payload, Tail1]} = re:run(PTail, "^(.{" ++ integer_to_list(Len) ++ "})\r\n(.*)",[dotall,{capture,[1,2],binary}]),
      [S,D,Dur,R,I] = [binary_to_integer(X) || X <- [Bs,Bd,Bdur,Br,Bi]], 
      V = binary_to_float(Bv),
      Flag = binary_to_flag(BFlag),
      Rcv = {recvim,Len,S,D,Flag,Dur,R,I,V,Payload},
      [{async, {pid, Pid}, Rcv} | answer_split(Tail1,Wait,Request,Pid)];
    true ->
      [{more, L}]
  end;
%% RECV,len,src,dst,bitrate,rssi,int,ptime,vel,data\r\n      RECV,len,([^,]*,){7}.{len}\r\n
%% RECVIMS,len,src,dst,timestamp,dur,rssi,int,vel,data\r\n   RECVIMS,len,([^,]*,){7}.{len}\r\n
recv_extract_helper(L,Recv,Len,Tail,Wait,Request,Pid) ->
  {match, [Bs,Bd,Bx,Bdur,Br,Bi,Bv,PLTail]} = re:run(Tail,"^,([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),(.*)",[dotall,{capture,[1,2,3,4,5,6,7,8],binary}]),
  PLLen = byte_size(PLTail),
  if
    Len + 2 =< PLLen ->
      {match, [Payload, Tail1]} = re:run(PLTail, "^(.{" ++ integer_to_list(Len) ++ "})\r\n(.*)",[dotall,{capture,[1,2],binary}]),
      [S,D,X,Dur,R,I] = [binary_to_integer(X) || X <- [Bs,Bd,Bx,Bdur,Br,Bi]], 
      V = binary_to_float(Bv),
      Rcv = {Recv,Len,S,D,X,Dur,R,I,V,Payload},
      [{async, {pid, Pid}, Rcv} | answer_split(Tail1,Wait,Request,Pid)];
    true ->
      [{more, L}]
  end.

binary_to_flag(<<"ack">>) -> ack;
binary_to_flag(<<"noack">>) -> noack;
binary_to_flag(<<"force">>) -> force.

bes_split([]) -> [];
bes_split(L) ->
  case re:run(L,"((.*?)(\\\+{3}AT.*?):(\\d+):)(.*)",[dotall,{capture,[1,2,3,4,5],binary}]) of
    {match,[MaybeBESHead,Bin,BESHead,BLen,Rest]} -> 
      Len = binary_to_integer(BLen),
      case parse_the_rest(Len,Rest) of
        [BESBody,Tail] -> [{raw,Bin}, {bes,BESHead,Len,BESBody} | bes_split(Tail)];
        nomatch        -> [{raw,MaybeBESHead} | bes_split(Rest)];
        more           -> [{more,L}]
      end;
    nomatch ->  
      case re:run(L,"(.*?[^+]*)(\\\+{3}(AT.*?:\\d*|AT[^:]{0,10}:?|AT?|A?)|\\\+{0,2})$",[dotall,{capture,[1,2],binary}]) of
        {match, [Bin, <<>>]}          -> [{raw,Bin}];
        {match, [<<>>, MaybeBESPart]} -> [{more,MaybeBESPart}];
        {match, [Bin, MaybeBESPart]}  -> [{raw,Bin},{more,MaybeBESPart}]
      end
  end.

parse_the_rest(Len, Rest) ->
  case byte_size(Rest) of
    RestLen when Len + 2 =< RestLen ->
      case re:run(Rest,"^(.{" ++ integer_to_list(Len) ++ "})\r\n(.*)",[dotall,{capture,[1,2],binary}]) of
        {match,[BESBody,Tail]} -> [BESBody,Tail];
        nomatch                -> nomatch
      end;
    _ -> more
  end.

from_term(Term, #{waitsync := no} = Cfg) ->
  from_term_priv(Term, Cfg);
from_term(Term, #{txtime := TXTime} = Cfg) ->
  case erlang:system_time(seconds) - TXTime of
    D when D > 1 ->
      from_term_priv(Term, Cfg);
    _ ->
      {error, at_sequenceError}
  end.

%% Term format:
%% {raw,Data}
%% {at,"*SEND",dst,data}   {at,{pid,Pid},"*SEND",dst,data}   
%% {at,"*SENDIM",dst,flag,data}  {at,{pid,Pid},"*SENDIM",dst,flag,data}  
%% {at,"*SENDIMS",dst,usec,data} {at,{pid,Pid},"*SENDIMS",dst,usec,data} 
%% {at,"*SENDPBM",dst,data}      {at,{pid,Pid},"*SENDPBM",dst,data}
%% {at,"*SENDJRP",data}
%% {at,"*SENDPROBE",bit_value,follow_flag,usec}
%% {at,"req","params"}
%% {at,help,"req"}
%%
%% [Bin, NewConfig] = from_term_priv(Term, Config)
%%
%% запятой от строки параметров отделаютсятя только send параметры
from_term_priv({raw,Data}, Cfg) when is_binary(Data) -> 
  [Data, Cfg];
from_term_priv({at,"O",[]}, #{filter := Filter, mode := Mode} = Cfg) when Filter == at,
                                      Mode == data ->
  [<<>>, Cfg];
from_term_priv(Term, #{pid := Pid, filter := Filter, eol := EOL} = Cfg) ->
  %% io:format("Term = ~p~n",[Term]),
  {Request, Wait, Telegram} = from_term_helper(Term, Pid, Filter),
  [list_to_binary([prefix(Cfg), Telegram, EOL])
  , Cfg#{waitsync => Wait, txtime => erlang:system_time(seconds), request => Request, telegram => Telegram}].

%% NOTE: disabled @ZF not supported!!!
%% {at,{pid,Pid},"*SEND",Dst,Data}} or {at,"*SEND",Dst,Data}
from_term_helper({at,{pid,Pid},"*SEND",Dst,Data},_,F) ->
  from_term_helper({at,"*SEND",Dst,Data},Pid,F);
from_term_helper({at,"*SEND",Dst,Data},Pid,_) when is_integer(Dst) and is_binary(Data) ->
  {"*SEND", singleline,
   ["AT*SEND,p", integer_to_binary(Pid), ",", integer_to_binary(byte_size(Data)), ",", integer_to_binary(Dst), ",", Data]};
%% {at,{pid,Pid},"*SENDIM",Dst,Flag,Data}} or {at,"*SENDIM",Dst,Flag,Data}
from_term_helper({at,{pid,Pid},"*SENDIM",Dst,Flag,Data},_,F) ->
  from_term_helper({at,"*SENDIM",Dst,Flag,Data},Pid,F);
from_term_helper({at,"*SENDIM",Dst,Flag,Data},Pid,_) when is_integer(Dst) and is_binary(Data) and is_atom(Flag) ->
  {"*SENDIM", singleline,
   ["AT*SENDIM,p", integer_to_binary(Pid), ",", integer_to_binary(byte_size(Data)), ",", integer_to_binary(Dst), ",", atom_to_list(Flag), ",", Data]};
%% {at,{pid,Pid},"*SENDIM",Dst,Usec,Data}} or {at,"*SENDIM",Dst,Usec,Data}
from_term_helper({at,{pid,Pid},"*SENDIMS",Dst,Usec,Data},_,F) ->
  from_term_helper({at,"*SENDIMS",Dst,Usec,Data},Pid,F);
from_term_helper({at,"*SENDIMS",Dst,Usec,Data},Pid,_) when is_integer(Dst) and is_binary(Data) ->
  case Usec of
    X when is_integer(X) -> {"*SENDIMS", singleline, 
                             ["AT*SENDIMS,p", integer_to_binary(Pid), ",", 
                              integer_to_binary(byte_size(Data)), ",", integer_to_binary(Dst), ",", integer_to_binary(Usec), ",", Data]};
    none                 -> {"*SENDIMS", singleline,
                             ["AT*SENDIMS,p", integer_to_binary(Pid), ",", 
                              integer_to_binary(byte_size(Data)), ",", integer_to_binary(Dst), ",,", Data]}
  end;
%% {at,{pid,Pid},"*SENDPBM",Dst,Data}} or {at,"*SENDPBM",Dst,Data}
from_term_helper({at,{pid,Pid},"*SENDPBM",Dst,Data},_,F) ->
  from_term_helper({at,"*SENDPBM",Dst,Data},Pid,F);
from_term_helper({at,"*SENDPBM",Dst,Data},Pid,_) when is_integer(Dst) and is_binary(Data) ->
  {"*SENDPBM", singleline,
   ["AT*SENDPBM,p", integer_to_binary(Pid), ",", integer_to_binary(byte_size(Data)), ",", integer_to_binary(Dst), ",", Data]};
%% {at,"*SENDPROBE",bit_value,follow_flag,usec}
from_term_helper({at,"*SENDPROBE",V,Flag,Usec},_,_) ->
  SUsec = case Usec of
            X when is_integer(X) -> integer_to_binary(Usec);
            none -> ""
          end,
  {"*SENDPROBE", singleline, ["AT*SENDPROBE,",integer_to_binary(V),$,,integer_to_binary(Flag),$,,SUsec]};
%% {at,"*SENDJRP",data}
from_term_helper({at,"*SENDJRP",Data},_,_) ->
  {"*SENDJRP", singleline,
   ["AT*SENDJRP,", integer_to_binary(byte_size(Data)), ",", Data]};
%% other {at,...} terms
from_term_helper({at,"$",Req,_}, _, _) ->
  {"$", multiline,
   ["AT", Req, "$"]};
from_term_helper({at,Req,Params}, _, F) when is_list(Req) and is_list(Params) ->
  Wait = case {Req, F} of
           {"?S", net}   -> multiline;
           {"?ZSL", _}   -> multiline;
           {"?P", _}     -> multiline;
           {"&V", _}     -> multiline;
           {"?NOISE", _} -> binary;
           {"O", _}      -> no;
           _             -> singleline
         end,
  {Req, Wait, ["AT",string:to_upper(Req),Params]}.

prefix(#{filter := at, mode := data}) -> "+++";
prefix(_) -> "".

