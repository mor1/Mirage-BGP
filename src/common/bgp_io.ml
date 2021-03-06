(* Assumptions: *)
(* 1. S.TCPV4.read flow gives back a buffer. If the number of data bytes n is smaller than 4096
then the buffer has length n, otherwise, the buffer has size 4096. The rest data is given in
next read. *)

open Lwt.Infix
open Bgp

module type S = sig
  type s
  type t
  type conn_error
  type flow
  type read_error = private [>
  | `Closed
  | `PARSE_ERROR of Bgp.parse_error
  | Mirage_protocols.Tcp.error
  ]
  type write_error
  
  val create_connection : s -> Ipaddr.V4.t * int -> (t, conn_error) Result.result Lwt.t
  val listen : s -> int -> (t -> unit Lwt.t) -> unit
  val read : t -> (Bgp.t, read_error) Result.result Lwt.t
  val write : t -> Bgp.t -> (unit, write_error) Result.result Lwt.t
  val close : t -> unit Lwt.t
  val dst : t -> Ipaddr.V4.t * int
  val tcp_flow : t -> flow
end

let io_log = Logs.Src.create "IO" ~doc:"IO LOG"
module Io_log = (val Logs.src_log io_log : Logs.LOG)

module Make (S: Mirage_stack_lwt.V4) : S with type s = S.t 
                                      and type conn_error = S.TCPV4.error 
                                      and type write_error = S.TCPV4.write_error 
                                      and type flow = S.TCPV4.flow = struct
  type s = S.t
  type conn_error = S.TCPV4.error
  type flow = S.TCPV4.flow
  type read_error = private [>
  | `Closed
  | `PARSE_ERROR of Bgp.parse_error
  | Mirage_protocols.Tcp.error
  ]
  type write_error = S.TCPV4.write_error

  type t = {
    s: S.t;
    flow: flow;
    mutable buf: Cstruct.t option;
  }


  let create_connection s (addr, port) =
    S.TCPV4.create_connection (S.tcpv4 s) (addr, port)
    >>= function
    | Ok flow -> Lwt.return (Ok { s; flow; buf = None })
    | Error err -> Lwt.return (Error err)
  ;;

  let listen s port callback = 
    let wrapped flow = 
      let t = { s; flow; buf = None } in
      callback t
    in
    S.listen_tcpv4 s port wrapped
  ;;
  

  let rec read t : (Bgp.t, read_error) Result.result Lwt.t = 
    let parse t b =
      let msg_len = Bgp.get_msg_len b in
      let msg_buf, rest = Cstruct.split b msg_len in
      if Cstruct.len rest > 0 then t.buf <- Some rest else t.buf <- None;
      let parsed = Bgp.parse_buffer_to_t msg_buf in
      match parsed with 
      | Result.Ok msg -> Lwt.return (Ok msg)
      | Result.Error err -> Lwt.return (Error (`PARSE_ERROR err))
    in

    match t.buf with
    | None ->
      S.TCPV4.read t.flow
      >>= (function
      | Ok (`Eof) -> Lwt.return (Error `Closed)
      | Error err -> begin
        match err with 
        | `Refused -> Lwt.return (Error `Refused)
        | `Timeout -> Lwt.return (Error `Timeout)
        | err -> 
          Io_log.err (fun m -> m "Crash due to: %a" S.TCPV4.pp_error err);
          Lwt.fail_with "Crash due to unchecked exception."
      end
      | Ok (`Data b) -> begin
        if (Cstruct.len b < 19) || (Cstruct.len b < Bgp.get_msg_len b) then begin
          t.buf <- Some b;
          read t
        end else parse t b
      end)
    | Some b ->
      if (Cstruct.len b < 19) || (Cstruct.len b < Bgp.get_msg_len b) then
        S.TCPV4.read t.flow
        >>= fun result ->
        match result with
        | Ok (`Data buf) ->
          t.buf <- Some (Cstruct.concat [b; buf]);
          read t
        | Ok (`Eof) -> Lwt.return (Error `Closed)
        | Error err -> begin
          match err with 
          | `Refused -> Lwt.return (Error `Refused)
          | `Timeout -> Lwt.return (Error `Timeout)
          | err ->
            Io_log.err (fun m -> m "Crash due to: %a" S.TCPV4.pp_error err);
            Lwt.fail_with "Crash due to unchecked exception."
        end
      else parse t b
  ;;

  let write t msg = S.TCPV4.write t.flow (Bgp.gen_msg msg)

  let close t = S.TCPV4.close t.flow

  let dst t = S.TCPV4.dst t.flow

  let tcp_flow t = t.flow
end