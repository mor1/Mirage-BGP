open Lwt.Infix

let conf_log = Logs.Src.create "Conf" ~doc:"Conformance tests log"
module Conf_log = (val Logs.src_log conf_log : Logs.LOG)

module Main (S: Mirage_stack_lwt.V4) = struct 
  module Bgp_flow = Bgp_io.Make(S)

  let relay_id () = Ipaddr.V4.of_string_exn "127.0.0.1"

  let relay1 () = 
    match Key_gen.speaker () with
    | "quagga" -> Relay.quagga_relay1
    | _ -> Relay.dev_relay1
  ;;

  let relay2 () = 
    match Key_gen.speaker () with
    | "quagga" -> Relay.quagga_relay2
    | _ -> Relay.dev_relay2
  ;;

  let default_open_msg () = 
    let open Bgp in
    let open Relay in
    let o = {
      version = 4;
      bgp_id = Ipaddr.V4.to_int32 ((relay1 ()).id);
      my_as = Asn (Int32.to_int ((relay1 ()).as_no));
      options = [];
      hold_time = 180;
    } in
    Bgp.Open o
  ;;

  let fail test_name fail_reason : unit Lwt.t = 
    Conf_log.info (fun m -> m "Test %s fails: %s" test_name fail_reason);
    Lwt.fail_with test_name
  ;;

  let pass test_name = 
    Conf_log.info (fun m -> m "Pass test %s" test_name);
    Lwt.return_unit
  ;;

  let test_create_session s = 
    let test_name = "create session" in
    let open Relay in
    Bgp_flow.create_connection s (relay_id (), (relay1 ()).port)
    >>= function
    | Error _ -> fail test_name "tcp connect fail"
    | Ok flow ->
      Bgp_flow.write flow (default_open_msg ())
      >>= function
      | Error _ -> fail test_name "tcp write fail"
      | Ok () ->
        Bgp_flow.read flow
        >>= function
        | Error _ -> fail test_name "tcp read fail"
        | Ok msg ->
          let open Bgp in
          match msg with
          | Keepalive | Notification _ | Update _ -> 
            fail test_name "wrong msg type"
          | Open { bgp_id; version; my_as } ->
            Bgp_flow.write flow Bgp.Keepalive
            >>= function
            | Error _ -> fail test_name "tcp write fail"
            | Ok () ->
              Bgp_flow.read flow
              >>= function
              | Error _ -> fail test_name "tcp read fail"
              | Ok msg ->
                match msg with
                | Keepalive -> 
                  Bgp_flow.close flow
                  >>= fun () ->
                  pass test_name
                | _ -> fail test_name "wrong msg type"
  ;;


  let start s =
    Conf_log.info (fun m -> m "test starts");
    test_create_session s

end