defmodule AshOnetime.Test.ExitBoundary.Classifier do
  @moduledoc false

  # §2.7.8 rule 3: the classes of every way a term leaves a process in OTP 28.5 and 29.1.2, and
  # the total function from an observed event to its class. The table and the classifier
  # are one artifact: `classify_mfa/3` is defined by the tables below and nothing else.
  #
  # - Every function of `:erlang` and `:erts_internal` at either supported release is named here, each with
  #   its class or as `:pure` (no term leaves the process). A function missing from the
  #   tables classifies as `:unclaimed`, and an unclaimed event fails the run.
  # - Every other module the class table names is claimed whole by exactly one class.
  #   A module named under two classes in the design is placed in the more specific one
  #   (`prim_file` in E10, `prim_net` and `prim_socket` in E11, `prim_tty` and `dbg` in
  #   E16, `erl_ddll` in E8); the native modules with no behavior class are E9.
  # - The BIFs in `bif.tab` outside these modules (`math`, `lists`, `maps`, `binary`,
  #   `re`, `unicode`, `string`, `records`) compute only; they are listed as pure modules.
  #
  # The coverage test (exit_boundary_classifier_test.exs) asserts the release, every
  # `bif.tab` row and every exported or local function of both modules against this table.

  @erlang %{
    pure: ~w[
      */2 ++/2 +/1 +/2 --/2 -/1 -/2 //2 /=/2 </2 =/=/2 =:=/2 =</2 ==/2 >/2 >=/2
      abs/1 adler32/1 adler32/2 adler32_combine/3 and/2 append/2 append_element/2
      apply/2 apply/3 atom_to_binary/1 atom_to_binary/2 atom_to_list/1 band/2
      big_binary_to_int/2 binary_part/2 binary_part/3 binary_to_float/1
      binary_to_integer/1 binary_to_integer/2 binary_to_list/1 binary_to_list/3
      bit_size/1 bitstring_to_list/1 bnot/1 bor/2 bsl/2 bsr/2 bump_reductions/1 bxor/2
      byte_size/1 ceil/1 combine/2 combine_pairs/2 convert_time_unit/3 cput_e2i/1
      cput_e2i/7 cput_e2i_clvl/2 cput_i2e/1 cput_i2e/4 cput_i2e/6 cput_i2e_tag/2
      cput_i2e_tag_map/0 crc32/1 crc32/2 crc32_combine/3 date/0 decode_packet/3
      delay_trap/2 delete_element/2 digits_per_small/2 div/2 element/2 external_size/1
      external_size/2 float/1 float_to_binary/1 float_to_binary/2 float_to_list/1
      float_to_list/2 floor/1 format_cpu_topology/1 fun_info/1 fun_info/2 fun_info_1/3
      fun_info_mfa/1 fun_to_list/1 function_exported/3 garbage_collect/0
      garbage_collect_message_area/0 get_sign/1 hd/1 hibernate/0 hibernate/3
      insert_element/3 integer_to_binary/1 integer_to_binary/2 integer_to_list/1
      integer_to_list/2 iolist_size/1 iolist_to_binary/1 iolist_to_iovec/1 is_alive/0
      is_atom/1 is_binary/1 is_bitstring/1 is_boolean/1 is_builtin/3 is_float/1
      is_function/1 is_function/2 is_integer/1 is_integer/3 is_list/1 is_map/1
      is_map_key/2 is_number/1 is_pid/1 is_port/1 is_record/1 is_record/2 is_record/3
      is_reference/1 is_tuple/1 length/1 list_to_binary/1 list_to_bitstring/1
      list_to_float/1 list_to_integer/1 list_to_integer/2 list_to_pid/1 list_to_port/1
      list_to_ref/1 list_to_tuple/1 localtime/0 localtime_to_universaltime/1
      localtime_to_universaltime/2 make_fun/3 make_ref/0 make_tuple/2 make_tuple/3
      map_get/2 map_size/1 max/2 md5/1 md5_final/1 md5_init/0 md5_update/2 min/2
      module_info/0 module_info/1 module_loaded/1 loaded/0 pre_loaded/0
      monotonic_time/0 monotonic_time/1 node/0 node/1 not/1 now/0 or/2 phash/2 phash2/1
      phash2/2 pid_to_list/1 port_to_list/1 posixtime_to_universaltime/1 radix/2
      ref_to_list/1 rem/2 round/1 rvrs/1 rvrs/2 segmentize/4 segmentize_1/4 self/0
      setelement/3 size/1 split_binary/2 subtract/2 system_time/0 system_time/1
      term_to_binary/1 term_to_binary/2 term_to_iovec/1 term_to_iovec/2 time/0
      time_offset/0 time_offset/1 timestamp/0 tl/1 trim_zeroes/1 trunc/1 tuple_size/1
      tuple_to_list/1 unique_integer/0 unique_integer/1 universaltime/0
      universaltime_to_localtime/1 universaltime_to_posixtime/1 xor/2 yield/0
    ],
    e1: ~w[
      !/2 send/2 send/3 send_nosuspend/2 send_nosuspend/3 alias/0 alias/1 unalias/1
      dist_ctrl_get_data/1 dist_ctrl_get_data_notification/1 dist_ctrl_get_opt/2
      dist_ctrl_input_handler/2 dist_ctrl_put_data/2 dist_ctrl_set_opt/3 dist_get_stat/1
      setnode/2 setnode/3 disconnect_node/1
    ],
    e2: ~w[send_after/3 send_after/4 start_timer/3 start_timer/4 cancel_timer/1
      cancel_timer/2 read_timer/1 read_timer/2],
    e3: ~w[put/2 erase/0 erase/1 get/0 get/1 get_keys/0 get_keys/1],
    e4: ~w[
      spawn/1 spawn/2 spawn/3 spawn/4 spawn_link/1 spawn_link/2 spawn_link/3
      spawn_link/4 spawn_monitor/1 spawn_monitor/2 spawn_monitor/3 spawn_monitor/4
      spawn_opt/2 spawn_opt/3 spawn_opt/4 spawn_opt/5 spawn_request/1 spawn_request/2
      spawn_request/3 spawn_request/4 spawn_request/5 spawn_request_abandon/1
    ],
    e8: ~w[open_port/2 port_command/2 port_command/3 port_control/3 port_call/2
      port_call/3 port_connect/2 port_set_data/2 port_get_data/1 port_close/1],
    e12: ~w[register/2 unregister/1 whereis/1 list_to_atom/1 list_to_existing_atom/1
      binary_to_atom/1 binary_to_atom/2 binary_to_existing_atom/1
      binary_to_existing_atom/2 binary_to_term/1 binary_to_term/2],
    e15: ~w[group_leader/0 group_leader/2],
    e16: ~w[display/1 display_string/1 display_string/2 process_display/2],
    e17: ~w[load_module/2 purge_module/1 delete_module/1 check_old_code/1
      check_process_code/2 check_process_code/3 prepare_loading/2 prepare_loading_1/2
      finish_loading/1 get_module_info/1 get_module_info/2],
    e18: ~w[load_nif/2 call_on_load_function/1 finish_after_on_load/2
      has_prepared_code_on_load/1],
    e19: ~w[process_flag/2 process_flag/3 system_flag/2 set_cookie/1 set_cookie/2
      get_cookie/0 get_cookie/1 set_cpu_topology/1 halt/0 halt/1 halt/2],
    e20: ~w[monitor/2 monitor/3 demonitor/1 demonitor/2 link/1 link/2 unlink/1 exit/2
      exit/3 exit_signal/2 exit_signal/3 monitor_node/2 monitor_node/3 dmonitor_node/3],
    e21: ~w[error/1 error/2 error/3 exit/1 throw/1 raise/3 nif_error/1 nif_error/2
      -inlined-error_with_inherited_info/3-/3],
    e22: ~w[
      process_info/1 process_info/2 system_info/1 statistics/1 memory/0 memory/1
      memory_1/2 processes/0 processes_iterator/0 processes_next/1 ports/0
      registered/0 port_info/1 port_info/2 nodes/0 nodes/1 nodes/2 is_process_alive/1
      garbage_collect/1 garbage_collect/2 suspend_process/1 suspend_process/2
      resume_process/1 aa_mem_data/1 aa_mem_data/2 acc_blocks_size/2 alloc_info/1
      alloc_sizes/1 au_mem_acc/3 au_mem_blocks/2 au_mem_blocks_1/2 au_mem_current/3
      au_mem_data/1 au_mem_data/2 au_mem_fix/2 fix_proc/2 get_fix_proc/2
      get_alloc_info/2 get_memval/2 insert_info/2 insert_instance/3 mk_res_list/1
      receive_allocator/3 receive_emd/1 receive_emd/3 gather_gc_info_result/1
      gc_info/3 get_gc_opts/2
    ],
    e23: ~w[
      trace/3 trace_delivered/1 trace_info/2 trace_pattern/2 trace_pattern/3
      seq_trace/2 seq_trace_info/1 seq_trace_print/1 seq_trace_print/2
      system_monitor/0 system_monitor/1 system_monitor/2 system_profile/0
      system_profile/2 ensure_tracer_module_loaded/2 match_spec_test/3
      dt_append_vm_tag_data/1 dt_get_tag/0 dt_get_tag_data/0 dt_prepend_vm_tag_data/1
      dt_put_tag/1 dt_restore_tag/1 dt_spread_tag/1
    ]
  }

  @erts_internal %{
    pure: ~w[binary_to_integer/2 list_to_integer/2 cmp_term/2 term_type/1
      term_to_string/1 term_to_string/2 map_hashmap_children/1 map_next/3
      map_to_tuple_keys/1 is_map_iter/1 module_info/0 module_info/1 garbage_collect/1],
    e1: ~w[abort_pending_connection/2 create_dist_channel/3 new_connection/1
      dist_ctrl_put_data/2 get_creation/0 get_dflags/0 dynamic_node_name/0
      dynamic_node_name/1],
    e4: ~w[spawn_init/1 spawn_request/4 spawn_system_process/3 dist_spawn_init/1
      dist_spawn_request/4],
    e5: ~w[ets_info_binary/1 ets_info_binary_error/4 ets_info_binary_iter/3
      ets_lookup_binary_info/2 ets_raw_first/1 ets_raw_next/2 ets_super_user/1],
    e6: ~w[erase_persistent_terms/0],
    e7: ~w[atomics_new/2 counters_add/3 counters_get/2 counters_info/1 counters_new/1
      counters_put/3],
    e8: ~w[open_port/2 port_call/3 port_close/1 port_command/3 port_connect/2
      port_control/3 port_info/1 port_info/2 await_port_send_result/3],
    e15: ~w[group_leader/2 group_leader/3],
    e16: ~w[process_display/2],
    e17: ~w[beamfile_chunk/2 beamfile_module_md5/1 check_dirty_process_code/2
      check_process_code/1 check_process_code/3 prepare_loading/2 purge_module/2
      get_cpc_opts/2 set_code_and_literal_cleaner_prio/1
      wait_release_literal_area_switch/1],
    e19: ~w[process_flag/3],
    e20: ~w[flush_monitor_messages/3 @flush_monitor_messages_refopt/0
      dirty_process_handle_signals/1],
    e21: ~w[crasher/6],
    e22: ~w[
      await_microstate_accounting_modifications/3 await_result/1
      await_sched_wall_time_modifications/2 gather_alloc_histograms/1
      gather_carrier_info/1 gather_io_bytes/2 gather_io_bytes/4
      gather_microstate_accounting_result/2 gather_sched_wall_time_result/1
      gather_system_check_result/1 gather_system_check_result/2
      get_internal_state_blocked/1 is_process_alive/1 is_process_alive/2
      is_process_executing_dirty/1 is_system_process/1 mc_iterator/1 mc_refill/1
      microstate_accounting/2 no_aux_work_threads/0 perf_counter_unit/0
      processes_next/1 request_system_task/3 request_system_task/4 sched_wall_time/2
      sched_wall_time/3 scheduler_wall_time/1 suspend_process/2 system_check/1
      system_flag_scheduler_wall_time/1 time_unit/0 find_lac/0 find_lac/1
    ],
    e23: ~w[breakpoint/4 -breakpoint/4-fun-0-/2 notify_breakpoint_hit/3
      system_monitor/1 system_monitor/3 trace/3 trace/4 trace_info/3 trace_pattern/3
      trace_pattern/4 trace_session_create/3 trace_session_destroy/1]
  }

  # Every other module the class table names, each in exactly one class.
  @modules %{
    e2: [:timer],
    e4: [:proc_lib],
    e5: [:ets],
    e6: [:persistent_term],
    e7: [:atomics, :counters],
    e8: [:erl_ddll],
    e9: [
      :asn1rt_nif,
      :crypto,
      :dyntrace,
      :erl_tracer,
      :gl,
      :prim_buffer,
      :pubkey_os_cacerts,
      :wxe_util,
      :zlib,
      :zstd
    ],
    e10: [:file, :prim_file, :dets, :disk_log, :mnesia],
    e11: [
      :socket,
      :prim_socket,
      :prim_net,
      :prim_inet,
      :gen_tcp,
      :gen_udp,
      :gen_sctp,
      :ssl,
      :inet_res
    ],
    e12: [:global, :pg],
    e13: [:os, :application, :application_controller],
    e14: [:logger, :logger_backend, :error_logger],
    e15: [:io, :io_lib],
    e16: [:erts_debug, :erl_debugger, :prim_tty, :int, :dbg],
    e17: [:code, :code_server, :erts_literal_area_collector, :erts_code_purger],
    e19: [:auth, :net_kernel],
    e22: [:sys],
    e23: [:trace, :seq_trace, :erts_trace_cleaner],
    e24: [:telemetry, :gen_server, :gen_statem, :gen_event]
  }

  # `proc_lib:set_label/1` stores a term in the process, as a label: E3, not E4.
  @overrides %{{:proc_lib, :set_label, 1} => :e3}

  # BIF modules of `bif.tab` whose functions only compute.
  @pure_modules [:math, :lists, :maps, :binary, :re, :unicode, :string, :records]

  @classes Enum.map(1..24, &:"e#{&1}")

  # "name/arity", split at the last slash, so operators such as `//2` parse.
  parse = fn table ->
    for {class, names} <- table, name <- names, into: %{} do
      {position, 1} = :binary.matches(name, "/") |> List.last()
      function = binary_part(name, 0, position)
      arity = binary_part(name, position + 1, byte_size(name) - position - 1)
      {{String.to_atom(function), String.to_integer(arity)}, class}
    end
  end

  @erlang_classes parse.(@erlang)
  @erts_internal_classes parse.(@erts_internal)
  @module_classes for {class, modules} <- @modules,
                      module <- modules,
                      into: %{},
                      do: {module, class}

  def classes, do: @classes
  alias AshOnetime.Test.ExitBoundary.Inventory

  def erlang_table(release \\ Inventory.release())
  def erlang_table("29.1.2"), do: @erlang_classes

  def erlang_table(release) when release in ["28.5", "28.5.0.8"],
    do: Map.drop(@erlang_classes, is_integer: 3, is_record: 1, exit_signal: 3)

  def erts_internal_table(release \\ Inventory.release()) do
    Inventory.bif_rows(release)
    @erts_internal_classes
  end

  def module_table, do: @module_classes
  def pure_modules, do: @pure_modules
  def traced_modules, do: [:erlang, :erts_internal | Map.keys(@module_classes)]

  @doc "The class of a call to `{module, function, arity}`."
  def classify_mfa(module, function, arity),
    do: classify_mfa(module, function, arity, Inventory.release())

  def classify_mfa(:erlang, function, arity, release),
    do: Map.get(erlang_table(release), {function, arity}, :unclaimed)

  def classify_mfa(:erts_internal, function, arity, release),
    do: Map.get(erts_internal_table(release), {function, arity}, :unclaimed)

  def classify_mfa(module, function, arity, release) do
    Inventory.bif_rows(release)

    cond do
      class = Map.get(@overrides, {module, function, arity}) -> class
      class = Map.get(@module_classes, module) -> class
      module in @pure_modules -> :pure
      true -> :unclaimed
    end
  end

  @doc """
  The class of one recorded event. Calls classify by their function; process events by
  their trace tag; port events are E8. Calls, returns, and exceptions remain complete
  comparison events, including package frames.
  """
  def classify({_pid, :call, {module, function, args}}),
    do: classify_mfa(module, function, length(args))

  def classify({_pid, :return_from, _mfa, _value}), do: :frame_return
  def classify({_pid, :exception_from, _mfa, _value}), do: :frame_return
  def classify({pid, :send, _message, _to}) when is_pid(pid), do: :e1
  def classify({pid, :send_to_non_existing_process, _message, _to}) when is_pid(pid), do: :e1
  def classify({pid, :receive, _message}) when is_pid(pid), do: :e20
  def classify({_pid, :spawn, _child, _mfa}), do: :e4
  def classify({_pid, :spawned, _parent, _mfa}), do: :e4
  def classify({pid, :exit, _reason}) when is_pid(pid), do: :e21

  def classify({pid, tag, _other})
      when tag in [:link, :unlink, :getting_linked, :getting_unlinked] and is_pid(pid),
      do: :e20

  def classify({port, tag, _a})
      when is_port(port) and
             tag in [:closed, :receive, :link, :unlink, :getting_linked, :getting_unlinked],
      do: :e8

  def classify({port, tag, _a, _b})
      when is_port(port) and tag in [:open, :send, :send_to_non_existing_process],
      do: :e8

  def classify({_pid, :register, _name}), do: :e12
  def classify({_pid, :unregister, _name}), do: :e12
  def classify(_event), do: :unclaimed
end
