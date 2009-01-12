(*
 * hal_device.ml
 * -------------
 * Copyright : (c) 2009, Jeremie Dimino <jeremie@dimino.org>
 * Licence   : BSD3
 *
 * This file is a part of obus, an ocaml implemtation of dbus.
 *)

open Lwt
open OBus_value

let get_peer =
  lazy(perform
         bus <-- Lazy.force OBus_bus.system;
         return (OBus_peer.make bus "org.freedesktop.Hal"))

OBUS_type udi = path

external make : OBus_path.t -> udi = "%identity"
external path : udi -> OBus_path.t = "%identity"

module Make_interface =
  OBus_interface.Make_custom(struct
                               type t = udi
                               let make_proxy udi =
                                 (perform
                                    peer <-- Lazy.force get_peer;
                                    return (OBus_proxy.make peer udi))
                             end)

include Make_interface(struct let name = "org.freedesktop.Hal.Device" end)

let computer = ["org"; "freedesktop"; "Hal"; "devices"; "computer"]

type property =
  | Pstring of string
  | Pstrlist of string list
  | Pint of int32
  | Puint64 of int64
  | Pbool of bool
  | Pdouble of float

let tproperty = OBus_type.wrap_single tvariant
  (function
     | Basic(String s) -> Pstring s
     | Array(Tsingle (Tbasic Tstring), _) as l -> Pstrlist(OBus_type.cast_single (tlist tstring) l)
     | Basic(Int32 x) -> Pint x
     | Basic(Uint64 x) -> Puint64 x
     | Basic(Boolean x) -> Pbool x
     | Basic(Double x) -> Pdouble x
     | v -> failwith ("invalid device property: " ^ OBus_value.string_of_single v))
  (function
     | Pstring s -> vbasic (String s)
     | Pstrlist l -> OBus_type.make_single (tlist tstring) l
     | Pint x -> vbasic (Int32 x)
     | Puint64 x -> vbasic (Uint64 x)
     | Pbool x -> vbasic (Boolean x)
     | Pdouble x -> vbasic (Double x))

OBUS_method GetAllProperties : {string, property} list
OBUS_method SetMultipleProperties : {string, property} list -> unit
OBUS_method GetProperty : string -> property
OBUS_method GetPropertyString : string -> string
OBUS_method GetPropertyStringList : string -> string list
OBUS_method GetPropertyInteger : string -> int
OBUS_method GetPropertyBoolean : string -> bool
OBUS_method GetPropertyDouble : string -> float
OBUS_method SetProperty : string -> property -> unit
OBUS_method SetPropertyString : string -> string -> unit
OBUS_method SetPropertyStringList : string -> string list -> unit
OBUS_method SetPropertyInteger : string -> int -> unit
OBUS_method SetPropertyBoolean : string -> bool -> unit
OBUS_method SetPropertyDouble : string -> float -> unit
OBUS_method RemoveProperty : string -> unit
OBUS_method GetPropertyType : string -> int
OBUS_method PropertyExists : string -> bool
OBUS_method AddCapability : string -> unit
OBUS_method QueryCapability : string -> bool
OBUS_method Lock : string -> bool
OBUS_method Unlock : bool
OBUS_method AcquireInterfaceLock : string -> bool -> unit
OBUS_method ReleaseInterfaceLock : string -> unit
OBUS_method IsCallerLockedOut : string -> string -> bool
OBUS_method IsCallerPrivileged : string -> string list -> string -> string
OBUS_method IsLockedByOthers : string -> bool
OBUS_method StringListAppend : string -> string -> unit
OBUS_method StringListPrepend : string -> string -> unit
OBUS_method StringListRemove : string -> string -> unit
OBUS_method EmitCondition : string -> string -> bool
OBUS_method Rescan : bool
OBUS_method Reprobe : bool
OBUS_method ClaimInterface : string -> string -> bool
OBUS_method AddonIsReady : bool

OBUS_signal PropertyModified : int * [string * bool * bool] list
OBUS_signal Condition : string * string
OBUS_signal InterfaceLockAcquired : string * string * int
OBUS_signal InterfaceLockReleased : string * string * int

module Volume = struct
  include Make_interface(struct let name = "org.freedesktop.Hal.Device.Volume" end)
  OBUS_method Mount : string -> string -> string list -> int
  OBUS_method Unmount : string list -> int
  OBUS_method Eject : string list -> int
end
module Storage = struct
  include Make_interface(struct let name = "org.freedesktop.Hal.Device.Storage" end)
  OBUS_method Eject : string list -> int
  OBUS_method CloseTray : string list -> int
end
module Storage_removable = struct
  include Make_interface(struct let name = "org.freedesktop.Hal.Device.Storage.Removable" end)
  OBUS_method CheckForMedia : bool
end
module Wake_on_lan = struct
  include Make_interface(struct let name = "org.freedesktop.Hal.Device.WakeOnLan" end)
  OBUS_method GetSupported : int
  OBUS_method GetEnabled : int
  OBUS_method SetEnabled : bool -> int
end
module System_power_management = struct
  include Make_interface(struct let name = "org.freedesktop.Hal.Device.SystemPowerManagement" end)
  OBUS_method Suspend : int -> int
  OBUS_method SuspendHybrid : int -> int
  OBUS_method Hibernate : int
  OBUS_method Shutdown : int
  OBUS_method Reboot : int
  OBUS_method SetPowerSave : bool -> int
end
module Cpufreq = struct
  include Make_interface(struct let name = "org.freedesktop.Hal.Device.CPUFreq" end)
  OBUS_method SetCPUFreqGovernor : string -> unit
  OBUS_method SetCPUFreqPerformance : int -> unit
  OBUS_method SetCPUFreqConsiderNice : bool -> unit
  OBUS_method GetCPUFreqGovernor : string
  OBUS_method GetCPUFreqPerformance : int
  OBUS_method GetCPUFreqConsiderNice : bool
  OBUS_method GetCPUFreqAvailableGovernors : string list
end
module Laptop_panel = struct
  include Make_interface(struct let name = "org.freedesktop.Hal.Device.LaptopPanel" end)
  OBUS_method SetBrightness : int -> int
  OBUS_method GetBrightness : int
end
module Dock_station = struct
  include Make_interface(struct let name = "org.freedesktop.Hal.Device.DockStation" end)
  OBUS_method Undock : int
end
module Kill_switch = struct
  include Make_interface(struct let name = "org.freedesktop.Hal.Device.KillSwitch" end)
  OBUS_method SetPower : bool -> int
  OBUS_method GetPower : int
end
