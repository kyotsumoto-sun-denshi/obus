(*
 * obus-binder.ml
 * --------------
 * Copyright : (c) 2008, Jeremie Dimino <jeremie@dimino.org>
 * Licence   : BSD3
 *
 * This file is a part of obus, an ocaml implemtation of dbus.
 *)

open Common

let output_file_prefix = ref None
let xml_files = ref []

let args = [
  "-o", Arg.String (fun s -> output_file_prefix := Some s),
  "output file prefix"
]

let usage_msg = Printf.sprintf "Usage: %s <options> <xml-files>
Generate an ocaml module from DBus introspection files.
options are:" (Filename.basename (Sys.argv.(0)))

let choose_output_file_prefix () = match !output_file_prefix with
  | Some f -> f
  | None -> match !xml_files with
      | [f] -> begin
          try
            let i = String.rindex f '.' in
            if String.lowercase (Str.string_after f i) = ".xml"
            then String.sub f 0 i
            else f
          with
              Not_found -> f
        end
      | _ -> "obus.out"

let with_pp fname f = Util.with_open_out fname
  (fun oc ->
     f (Format.formatter_of_out_channel oc);
     Printf.eprintf "File %S written.\n" fname)

let _ =
  Arg.parse args
    (fun s -> xml_files := s :: !xml_files)
    usage_msg;

  if !xml_files = []
  then Arg.usage args usage_msg;

  let output_file_prefix = choose_output_file_prefix () in

  let interfaces = List.flatten
    (List.map
       (fun name -> fst (parse_source IParser.document (XmlParser.SFile name)))
       !xml_files) in

  with_pp (output_file_prefix ^ ".mli")
    (fun pp -> List.iter (print_interf pp) interfaces);

  with_pp (output_file_prefix ^ ".ml")
    (fun pp -> List.iter (print_implem pp) interfaces)