open Lwt.Infix

(* Logging *)
let bgpd_src = Logs.Src.create "BGP" ~doc:"BGP logging"
module Bgp_log = (val Logs.src_log bgpd_src : Logs.LOG)

(* This is to simulate a cancellable lwt thread *)
module Device = struct
  type t = unit Lwt.t

  let create f callback : t =
    let t, u = Lwt.task () in
    let _ = 
      f () >>= fun x ->
      Lwt.wakeup u x;
      Lwt.return_unit
    in
    t >>= fun x ->
    (* To avoid callback being cancelled. *)
    let _ = callback x in
    Lwt.return_unit
  ;;

  let stop t = Lwt.cancel t
end

module  Main (S: Mirage_stack_lwt.V4) = struct
  module Bgp_flow = Bgp_io.Make(S)
  module Id_map = Map.Make(Ipaddr.V4)
  
  type t = {
    remote_id: Ipaddr.V4.t;
    local_id: Ipaddr.V4.t;
    local_asn: int;
    socket: S.t;
    mutable fsm: Fsm.t;
    mutable flow: Bgp_flow.t option;
    mutable conn_retry_timer: Device.t option;
    mutable hold_timer: Device.t option;
    mutable keepalive_timer: Device.t option;
    mutable conn_starter: Device.t option;
    mutable tcp_flow_reader: Device.t option;
    mutable input_rib: Rib.Adj_rib.t option;
    mutable output_rib: Rib.Adj_rib.t option;
    mutable loc_rib: Rib.Loc_rib.t;
  }

  type id_map = t Id_map.t

  let create_timer time callback : Device.t =
    Device.create (fun () -> OS.Time.sleep_ns (Duration.of_sec time)) callback
  ;;

  let rec flow_reader t callback =
    match t.flow with
    | None -> Lwt.return_unit
    | Some flow -> begin
      let task () = Bgp_flow.read flow in
      let wrapped_callback read_result =
        match read_result with
        | Ok msg -> 
          let event = match msg with
          | Bgp.Open o -> Fsm.BGP_open o
          | Bgp.Update u -> Fsm.Update_msg u
          | Bgp.Notification e -> Fsm.Notif_msg e
          | Bgp.Keepalive -> Fsm.Keepalive_msg
          in
          Bgp_log.info (fun m -> m "receive message %s" (Bgp.to_string msg));
          let _ = callback event in
          flow_reader t callback
        | Error err ->
          let open Bgp_flow in
          (match err with
          | `Closed -> Bgp_log.debug (fun m -> m "Connection closed when read.")
          | `Refused -> Bgp_log.debug (fun m -> m "Read refused.");
          | `Timeout -> Bgp_log.debug (fun m -> m "Read timeout.");
          | `BGP_MSG_ERR err -> begin
            match err with
            | Bgp.Parsing_error -> Bgp_log.warn (fun m -> m "Message parsing error")
            | Bgp.Msg_fmt_error _ | Bgp.Notif_fmt_error _ -> Bgp_log.warn (fun m -> m "Message format error")
          end
          | _ -> ());
          t.tcp_flow_reader <- None;
          callback Fsm.Tcp_connection_fail
      in
      t.tcp_flow_reader <- Some (Device.create task wrapped_callback);
      Lwt.return_unit
    end
  ;;

  let start_tcp_flow_reader t callback = 
    match t.tcp_flow_reader with
    | None -> (match t.flow with
      | None -> Bgp_log.warn (fun m -> m "new flow reader is created when no tcp flow."); Lwt.return_unit
      | Some _ -> flow_reader t callback)
    | Some _ -> 
      Bgp_log.warn (fun m -> m "new flow reader is created when thee exists another flow reader."); 
      Lwt.return_unit
  ;;

  let init_tcp_connection t callback =
    Bgp_log.debug (fun m -> m "try setting up TCP connection with remote peer.");
    if not (t.conn_starter = None) then begin
      Bgp_log.warn (fun m -> m "new connection is initiated when there exists another conn starter.");
      Lwt.return_unit
    end
    else if not (t.flow = None) then begin
      Bgp_log.warn (fun m -> m "new connection is initiated when there exists an old connection.");
      Lwt.return_unit
    end
    else begin
      let task = fun () ->
        Bgp_flow.create_connection t.socket (t.remote_id, Key_gen.remote_port ())
      in
      let wrapped_callback result =
        t.conn_starter <- None;
        match result with
        | Error err ->
          (match err with
          | `Timeout -> Bgp_log.debug (fun m -> m "Connection init timeout.")
          | `Refused -> Bgp_log.debug (fun m -> m "Connection init refused.")
          | _ -> ());
          
          callback (Fsm.Tcp_connection_fail)
        | Ok flow -> begin
          Bgp_log.debug (fun m -> m "Connected to remote %s" (Ipaddr.V4.to_string t.remote_id));
          let connection = t in
          let open Fsm in
          match connection.fsm.state with
          | IDLE -> 
            Bgp_log.debug (fun m -> m "Drop connection to remote %s because fsm is at IDLE" (Ipaddr.V4.to_string t.remote_id));
            Bgp_flow.close flow
          | CONNECT ->
            connection.flow <- Some flow;
            callback Tcp_CR_Acked
            >>= fun () ->
            flow_reader connection callback
          | ACTIVE ->
            connection.flow <- Some flow;
            callback Tcp_CR_Acked
            >>= fun () ->
            flow_reader connection callback
          | OPEN_SENT | OPEN_CONFIRMED -> 
            if (Ipaddr.V4.compare connection.local_id connection.remote_id < 0) then begin
              Bgp_log.debug (fun m -> m "Connection collision detected and dump new connection.");
              Bgp_flow.close flow
            end
            else begin
              Bgp_log.debug (fun m -> m "Connection collision detected and dump existing connection.");
              callback Open_collision_dump
              >>= fun () ->
              let new_fsm = {
                state = CONNECT;
                conn_retry_counter = connection.fsm.conn_retry_counter;
                conn_retry_time = connection.fsm.conn_retry_time;
                hold_time = connection.fsm.hold_time;
                keepalive_time = connection.fsm.keepalive_time;
              } in
              connection.flow <- Some flow;
              connection.fsm <- new_fsm;
              callback Tcp_CR_Acked
            end
          | ESTABLISHED -> 
            Bgp_log.debug (fun m -> m "Connection collision detected and dump new connection.");
            Bgp_flow.close flow
        end
      in
      t.conn_starter <- Some (Device.create task wrapped_callback);
      Lwt.return_unit
    end
  ;;      

  let listen_tcp_connection s id_map callback =
    let on_connect flow =
      let remote_id, _ = Bgp_flow.dst flow in
      Bgp_log.debug (fun m -> m "receive incoming connection from remote %s" (Ipaddr.V4.to_string remote_id));
      match Id_map.mem remote_id id_map with
      | false -> 
        Bgp_log.debug (fun m -> m "Refuse connection because remote id %s is unknown." (Ipaddr.V4.to_string remote_id));
        Bgp_flow.close flow
      | true -> begin
        let connection = Id_map.find remote_id id_map in
        let open Fsm in
        match connection.fsm.state with
        | IDLE -> 
          Bgp_log.debug (fun m -> m "Refuse connection %s because fsm is at IDLE." (Ipaddr.V4.to_string remote_id));
          Bgp_flow.close flow
        | CONNECT ->
          connection.flow <- Some flow;
          callback connection Tcp_connection_confirmed
          >>= fun () ->
          flow_reader connection (callback connection)
        | ACTIVE ->
          connection.flow <- Some flow;
          callback connection Tcp_connection_confirmed
          >>= fun () ->
          flow_reader connection (callback connection)
        | OPEN_SENT | OPEN_CONFIRMED -> 
          if (Ipaddr.V4.compare connection.local_id connection.remote_id > 0) then begin
            Bgp_log.debug (fun m -> m "Collision detected and dump new connection.");
            Bgp_flow.close flow
          end
          else begin
            Bgp_log.debug (fun m -> m "Collision detected and dump existing connection.");
            callback connection Open_collision_dump
            >>= fun () ->
            let new_fsm = {
              state = CONNECT;
              conn_retry_counter = connection.fsm.conn_retry_counter;
              conn_retry_time = connection.fsm.conn_retry_time;
              hold_time = connection.fsm.hold_time;
              keepalive_time = connection.fsm.keepalive_time;
            } in
            connection.flow <- Some flow;
            connection.fsm <- new_fsm;
            callback connection Tcp_connection_confirmed
          end
        | ESTABLISHED -> 
          Bgp_log.debug (fun m -> m "Connection collision detected and dump new connection.");
          Bgp_flow.close flow
      end
    in
    Bgp_flow.listen s (Key_gen.local_port ()) on_connect
  ;;
                    
  let send_msg t msg = 
    match t.flow with
    | Some flow ->
      Bgp_log.info (fun m -> m "send message %s" (Bgp.to_string msg));
      Bgp_flow.write flow msg
      >>= begin function
      | Error err ->
        (match err with
        | `Timeout -> Bgp_log.debug (fun m -> m "Timeout when write %s" (Bgp.to_string msg))
        | `Refused -> Bgp_log.debug (fun m -> m "Refused when Write %s" (Bgp.to_string msg))
        | `Closed -> Bgp_log.debug (fun m -> m "Connection closed when write %s." (Bgp.to_string msg)) 
        | _ -> ());
        Lwt.return_unit
      | Ok () -> Lwt.return_unit
      end    
    | None -> Lwt.return_unit
  ;;

  let send_open_msg (t: t) =
    let open Bgp in
    let open Fsm in
    let o = {
      version = 4;
      bgp_id = Ipaddr.V4.to_int32 t.local_id;
      my_as = Asn t.local_asn;
      hold_time = t.fsm.hold_time;
      options = [];
    } in
    send_msg t (Bgp.Open o) 
  ;;

  let drop_tcp_connection t =    
    (match t.conn_starter with
    | None -> ()
    | Some d -> 
      Bgp_log.debug (fun m -> m "close conn starter."); 
      t.conn_starter <- None;
      Device.stop d);

    (match t.tcp_flow_reader with
    | None -> ()
    | Some d -> 
      Bgp_log.debug (fun m -> m "close flow reader."); 
      t.tcp_flow_reader <- None;
      Device.stop d);
    
    match t.flow with
    | None -> Lwt.return_unit
    | Some flow ->
      Bgp_log.debug (fun m -> m "close flow."); 
      t.flow <- None; 
      Bgp_flow.close flow;
  ;;

  let rec perform_action t action =
    let open Fsm in
    let callback = fun event -> handle_event t event in
    match action with
    | Initiate_tcp_connection -> init_tcp_connection t callback
    | Send_open_msg -> send_open_msg t
    | Send_msg msg -> send_msg t msg
    | Drop_tcp_connection -> drop_tcp_connection t
    | Start_conn_retry_timer -> 
      if (t.fsm.conn_retry_time > 0) then begin
        let callback () =
          t.conn_retry_timer <- None;
          handle_event t Connection_retry_timer_expired
        in
        t.conn_retry_timer <- Some (create_timer t.fsm.conn_retry_time callback);
      end;
      Lwt.return_unit
    | Stop_conn_retry_timer -> begin
      match t.conn_retry_timer with
      | None -> Lwt.return_unit
      | Some d -> t.conn_retry_timer <- None; Device.stop d; Lwt.return_unit
    end
    | Reset_conn_retry_timer -> begin
      (match t.conn_retry_timer with
      | None -> ()
      | Some t -> Device.stop t);
      if (t.fsm.conn_retry_time > 0) then begin
        let callback () =
          t.conn_retry_timer <- None;
          handle_event t Connection_retry_timer_expired
        in
        t.conn_retry_timer <- Some (create_timer t.fsm.conn_retry_time callback);
      end;
      Lwt.return_unit
    end
    | Start_hold_timer ht -> 
      if (t.fsm.hold_time > 0) then 
        t.hold_timer <- Some (create_timer ht (fun () -> t.hold_timer <- None; handle_event t Hold_timer_expired));
      Lwt.return_unit
    | Stop_hold_timer -> begin
      match t.hold_timer with
      | None -> Lwt.return_unit
      | Some d -> t.hold_timer <- None; Device.stop d; Lwt.return_unit
    end
    | Reset_hold_timer ht -> begin
      (match t.hold_timer with
      | None -> ()
      | Some d -> Device.stop d);
      if (t.fsm.hold_time > 0) then 
        t.hold_timer <- Some (create_timer ht (fun () -> t.hold_timer <- None; handle_event t Hold_timer_expired));
      Lwt.return_unit
    end
    | Start_keepalive_timer -> 
      if (t.fsm.keepalive_time > 0) then 
        t.keepalive_timer <- Some (create_timer t.fsm.keepalive_time 
                            (fun () -> t.keepalive_timer <- None; handle_event t Keepalive_timer_expired));
      Lwt.return_unit
    | Stop_keepalive_timer -> begin
      match t.keepalive_timer with
      | None -> Lwt.return_unit
      | Some d -> t.keepalive_timer <- None; Device.stop d; Lwt.return_unit
    end
    | Reset_keepalive_timer -> begin
      (match t.keepalive_timer with
      | None -> ()
      | Some t -> Device.stop t);
      if (t.fsm.keepalive_time > 0) then 
        t.keepalive_timer <- Some (create_timer t.fsm.keepalive_time 
                            (fun () -> t.keepalive_timer <- None; handle_event t Keepalive_timer_expired));
      Lwt.return_unit
    end
    | Process_update_msg u -> begin
      let converted = Util.Bgp_to_Rib.convert_update u in
      match t.input_rib with
      | None -> Lwt.fail_with "Input RIB not initiated."
      | Some rib -> Rib.Adj_rib.handle_update rib converted
    end
    | Initiate_rib ->
      let input_rib = 
        let callback u = Rib.Loc_rib.handle_signal t.loc_rib (Rib.Loc_rib.Update (u, t.remote_id)) in
        Rib.Adj_rib.create t.remote_id callback
      in
      t.input_rib <- Some input_rib;

      let output_rib =
        let callback u = 
          let converted = Util.Rib_to_Bgp.convert_update u in
          send_msg t (Bgp.Update converted)
        in
        Rib.Adj_rib.create t.remote_id callback
      in
      t.output_rib <- Some output_rib;

      Rib.Loc_rib.handle_signal t.loc_rib (Rib.Loc_rib.Subscribe output_rib)
    | Release_rib ->
      t.input_rib <- None;
      match t.output_rib with
      | None -> Lwt.return_unit
      | Some rib -> t.output_rib <- None; Rib.Loc_rib.handle_signal t.loc_rib (Rib.Loc_rib.Unsubscribe rib)
  
  and handle_event t event =
    (* Bgp_log.debug (fun m -> m "%s" (Fsm.event_to_string event)); *)
    let new_fsm, actions = Fsm.handle t.fsm event in
    t.fsm <- new_fsm;
    (* Spawn threads to perform actions from left to right *)
    let _ = List.fold_left (fun acc act -> List.cons (perform_action t act) acc) [] actions in
    Lwt.return_unit
  ;;

  let rec loop t =
    Lwt_io.read_line Lwt_io.stdin
    >>= function
    | "start" -> 
      Bgp_log.info (fun m -> m "BGP starts.");
      handle_event t (Fsm.Manual_start) 
      >>= fun () -> 
      loop t
    | "stop" -> 
      Bgp_log.info (fun m -> m "BGP stops.");
      handle_event t (Fsm.Manual_stop)
      >>= fun () ->
      loop t
    | "exit" -> 
      handle_event t (Fsm.Manual_stop)
      >>= fun () ->
      Bgp_log.info (fun m -> m "BGP exits.");
      S.disconnect t.socket
      >>= fun () ->
      Lwt.return_unit
    | "show fsm" ->
      Bgp_log.info (fun m -> m "status: %s" (Fsm.to_string t.fsm));
      loop t
    | "show device" ->
      let dev1 = if not (t.conn_retry_timer = None) then "Conn retry timer" else "" in
      let dev2 = if not (t.hold_timer = None) then "Hold timer" else "" in 
      let dev3 = if not (t.keepalive_timer = None) then "Keepalive timer" else "" in 
      let dev4 = if not (t.conn_starter = None) then "Conn starter" else "" in 
      let dev5 = if not (t.tcp_flow_reader = None) then "Flow reader" else "" in 
      let str_list = List.filter (fun x -> not (x = "")) ["Running device:"; dev1; dev2; dev3; dev4; dev5] in
      Bgp_log.info (fun m -> m "%s" (String.concat "\n" str_list));
      loop t
    | "show rib" ->
      let input = 
        match t.input_rib with
        | None -> "No IN RIB."
        | Some rib -> Printf.sprintf "Adj_RIB_IN %d" (Rib.Adj_rib.size rib)
      in

      let loc = Printf.sprintf "Loc_RIB %d" (Rib.Loc_rib.size t.loc_rib) in

      let output = 
        match t.output_rib with
        | None -> "No OUT RIB"
        | Some rib -> Printf.sprintf "Adj_RIB_OUT %d" (Rib.Adj_rib.size rib)
      in
      
      Bgp_log.info (fun m -> m "%s" (String.concat ", " [input; loc; output]));
      loop t
    | "show rib detail" ->
      (match t.input_rib with
      | None -> Bgp_log.warn (fun m -> m "No IN RIB.");
      | Some rib -> Bgp_log.info (fun m -> m "Adj_RIB_IN \n %s" (Rib.Adj_rib.to_string rib)));

      Bgp_log.info (fun m -> m "%s" (Rib.Loc_rib.to_string t.loc_rib));

      (match t.output_rib with
      | None -> Bgp_log.warn (fun m -> m "No OUT RIB.");
      | Some rib -> Bgp_log.info (fun m -> m "Adj_RIB_OUT \n %s" (Rib.Adj_rib.to_string rib)));
      
      loop t
    | "show gc" ->
      let word_to_KB ws = ws * 8 / 1024 in

      let gc_stat = Gc.stat () in
      let open Gc in
      let allocation = Printf.sprintf "Minor: %.0f, Promoted: %.0f, Major %.0f" 
                              gc_stat.minor_words gc_stat.promoted_words gc_stat.major_words in
      let size = Printf.sprintf "Heap size: %d KB, Stack size: %d KB" 
                              (word_to_KB gc_stat.heap_words) (word_to_KB gc_stat.stack_size) in
      let collection = Printf.sprintf "Minor collection: %d, Major collection: %d, Compaction: %d" 
                              gc_stat.minor_collections gc_stat.major_collections gc_stat.compactions in
      Bgp_log.info (fun m -> m "%s" (String.concat "\n" ["GC stat:"; allocation; size; collection]));
      
      loop t
    | _ -> loop t
  ;;

  let start_bgp remote_id local_id local_asn socket =

    let fsm = Fsm.create 30 45 15 in
    let flow = None in
    let t = {
      remote_id; local_id; local_asn; 
      socket; fsm; flow;
      conn_retry_timer = None; 
      hold_timer = None; 
      keepalive_timer = None;
      conn_starter = None;
      tcp_flow_reader = None;
      input_rib = None;
      output_rib = None;
      loc_rib = Rib.Loc_rib.create;
    } in


    let id_map = Id_map.add t.remote_id t Id_map.empty in

    (* Start listening to BGP port. *)
    listen_tcp_connection socket id_map handle_event;

    loop t
  ;;

  let start s =
    let remote_id = Ipaddr.V4.of_string_exn (Key_gen.remote_id ()) in
    let local_id = Ipaddr.V4.of_string_exn (Key_gen.local_id ()) in
    let local_asn = Key_gen.local_asn () in  
    start_bgp remote_id local_id local_asn s
  ;;
end