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
-module(fsm_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([delete_standard_report_handler/0]).

delete_standard_report_handler() ->
  case error_logger:delete_report_handler(log_mf_h) of
    {_,Dir,MaxB,MaxF,_,_,_,_,Fun} ->
      error_logger:add_report_handler(fsm_log_mf_h,fsm_log_mf_h:init(Dir,MaxB,MaxF,Fun));
    _ ->
      timer:apply_after(100, ?MODULE, delete_standard_report_handler, [])
  end.

start(_Type, _Args) ->
  case maybe_config(log_output) of
    on ->
      evins:logon();
    _ ->
      nothing
  end,
  case maybe_config(log_file) of
    nothing -> nothing; % do not start disk logging unless path is specified
    Path ->
          logger:add_handler(file_logger, logger_disk_log_h,
                             #{level => debug,
                               config => #{file => Path,
                                           max_no_files => maybe_config(log_max_no_files, 5),
                                           max_no_bytes => maybe_config(log_max_no_bytes, 4194304)},
                               formatter => {logger_formatter,
                                             #{template => [time, " ", pid, " ", level, ": ", msg, "\n"],
                                               single_line => true}}})
  end,
  User_config = maybe_config(user_config),
  Fabric_config = maybe_config(fabric_config),
  fsm_supervisor:start_link([Fabric_config, User_config]).

maybe_config(Name) ->
  case application:get_env(evins, Name) of
    {ok, Path} -> Path;
    _ -> nothing
  end.

maybe_config(Name, Default) ->
  case application:get_env(evins, Name) of
    {ok, Path} -> Path;
    _ -> Default
  end.

stop(_State) ->
  ok.

