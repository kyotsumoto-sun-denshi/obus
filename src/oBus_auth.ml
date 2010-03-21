(*
 * oBus_auth.ml
 * ------------
 * Copyright : (c) 2008, Jeremie Dimino <jeremie@dimino.org>
 * Licence   : BSD3
 *
 * This file is a part of obus, an ocaml implementation of D-Bus.
 *)

let section = Lwt_log.Section.make "obus(auth)"

open Printf
open Lwt

type capability = [ `Unix_fd ]

let capabilities = [`Unix_fd]

(* Maximum line length, if line greated are received, authentication
   will fail *)
let max_line_length = 42 * 1024

(* Maximum number of reject, if a client is rejected more than that,
   authentication will fail *)
let max_reject = 42

exception Auth_failure of string
let auth_failure fmt = ksprintf (fun msg -> fail (Auth_failure msg)) fmt

let () =
  Printexc.register_printer
    (function
       | Auth_failure msg ->
           Some(Printf.sprintf "D-Bus authentication failed: %s" msg)
       | _ ->
           None)

let hex_encode = OBus_util.hex_encode
let hex_decode str =
  try
    OBus_util.hex_decode str
  with
    | Invalid_argument _ -> failwith "invalid hex-encoded data"

type data = string

type client_command =
  | Client_auth of (string * data option) option
  | Client_cancel
  | Client_begin
  | Client_data of data
  | Client_error of string
  | Client_negotiate_unix_fd

type server_command =
  | Server_rejected of string list
  | Server_ok of OBus_address.guid
  | Server_data of data
  | Server_error of string
  | Server_agree_unix_fd

(* +-----------------------------------------------------------------+
   | Keyring for the SHA-1 method                                    |
   +-----------------------------------------------------------------+ *)

module Cookie =
struct
  type t = {
    id : int32;
    time : int64;
    cookie : string;
  } with projection
end

module Keyring : sig

  type context = string
      (** A context for the SHA-1 method *)

  val load : context -> Cookie.t list Lwt.t
    (** [load context] load all cookies for context [context] *)

  val save : context -> Cookie.t list -> unit Lwt.t
    (** [save context cookies] save all cookies with context
        [context] *)
end = struct

  type context = string

  let keyring_directory = lazy(Filename.concat (Lazy.force OBus_util.homedir) ".dbus-keyrings")

  let keyring_file_name context =
    Filename.concat (Lazy.force keyring_directory) context

  let parse_line line =
    Scanf.sscanf line "%ld %Ld %[a-fA-F0-9]"
      (fun id time cookie -> { Cookie.id = id;
                               Cookie.time = time;
                               Cookie.cookie = cookie })

  let print_line cookie =
    sprintf  "%ld %Ld %s" (Cookie.id cookie) (Cookie.time cookie) (Cookie.cookie cookie)

  let load context =
    let fname = keyring_file_name context in
    if Sys.file_exists fname then
      try_lwt
        Lwt_stream.get_while (fun _ -> true) (Lwt_stream.map parse_line (Lwt_io.lines_of_file fname))
      with exn ->
        lwt () = Lwt_log.error_f ~section "failed to load cookie file %s: %s" (keyring_file_name context) (Printexc.to_string exn) in
        fail exn
    else
      return []

  let lock_file fname =
    let really_lock () =
      Unix.close(Unix.openfile fname
                   [Unix.O_WRONLY;
                    Unix.O_EXCL;
                    Unix.O_CREAT] 0o600)
    in
    let rec aux = function
      | 0 ->
          lwt () =
            try_lwt
              Unix.unlink fname;
              Lwt_log.info_f ~section "stale lock file %s removed" fname
            with Unix.Unix_error(error, _, _) as exn ->
              lwt () = Lwt_log.error_f ~section "failed to remove stale lock file %s: %s" fname (Unix.error_message error) in
              fail exn
          in
          (try_lwt
             really_lock ();
             return ()
           with Unix.Unix_error(error, _, _) as exn ->
             lwt () = Lwt_log.error_f ~section "failed to lock file %s after removing it: %s" fname (Unix.error_message error) in
             fail exn)
      | n ->
          try_lwt
            really_lock ();
            return ()
          with exn ->
            lwt () = Lwt_log.info_f ~section "waiting for lock file (%d) %s" n fname in
            lwt () = Lwt_unix.sleep 0.250 in
            aux (n - 1)
    in
    aux 32

  let unlock_file fname =
    try_lwt
      Unix.unlink fname;
      return ()
    with Unix.Unix_error(error, _, _) as exn ->
      lwt () = Lwt_log.error_f ~section "failed to unlink file %s: %s" fname (Unix.error_message error) in
      fail exn

  let save context cookies =
    let fname = keyring_file_name context in
    let tmp_fname = fname ^ "." ^ hex_encode (OBus_util.random_string 8) in
    let lock_fname = fname ^ ".lock" in
    let lazy dir = keyring_directory in
    (* Check that the keyring directory exists, or create it *)
    if not (Sys.file_exists dir) then begin
      try
        Unix.mkdir dir 0o700
      with Unix.Unix_error(error, _, _) as exn ->
        ignore (Lwt_log.error_f ~section "failed to create directory %s with permissions 0600: %s" dir (Unix.error_message error));
        raise exn
    end;
    lwt () = lock_file lock_fname in
    try_lwt
      lwt () =
        try_lwt
          Lwt_io.lines_to_file tmp_fname (Lwt_stream.map print_line (Lwt_stream.of_list cookies))
        with exn ->
          lwt () = Lwt_log.error_f ~section "unable to write temporary keyring file %s: %s" tmp_fname (Printexc.to_string exn) in
          fail exn
      in
      try
        Unix.rename tmp_fname fname;
        return ()
      with Unix.Unix_error(error, _, _) as exn ->
        lwt () = Lwt_log.error_f ~section "unable to rename file %s to %s: %s" tmp_fname fname (Unix.error_message error) in
        fail exn
      finally
        unlock_file lock_fname
end

(* +-----------------------------------------------------------------+
   | Communication                                                   |
   +-----------------------------------------------------------------+ *)

type stream = {
  recv : unit -> string Lwt.t;
  send : string -> unit Lwt.t;
}

let make_stream ~recv ~send = {
  recv = (fun () ->
            try_lwt
              recv ()
            with
              | Auth_failure _ as exn ->
                  fail exn
              | End_of_file ->
                  fail (Auth_failure("input: premature end of input"))
              | exn ->
                  fail (Auth_failure("input: " ^ Printexc.to_string exn)));
  send = (fun line ->
            try_lwt
              send line
            with
              | Auth_failure _ as exn ->
                  fail exn
              | exn ->
                  fail (Auth_failure("output: " ^ Printexc.to_string exn)));
}

let stream_of_channels (ic, oc) =
  make_stream
    ~recv:(fun () ->
             let buf = Buffer.create 42 in
             let rec loop last =
               if Buffer.length buf > max_line_length then
                 fail (Auth_failure "input: line too long")
               else
                 Lwt_io.read_char_opt ic >>= function
                   | None ->
                       fail (Auth_failure "input: premature end of input")
                   | Some ch ->
                       Buffer.add_char buf ch;
                       if last = '\r' && ch = '\n' then
                         return (Buffer.contents buf)
                       else
                         loop ch
             in
             loop '\x00')
    ~send:(fun line ->
             lwt () = Lwt_io.write oc line in
             Lwt_io.flush oc)

let stream_of_fd fd =
  make_stream
    ~recv:(fun () ->
             (* Note: we cannot use buffering here. Indeed, if we use
                buffereing then when the "BEGIN\r\n" command is
                received, it may be followed be the first message
                which may contains file descriptors that would be
                dropped. *)
             let buf = Buffer.create 42 and tmp = String.create 1  in
             let rec loop last =
               if Buffer.length buf > max_line_length then
                 fail (Auth_failure "input: line too long")
               else
                 Lwt_unix.read fd tmp 0 1 >>= function
                   | 0 ->
                       fail (Auth_failure "input: premature end of input")
                   | n ->
                       assert (n = 1);
                       let ch = tmp.[0] in
                       Buffer.add_char buf ch;
                       if last = '\r' && ch = '\n' then
                         return (Buffer.contents buf)
                       else
                         loop ch
             in
             loop '\x00')
    ~send:(fun line ->
             let rec loop ofs len =
               if len = 0 then
                 return ()
               else
                 Lwt_unix.write fd line ofs len >>= function
                   | 0 ->
                       fail (Auth_failure "output: zero byte written")
                   | n ->
                       assert (n > 0 && n <= len);
                       loop (ofs + n) (len - n)
             in
             loop 0 (String.length line))

let send_line mode stream line =
  ignore (Lwt_log.debug_f ~section "%s: sending: %S" mode line);
  stream.send (line ^ "\r\n")

let rec recv_line stream =
  lwt line = stream.recv () in
  let len = String.length line in
  if len < 2 || not (line.[len - 2] = '\r' && line.[len - 1] = '\n') then
    fail (Auth_failure("input: invalid line received"))
  else
    return (String.sub line 0 (len - 2))

let rec first f str pos =
  if pos = String.length str then
    pos
  else match f str.[pos] with
    | true -> pos
    | false -> first f str (pos + 1)

let rec last f str pos =
  if pos = 0 then
    pos
  else match f str.[pos - 1] with
    | true -> pos
    | false -> first f str (pos - 1)

let blank ch = ch = ' ' || ch = '\t'
let not_blank ch = not (blank ch)

let sub_strip str i j =
  let i = first not_blank str i in
  let j = last not_blank str j in
  if i < j then String.sub str i (j - i) else ""

let split str =
  let rec aux i =
    let i = first not_blank str i in
    if i = String.length str then
      []
    else
      let j = first blank str i in
      String.sub str i (j - i) :: aux j
  in
  aux 0

let preprocess_line line =
  (* Check for ascii-only *)
  String.iter (function
                 | '\x01'..'\x7f' -> ()
                 | _ -> failwith "non-ascii characters in command") line;
  (* Extract the command *)
  let i = first blank line 0 in
  if i = 0 then failwith "empty command";
  (String.sub line 0 i, sub_strip line i (String.length line))

let rec recv mode command_parser stream =
  lwt line = recv_line stream in
  lwt () = Lwt_log.debug_f ~section "%s: received: %S" mode line in

  (* If a parse failure occur, return an error and try again *)
  match
    try
      let command, args = preprocess_line line in
      `Success(command_parser command args)
    with exn ->
      `Failure(exn)
  with
    | `Success x -> return x
    | `Failure(Failure msg) ->
        lwt () = send_line mode stream ("ERROR \"" ^ msg ^ "\"") in
        recv mode command_parser stream
    | `Failure exn -> fail exn

let client_recv = recv "client"
  (fun command args -> match command with
     | "REJECTED" -> Server_rejected (split args)
     | "OK" -> Server_ok(try OBus_uuid.of_string args with _ -> failwith "invalid hex-encoded guid")
     | "DATA" -> Server_data(hex_decode args)
     | "ERROR" -> Server_error args
     | "AGREE_UNIX_FD" -> Server_agree_unix_fd
     | _ -> failwith "invalid command")

let server_recv = recv "server"
  (fun command args -> match command with
     | "AUTH" -> Client_auth(match split args with
                               | [] -> None
                               | [mech] -> Some(mech, None)
                               | [mech; data] -> Some(mech, Some(hex_decode data))
                               | _ -> failwith "too many arguments")
     | "CANCEL" -> Client_cancel
     | "BEGIN" -> Client_begin
     | "DATA" -> Client_data(hex_decode args)
     | "ERROR" -> Client_error args
     | "NEGOTIATE_UNIX_FD" -> Client_negotiate_unix_fd
     | _ -> failwith "invalid command")

let client_send chans cmd = send_line "client" chans
  (match cmd with
     | Client_auth None -> "AUTH"
     | Client_auth(Some(mechanism, None)) -> sprintf "AUTH %s" mechanism
     | Client_auth(Some(mechanism, Some data)) -> sprintf "AUTH %s %s" mechanism (hex_encode data)
     | Client_cancel -> "CANCEL"
     | Client_begin -> "BEGIN"
     | Client_data data -> sprintf "DATA %s" (hex_encode data)
     | Client_error msg -> sprintf "ERROR \"%s\"" msg
     | Client_negotiate_unix_fd -> "NEGOTIATE_UNIX_FD")

let server_send chans cmd = send_line "server" chans
  (match cmd with
     | Server_rejected mechs -> String.concat " " ("REJECTED" :: mechs)
     | Server_ok guid -> sprintf "OK %s" (OBus_uuid.to_string guid)
     | Server_data data -> sprintf "DATA %s" (hex_encode data)
     | Server_error msg -> sprintf "ERROR \"%s\"" msg
     | Server_agree_unix_fd -> "AGREE_UNIX_FD")

(* +-----------------------------------------------------------------+
   | Client side authentication                                      |
   +-----------------------------------------------------------------+ *)

module Client =
struct

  type mechanism_return =
    | Mech_continue of data
    | Mech_ok of data
    | Mech_error of string

  class virtual mechanism_handler = object
    method virtual init : mechanism_return Lwt.t
    method data (chall : data) = return (Mech_error("no data expected for this mechanism"))
    method abort = ()
  end

  type mechanism = {
    mech_name : string;
    mech_exec : unit -> mechanism_handler;
  } with projection

  (* +---------------------------------------------------------------+
     | Predefined client mechanisms                                  |
     +---------------------------------------------------------------+ *)

  class mech_external_handler = object
    inherit mechanism_handler
    method init = return (Mech_ok(string_of_int (Unix.getuid ())))
  end

  class mech_anonymous_handler = object
    inherit mechanism_handler
    method init = return (Mech_ok("obus " ^ OBus_info.version))
  end

  class mech_dbus_cookie_sha1_handler = object
    method init = return (Mech_continue(string_of_int (Unix.getuid ())))
    method data chal =
      lwt () = Lwt_log.debug_f ~section "client: dbus_cookie_sha1: chal: %s" chal in
      let context, id, chal = Scanf.sscanf chal "%[^/\\ \n\r.] %ld %[a-fA-F0-9]%!" (fun context id chal -> (context, id, chal)) in
      lwt keyring = Keyring.load context in
      let cookie =
        try
          List.find (fun cookie -> cookie.Cookie.id = id) keyring
        with Not_found ->
          ksprintf failwith "cookie %ld not found in context %S" id context
      in
      let rand = hex_encode (OBus_util.random_string 16) in
      let resp = sprintf "%s %s" rand (hex_encode (OBus_util.sha_1 (sprintf "%s:%s:%s" chal rand cookie.Cookie.cookie))) in
      lwt () = Lwt_log.debug_f ~section "client: dbus_cookie_sha1: resp: %s" resp in
      return (Mech_ok resp)
    method abort = ()
  end

  let mech_external = {
    mech_name = "EXTERNAL";
    mech_exec = (fun () -> new mech_external_handler);
  }
  let mech_anonymous = {
    mech_name = "ANONYMOUS";
    mech_exec = (fun () -> new mech_anonymous_handler);
  }
  let mech_dbus_cookie_sha1 = {
    mech_name = "DBUS_COOKIE_SHA1";
    mech_exec = (fun () -> new mech_dbus_cookie_sha1_handler);
  }

  let default_mechanisms = [mech_external;
                            mech_dbus_cookie_sha1;
                            mech_anonymous]

  (* +---------------------------------------------------------------+
     | Client-side protocol                                          |
     +---------------------------------------------------------------+ *)

  type state =
    | Waiting_for_data of mechanism_handler
    | Waiting_for_ok
    | Waiting_for_reject

  type transition =
    | Transition of client_command * state * mechanism list
    | Success of OBus_address.guid
    | Failure

  (* Try to find a mechanism that can be initialised *)
  let find_working_mech implemented_mechanisms available_mechanisms =
    let rec aux = function
      | [] ->
          return Failure
      | { mech_name = name; mech_exec =  f } :: mechs ->
          match available_mechanisms with
            | Some l when not (List.mem name l) ->
                aux mechs
            | _ ->
                let mech = f () in
                try_lwt
                  mech#init >>= function
                    | Mech_continue resp ->
                        return (Transition(Client_auth(Some (name, Some resp)),
                                           Waiting_for_data mech,
                                           mechs))
                    | Mech_ok resp ->
                        return (Transition(Client_auth(Some (name, Some resp)),
                                           Waiting_for_ok,
                                           mechs))
                    | Mech_error msg ->
                        aux mechs
                with exn ->
                  aux mechs
    in
    aux implemented_mechanisms

  let initial mechs = find_working_mech mechs None
  let next mechs available = find_working_mech mechs (Some available)

  let transition mechs state cmd = match state with
    | Waiting_for_data mech -> begin match cmd with
        | Server_data chal ->
            begin
              try_lwt
                mech#data chal >>= function
                  | Mech_continue resp ->
                      return (Transition(Client_data resp,
                                         Waiting_for_data mech,
                                         mechs))
                  | Mech_ok resp ->
                      return (Transition(Client_data resp,
                                         Waiting_for_ok,
                                         mechs))
                  | Mech_error msg ->
                      return (Transition(Client_error msg,
                                         Waiting_for_data mech,
                                         mechs))
              with exn ->
                return (Transition(Client_error(Printexc.to_string exn),
                                   Waiting_for_data mech,
                                   mechs))
            end
        | Server_rejected am ->
            mech#abort;
            next mechs am
        | Server_error _ ->
            mech#abort;
            return (Transition(Client_cancel,
                               Waiting_for_reject,
                               mechs))
        | Server_ok guid ->
            mech#abort;
            return (Success guid)
        | Server_agree_unix_fd ->
            mech#abort;
            return (Transition(Client_error "command not expected here",
                               Waiting_for_data mech,
                               mechs))
      end

    | Waiting_for_ok -> begin match cmd with
        | Server_ok guid ->
            return (Success guid)
        | Server_rejected am ->
            next mechs am
        | Server_data _
        | Server_error _ ->
            return (Transition(Client_cancel,
                               Waiting_for_reject,
                               mechs))
        | Server_agree_unix_fd ->
            return (Transition(Client_error "command not expected here",
                               Waiting_for_ok,
                               mechs))
      end

    | Waiting_for_reject -> begin match cmd with
        | Server_rejected am -> next mechs am
        | _ -> return Failure
      end

  let authenticate ?(capabilities=[]) ?(mechanisms=default_mechanisms) ~stream () =
    let rec loop = function
      | Transition(cmd, state, mechs) ->
          lwt () = client_send stream cmd in
          lwt cmd = client_recv stream in
          transition mechs state cmd >>= loop
      | Success guid ->
          lwt caps =
            if List.mem `Unix_fd capabilities then
              lwt () = client_send stream Client_negotiate_unix_fd in
              client_recv stream >>= function
                | Server_agree_unix_fd ->
                    return [`Unix_fd]
                | Server_error _ ->
                    return []
                | _ ->
                    (* This case is not covered by the
                       specification *)
                    return []
            else
              return []
          in
          lwt () = client_send stream Client_begin in
          return (guid, caps)
      | Failure ->
          auth_failure "authentication failure"
    in
    initial mechanisms >>= loop
end

(* +-----------------------------------------------------------------+
   | Server-side authentication                                      |
   +-----------------------------------------------------------------+ *)

module Server =
struct

  type mechanism_return =
    | Mech_continue of data
    | Mech_ok of int option
    | Mech_reject

  class virtual mechanism_handler = object
    method init = return (None : data option)
    method virtual data : data -> mechanism_return Lwt.t
    method abort = ()
  end

  type mechanism = {
    mech_name : string;
    mech_exec : int option -> mechanism_handler;
  } with projection

  (* +---------------------------------------------------------------+
     | Predefined server mechanisms                                  |
     +---------------------------------------------------------------+ *)

  class mech_external_handler user_id = object
    inherit mechanism_handler
    method data data =
      match user_id, try Some(int_of_string data) with _ -> None with
        | Some user_id, Some user_id' when user_id = user_id' ->
            return (Mech_ok(Some user_id))
        | _ ->
            return Mech_reject
  end

  class mech_anonymous_handler = object
    inherit mechanism_handler
    method data _ = return (Mech_ok None)
  end

  class mech_dbus_cookie_sha1_handler = object
    inherit mechanism_handler

    val context = "org_freedesktop_general"
    val mutable state = `State1
    val mutable user_id = None

    method data resp =
      try_lwt
        lwt () = Lwt_log.debug_f ~section "server: dbus_cookie_sha1: resp: %s" resp in
        match state with
          | `State1 ->
              user_id <- (try Some(int_of_string resp) with _ -> None);
              lwt keyring = Keyring.load context in
              let cur_time = Int64.of_float (Unix.time ()) in
              (* Filter old and future keys *)
              let keyring = List.filter (fun { Cookie.time = time } -> time <= cur_time && Int64.sub cur_time time <= 300L) keyring in
              (* Find a working cookie *)
              lwt id, cookie = match keyring with
                | { Cookie.id = id; Cookie.cookie = cookie } :: _ ->
                    (* There is still valid cookies, just choose one *)
                    return (id, cookie)
                | [] ->
                    (* No one left, generate a new one *)
                    let id = Int32.abs (OBus_util.random_int32 ()) in
                    let cookie = hex_encode (OBus_util.random_string 24) in
                    lwt () = Keyring.save context [{ Cookie.id = id; Cookie.time = cur_time; Cookie.cookie = cookie }] in
                    return (id, cookie)
              in
              let rand = hex_encode (OBus_util.random_string 16) in
              let chal = sprintf "%s %ld %s" context id rand in
              lwt () = Lwt_log.debug_f ~section "server: dbus_cookie_sha1: chal: %s" chal in
              state <- `State2(cookie, rand);
              return (Mech_continue chal)

          | `State2(cookie, my_rand) ->
              Scanf.sscanf resp "%s %s"
                (fun its_rand comp_sha1 ->
                   if OBus_util.sha_1 (sprintf "%s:%s:%s" my_rand its_rand cookie) = hex_decode comp_sha1 then
                     return (Mech_ok user_id)
                   else
                     return Mech_reject)

      with _ ->
        return Mech_reject

    method abort = ()
  end

  let mech_anonymous = {
    mech_name = "ANONYMOUS";
    mech_exec = (fun uid -> new mech_anonymous_handler);
  }
  let mech_external = {
    mech_name = "EXTERNAL";
    mech_exec = (fun uid -> new mech_external_handler uid);
  }
  let mech_dbus_cookie_sha1 = {
    mech_name = "DBUS_COOKIE_SHA1";
    mech_exec = (fun uid -> new mech_dbus_cookie_sha1_handler);
  }

  let default_mechanisms = [mech_external;
                            mech_dbus_cookie_sha1;
                            mech_anonymous]

  (* +---------------------------------------------------------------+
     | Server-side protocol                                          |
     +---------------------------------------------------------------+ *)

  type state =
    | Waiting_for_auth
    | Waiting_for_data of mechanism_handler
    | Waiting_for_begin of int option * capability list

  type server_machine_transition =
    | Transition of server_command * state
    | Accept of int option * capability list
    | Failure

  let reject mechs =
    return (Transition(Server_rejected (List.map mech_name mechs),
                       Waiting_for_auth))

  let error msg =
    return (Transition(Server_error msg,
                       Waiting_for_auth))

  let transition user_id guid capabilities mechs state cmd = match state with
    | Waiting_for_auth -> begin match cmd with
        | Client_auth None ->
            reject mechs
        | Client_auth(Some(name, resp)) ->
            begin match OBus_util.find_map (fun m -> if m.mech_name = name then Some m.mech_exec else None) mechs with
              | None ->
                  reject mechs
              | Some f ->
                  let mech = f user_id in
                  try_lwt
                    lwt init = mech#init in
                    match init, resp with
                      | None, None ->
                          return (Transition(Server_data "",
                                             Waiting_for_data mech))
                      | Some chal, None ->
                          return (Transition(Server_data chal,
                                             Waiting_for_data mech))
                      | Some chal, Some rest ->
                          reject mechs
                      | None, Some resp ->
                          mech#data resp >>= function
                            | Mech_continue chal ->
                                return (Transition(Server_data chal,
                                                   Waiting_for_data mech))
                            | Mech_ok uid ->
                                return (Transition(Server_ok guid,
                                                   Waiting_for_begin(uid, [])))
                            | Mech_reject ->
                                reject mechs
                  with exn ->
                    reject mechs
            end
        | Client_begin -> return Failure
        | Client_error msg -> reject mechs
        | _ -> error "AUTH command expected"
      end

    | Waiting_for_data mech -> begin match cmd with
        | Client_data "" ->
            return (Transition(Server_data "",
                               Waiting_for_data mech))
        | Client_data resp -> begin
            try_lwt
              mech#data resp >>= function
                | Mech_continue chal ->
                    return (Transition(Server_data chal,
                                       Waiting_for_data mech))
                | Mech_ok uid ->
                    return (Transition(Server_ok guid,
                                       Waiting_for_begin(uid, [])))
                | Mech_reject ->
                    reject mechs
            with exn ->
              reject mechs
          end
        | Client_begin -> mech#abort; return Failure
        | Client_cancel -> mech#abort; reject mechs
        | Client_error _ -> mech#abort; reject mechs
        | _ -> mech#abort; error "DATA command expected"
      end

    | Waiting_for_begin(uid, caps) -> begin match cmd with
        | Client_begin ->
            return (Accept(uid, caps))
        | Client_cancel ->
            reject mechs
        | Client_error _ ->
            reject mechs
        | Client_negotiate_unix_fd ->
            if List.mem `Unix_fd capabilities then
              return(Transition(Server_agree_unix_fd,
                                Waiting_for_begin(uid,
                                                  if List.mem `Unix_fd caps then
                                                    caps
                                                  else
                                                    `Unix_fd :: caps)))
            else
              return(Transition(Server_error "Unix fd passing is not supported by this server",
                                Waiting_for_begin(uid, caps)))
        | _ ->
            error "BEGIN command expected"
      end

  let authenticate ?(capabilities=[]) ?(mechanisms=default_mechanisms) ?user_id ~guid ~stream () =
    let rec loop state count =
      lwt cmd = server_recv stream in
      transition user_id guid capabilities mechanisms state cmd >>= function
        | Transition(cmd, state) ->
            let count =
              match cmd with
                | Server_rejected _ -> count + 1
                | _ -> count
            in
            (* Specification do not specify a limit for rejected, so
               we choose one arbitrary *)
            if count >= max_reject then
              auth_failure "too many reject"
            else
              lwt () = server_send stream cmd in
              loop state count
        | Accept(uid, caps) ->
            return (uid, caps)
        | Failure ->
            auth_failure "authentication failure"
    in
    loop Waiting_for_auth 0
end
