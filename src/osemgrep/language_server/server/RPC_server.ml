(* Austin Theriault
 *
 * Copyright (C) Semgrep, Inc.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file LICENSE.
 *
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * LICENSE for more details.
 *)

(* Commentary *)
(* This contains all networking/jsonrpc related functionality of the *)
(* language server. This means that our main event loop is here, and *)
(* it's as follows: *)
(* Handle server state (uninitialized, running, stopped etc.) *)
(*  -> Read STDIN *)
(*  -> parse message to notification or request *)
(*  -> Let Semgrep LS handle notif/req *)
(*  -> If request, get response from Semgrep LS *)
(*  -> Try and complete any LWT promises *)
(*  -> Respond if needed *)
(*  -> loop *)
(*  *)
(* This module also provides some helper functions for the messsage *)
(* handler (Semgrep LS) to send notifications and requests to the *)
(* client. Any helper function should be LWT agnostic if possible. *)
(* This means wrapping it in Lwt.async, so the task will run but errors *)
(* will still surface *)
(*  *)
(* The hope here is that anything that isn't Semgrep *)
(* specific, but Language Server related, goes in here. The other goal *)
(* is that this contains as much of the Lwt code possible *)

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)

open Jsonrpc
open Lsp
open Types
module SR = Server_request
module SN = Server_notification
module CR = Client_request
module CN = Client_notification

(*****************************************************************************)
(* Server IO *)
(*****************************************************************************)

module type LSIO = sig
  val read : unit -> Jsonrpc.Packet.t option Lwt.t
  val write : Jsonrpc.Packet.t -> unit Lwt.t
  val flush : unit -> unit Lwt.t
end

module MakeLSIO (I : sig
  type input
  type output

  val stdin : input
  val stdout : output
  val read_line : input -> string option Lwt.t
  val write : output -> string -> unit Lwt.t
  val read_exactly : input -> int -> string option Lwt.t
  val flush : unit -> unit Lwt.t
  val atomic : (output -> 'a Lwt.t) -> output -> 'a Lwt.t
end) : LSIO = struct
  open
    Lsp.Io.Make
      (struct
        include Lwt

        module O = struct
          let ( let* ) x f = Lwt.bind x f
          let ( let+ ) x f = Lwt.map f x
        end

        let raise exn = Lwt.fail exn
      end)
      (I)

  let read () = read I.stdin
  let write packet = I.atomic (fun oc -> write oc packet) I.stdout
  let flush = I.flush
end

let unset_io : (module LSIO) =
  (module struct
    let read () =
      failwith
        "IO not set. This is a bug in the language server. Please report it \
         with the command you ran to get this error"

    let write _ =
      failwith
        "IO not set. This is a bug in the language server. Please report it \
         with the command you ran to get this error"

    let flush () =
      failwith
        "IO not set. This is a bug in the language server. Please report it \
         with the command you ran to get this error"
  end)

let io_ref : (module LSIO) ref = ref unset_io

(*****************************************************************************)
(* Types *)
(*****************************************************************************)

module State = struct
  type t = Uninitialized | Running | Stopped
end

type t = { session : Session.t; state : State.t }

type error_response = { message : string; name : string; stack : string }
[@@deriving yojson]

let error_response_of_exception message e =
  let name = Printexc.to_string e in
  let stack = Printexc.get_backtrace () in
  { message; name; stack }

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

(* Why the atomic writes below? The LSP library we use does something weird, *)
(* it writes the jsonrpc header then body with seperate calls to write, which *)
(* means there's a race condition there. The below atomic calls ensures that *)
(* the ENTIRE packet is written at the same time *)
let respond packet =
  let module Io = (val !io_ref : LSIO) in
  Logs.debug (fun m ->
      m "Sending response %s"
        (Packet.yojson_of_t packet |> Yojson.Safe.pretty_to_string));
  let%lwt () = Io.write packet in
  Io.flush ()

(** Send a request to the client *)
let request request =
  let module Io = (val !io_ref : LSIO) in
  let id = Uuidm.v `V4 |> Uuidm.to_string in
  let request = SR.to_jsonrpc_request request (`String id) in
  Logs.debug (fun m ->
      m "Sending request %s"
        (request |> Request.yojson_of_t |> Yojson.Safe.pretty_to_string));
  let packet = Packet.Request request in
  let () = Lwt.async (fun () -> Io.write packet) in
  id

(** Send a notification to the client *)
let notify notification =
  let module Io = (val !io_ref : LSIO) in
  let notification = SN.to_jsonrpc notification in
  Logs.debug (fun m ->
      m "Sending notification %s"
        (Notification.yojson_of_t notification |> Yojson.Safe.pretty_to_string));
  let packet = Packet.Notification notification in
  let%lwt () = Io.write packet in
  Io.flush ()

let notify_custom ?params method_ =
  Logs.debug (fun m -> m "Sending custom notification %s" method_);
  let jsonrpc_notif = Jsonrpc.Notification.create ~method_ ?params () in
  let server_notif = SN.of_jsonrpc jsonrpc_notif in
  match server_notif with
  | Ok notif -> Lwt.async (fun () -> notify notif)
  | Error e ->
      Logs.err (fun m -> m "Error creating notification %s: %s" method_ e)

(** Send a bunch of notifications to the client *)
let batch_notify notifications =
  Logs.debug (fun m -> m "Sending notifications");
  Lwt.async (fun () -> Lwt_list.iter_s notify notifications)

let notify_show_message ~kind s =
  Logs.debug (fun m -> m "Sending show message notification %s" s);
  let notif =
    Server_notification.ShowMessage
      { ShowMessageParams.message = s; type_ = kind }
  in
  batch_notify [ notif ]

(** Show a little progress circle while doing thing. Returns a token needed to end progress*)
let create_progress title message =
  let id = Uuidm.v `V4 |> Uuidm.to_string in
  Logs.debug (fun m ->
      m "Creating progress token %s, (%s: %s)" id title message);
  let token = ProgressToken.t_of_yojson (`String id) in
  let progress =
    SR.WorkDoneProgressCreate (WorkDoneProgressCreateParams.create token)
  in
  let _ = request progress in
  let start =
    SN.Progress.Begin (WorkDoneProgressBegin.create ~message ~title ())
  in
  let progress = SN.WorkDoneProgress (ProgressParams.create token start) in
  let () = Lwt.async (fun () -> notify progress) in
  token

(** end progress circle *)
let end_progress token =
  Logs.debug (fun m ->
      m "Ending progress token %s"
        (token |> ProgressToken.yojson_of_t |> Yojson.Safe.pretty_to_string));
  let end_ = SN.Progress.End (WorkDoneProgressEnd.create ()) in
  let progress = SN.WorkDoneProgress (ProgressParams.create token end_) in
  Lwt.async (fun () -> notify progress)

let log_error_to_client msg exn =
  (* Let's use LogMessage since it has a nice setup anyways *)
  let message =
    error_response_of_exception msg exn |> error_response_to_yojson
  in
  (* We use telemetry notification here since that's basically what this is,
     and on the client side, nothing listens to this by default, and we can pass
     arbitrary data *)
  let notif = SN.TelemetryNotification message in
  Lwt.async (fun () -> notify notif)

let notify_and_log_error msg exn =
  let trace = Printexc.get_backtrace () in
  let exn_str = Printexc.to_string exn in
  Logs.err (fun m -> m "%s: %s" msg exn_str);
  Logs.info (fun m -> m "Backtrace:\n%s" trace);
  log_error_to_client msg exn;
  notify_show_message ~kind:MessageType.Error exn_str

let error_response_of_exception id e =
  let error = Response.Error.of_exn e in
  Response.error id error

(*****************************************************************************)
(* Server *)
(*****************************************************************************)

(* Functor !!! Scary D:. Why are we using a functor here? Well it's much *)
(* cleanr to split up semgrep specific stuff (handling of messages), and *)
(* the rest of the JSONRPC + LSP stuff. But still, why functors? Well the official *)
(* OCaml LS does it this way, and this feels a lot more readable than having *)
(* to create a server and pass it functions as params *)
module Make (MessageHandler : sig
  val on_request : _ CR.t -> t -> Json.t option * t
  val on_notification : CN.t -> t -> t
  val capabilities : ServerCapabilities.t
end) =
struct
  open MessageHandler

  let handle_client_message (msg : Packet.t) server =
    let server_and_resp_opt =
      match msg with
      | Notification n when CN.of_jsonrpc n |> Result.is_ok ->
          let server =
            try on_notification (CN.of_jsonrpc n |> Result.get_ok) server with
            | e ->
                let msg =
                  Printf.sprintf "Error handling notification %s" n.method_
                in
                notify_and_log_error msg e;
                server
          in
          (server, None)
      | Request req when CR.of_jsonrpc req |> Result.is_ok -> (
          let (CR.E req_unpacked) = CR.of_jsonrpc req |> Result.get_ok in
          try
            let response_opt, server = on_request req_unpacked server in
            let response =
              Option.map
                (fun json ->
                  let response = Response.ok req.id json in
                  Packet.Response response)
                response_opt
            in
            (server, response)
          with
          | e ->
              (* Don't notify since the client will *)
              let msg =
                Printf.sprintf "Error handling request %s" req.method_
              in
              log_error_to_client msg e;
              let response = error_response_of_exception req.id e in
              (* Client will handle showing error message *)
              (server, Some (Packet.Response response)))
      | _ ->
          Logs.debug (fun m ->
              m "Unhandled message:\n%s"
                (msg |> Packet.yojson_of_t |> Yojson.Safe.pretty_to_string));
          (server, None)
    in
    Lwt.return server_and_resp_opt

  (* NOTE: this function is only used by the native version of the extension,
     but not LSP.js. [handle_client_message] is used by LSP.js though. *)
  let rec rpc_loop server () =
    let module Io = (val !io_ref : LSIO) in
    match server.state with
    | State.Stopped ->
        Logs.app (fun m -> m "Server stopped");
        Lwt.return_unit
    | _ -> (
        let%lwt client_msg = Io.read () in
        match client_msg with
        | Some msg ->
            let%lwt server =
              let%lwt server, resp_opt = handle_client_message msg server in
              ignore
                (Option.map
                   (fun packet -> Lwt.async (fun () -> respond packet))
                   resp_opt);
              Lwt.return server
            in
            rpc_loop server ()
        | None ->
            Logs.app (fun m -> m "Client disconnected");
            Lwt.return_unit)

  let start server =
    (* Set async exception hook so we error handle better *)
    Lwt.async_exception_hook := notify_and_log_error "Uncaught async exception";
    rpc_loop server ()

  (* See: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification *)

  let create caps =
    { session = Session.create caps capabilities; state = State.Uninitialized }
end
