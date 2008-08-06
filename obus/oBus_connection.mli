(*
 * oBus_connection.mli
 * -------------------
 * Copyright : (c) 2008, Jeremie Dimino <jeremie@dimino.org>
 * Licence   : BSD3
 *
 * This file is a part of obus, an ocaml implemtation of dbus.
 *)

(** Inerface to DBus connection *)

(** This module implement low-level manipulation of a DBus connection.
    A DBus connection is a channel opened with another application
    which also implement the DBus protocol. It is used to exchange
    DBus messages.

    It is low-level because functions of this module deals directly
    with DBus messages, as header + body. *)

type t = OBus_intern.connection

(** {6 Creation} *)

val of_transport : ?shared:bool -> OBus_transport.t -> t Lwt.t
  (** [of_transport shared transport] create a dbus connection over
      the given transport. If [shared] is true and a connection to the
      same server is already open, then it is used instead of
      [transport], this is the default behaviour. *)

val of_authenticated_transport : ?shared:bool -> OBus_transport.t -> OBus_address.guid -> t
  (** Same as of_transport but assume that the authentification is
      done. *)

val of_addresses : ?shared:bool -> OBus_address.t list -> t Lwt.t
  (** [of_addresses shared addresses] shorthand for obtaining
      transport and doing [of_transport] *)

val close : t -> unit
  (** Close a connection.

      All thread waiting for a reply will fail with the exception
      [Connection_closed].

      Note: when a connection is closed, the transport it use is
      closed too. *)

exception Connection_closed

(** {6 Informations} *)

val transport : t -> OBus_transport.t
  (** [transport connection] get the transport associated with a
      connection *)

val guid : t -> OBus_address.guid
  (** [guid connection] return the unique identifier of the server at
      the other side of the connection *)

(** {6 Sending messages} *)

val send_message : t -> 'a OBus_header.t -> ('b, unit Lwt.t, unit, _, _) OBus_comb.func -> 'b
  (** [send_message connection header typ ...] send a message without
      expecting a reply *)

val send_message_with_reply : t -> OBus_header.method_call -> ('b, (OBus_header.method_return * 'c) Lwt.t, 'c, _, _) OBus_comb.func -> 'b
  (** [send_message_with_reply connection header typ ...] Send a
      message and return a thread which wait for the reply *)

val ksend_message : (unit Lwt.t -> 'c) -> t -> 'a OBus_header.t -> ('b, 'c, unit, _, _) OBus_comb.func -> 'b
val ksend_message_with_reply : ((OBus_header.method_return * 'c) Lwt.t -> 'd) -> t -> OBus_header.method_call -> ('b, 'd, 'c, _, _) OBus_comb.func -> 'b
  (** Same thing but with continuation *)

val wire_send_message : t -> 'a OBus_header.t ->
  'b OBus_types.sequence_p -> (unit, 'b, OBus_wire.writer) OBus_wire.sequence_p -> unit Lwt.t
val wire_send_message_with_reply : t -> OBus_header.method_call ->
  'b OBus_types.sequence_p -> (unit, 'b, OBus_wire.writer) OBus_wire.sequence_p ->
  'c OBus_types.sequence_p -> ('d, 'c, OBus_wire.reader) OBus_wire.sequence_p ->
  (OBus_header.method_return * 'd) Lwt.t
    (** Send a message by directly providing writer/reader monads,
        this could be used for more complex cases *)

val send_error : t -> OBus_header.method_call -> OBus_error.name -> OBus_error.message -> unit Lwt.t
  (** Send an error message in reply to a method call *)

val send_exn : t -> OBus_header.method_call -> exn -> unit Lwt.t
  (** [send_exn connection method_call exn] equivalent of:

      {[
         let Some(name, message) = OBus_error.unmake exn in
           send_exn connection method_call name message
      ]}
  *)

(** {6 Sending untyped messages} *)

(** The following function are similar to the [send_*] function but
    instead of taking a type combinator they take a dynamically type
    value.

    For example the two codes are equivalent:

    [send_message connection header [: int -> string -> unit ] 1 "toto"]

    and:

    {[
       usend_message connection header
            [Basic(Int32 1l);
             Basic(String "toto")]
    ]}
*)

val usend_message : t -> 'a OBus_header.t -> OBus_value.sequence -> unit Lwt.t
val usend_message_with_reply : t -> OBus_header.method_call -> OBus_value.sequence ->
  (OBus_header.method_return * OBus_value.sequence) Lwt.t

(** {6 Filters} *)

(** Filters are functions whose are applied on all incomming
    messages.

    Filters can be used to for debugging purpose or to write low-level
    DBus application (look at [samples/monitor.ml] to see an example
    of use of filters). *)

type filter_id
type filter = OBus_header.any -> OBus_value.sequence -> unit
  (** A filter will take as argument the header of the message and the
      body as q dynamically typed value *)

val add_filter : t -> filter -> filter_id
  (** [add_filter connection filter] add a filter to the given
      connection. This filter will be called before all previously
      defined filter. *)

val remove_filter : t -> filter_id -> unit
  (** Remove the given filter. It do nothing if the filter as already
      been removed *)

(** {6 Errors handling} *)

exception Protocol_error of string
  (** This exception is raised when an invalid DBus message is
      received. *)

(** Note: protocol and transport errors are considered as fatal
    errors. When a fatal error happen the connection is immediately
    closed. *)

val on_disconnect : t -> (exn -> unit) ref
  (** Function called when a fatal error happen. The default behaviour
      is to print an error message and to exit the program. *)