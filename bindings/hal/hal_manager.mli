(*
 * hal_manager.mli
 * ---------------
 * Copyright : (c) 2009, Jeremie Dimino <jeremie@dimino.org>
 * Licence   : BSD3
 *
 * This file is a part of obus, an ocaml implementation of D-Bus.
 *)

(** The Hal manager *)

type t = OBus_proxy.t
    (** Type of the Hal manager *)

val obus_t : t OBus_type.basic

val manager : unit -> t Lwt.t
  (** The Hal manager *)

val get_all_devices : t -> Hal_device.t list Lwt.t
val get_all_devices_with_properties : t -> (Hal_device.t * (string * Hal_device.property) list) list Lwt.t
val device_exists : t -> Hal_device.t -> bool Lwt.t
val find_device_string_match : t -> string -> string -> Hal_device.t list Lwt.t
val find_device_by_capability : t -> string -> Hal_device.t list Lwt.t
val new_device : t -> string Lwt.t
val remove : t -> string -> unit Lwt.t
val commit_to_gdl : t -> string -> string -> unit Lwt.t
val acquire_global_interface_lock : t -> string -> bool -> unit Lwt.t
val release_global_interface_lock : t -> string -> unit Lwt.t
val singleton_addon_is_ready : t -> string -> unit Lwt.t

val device_added : t -> Hal_device.t OBus_proxy.signal
val device_removed : t -> Hal_device.t OBus_proxy.signal
val new_capability : t -> (Hal_device.t * string) OBus_proxy.signal
val global_interface_lock_acquired : t -> (string * string * int) OBus_proxy.signal
val global_interface_lock_released : t -> (string * string * int) OBus_proxy.signal
