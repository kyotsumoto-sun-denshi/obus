open Printf
open Ocamlbuild_plugin
open Command (* no longer needed for OCaml >= 3.10.2 *)

module Config =
struct
  let obus_version = "0.1"

  let all_modules =
    [ "Addr_lexer";
      "Auth_lexer";
      "Util";
      "OBus_info";
      "Wire";
      "Types_rw";
      "OBus_path";
      "OBus_types";
      "OBus_value";
      "OBus_xml_parser";
      "OBus_introspect";
      "OBus_address";
      "OBus_transport";
      "OBus_annot";
      "OBus_auth";
      "OBus_header";
      "OBus_intern";
      "OBus_wire";
      "Wire_message";
      "OBus_comb";
      "OBus_error";
      "OBus_connection";
      "OBus_proxy";
      "OBus_pervasives";
      "OBus_client";
      "OBus_bus" ]

  let hidden_modules =
    [ "Wire_message";
      "Addr_lexer";
      "Auth_lexer";
      "Util";
      "Wire";
      "Types_rw";
      "OBus_intern" ]

  let modules = List.filter (fun s -> not & List.mem s hidden_modules) all_modules

  let meta = Printf.sprintf "
description = \"Pure OCaml implementation of DBus\"
version = \"%s\"
browse_interfaces = \"%s\"
requires = \"lwt\"
archive(byte) = \"obus.cma\"
archive(native) = \"obus.cmxa\"
package \"syntax\" (
  version = \"[distrubuted with OBus]\"
  description = \"Syntactic sugar for OBus: DBus types written as caml types + convertion function\"
  requires = \"camlp4\"
  archive(syntax,preprocessor) = \"pa_obus.cmo\"
  archive(syntax,toploop) = \"pa_obus.cmo\"
)\n" obus_version (String.concat " " modules)

  (* Syntax extensions used internally *)
  let intern_syntaxes = ["pa_log"; "trace"; "pa_obus"]
end

(* these functions are not really officially exported *)
let run_and_read = Ocamlbuild_pack.My_unix.run_and_read
let blank_sep_strings = Ocamlbuild_pack.Lexers.blank_sep_strings

let exec cmd =
  blank_sep_strings &
    Lexing.from_string &
    run_and_read cmd

(* this lists all supported packages *)
let find_packages () = exec "ocamlfind list | cut -d' ' -f1"

(* this is supposed to list available syntaxes, but I don't know how to do it. *)
let find_syntaxes () = ["camlp4o"; "camlp4r"]

(* ocamlfind command *)
let ocamlfind x = S[A"ocamlfind"; x]

let _ =
  dispatch begin function
    | Before_options ->

        (* override default commands by ocamlfind ones *)
        Options.ocamlc   := ocamlfind & A"ocamlc";
        Options.ocamlopt := ocamlfind & A"ocamlopt";
        Options.ocamldep := ocamlfind & A"ocamldep";
        Options.ocamldoc := ocamlfind & A"ocamldoc"

    | After_rules ->
        Pathname.define_context "test" [ "obus" ];

        ocaml_lib ~dir:"obus" "obus";
        dep ["ocaml"; "byte"; "use_obus"] ["obus.cma"];
        dep ["ocaml"; "native"; "use_obus"] ["obus.cmxa"];

        rule "META" ~prod:"META"
          (fun _ _ -> Echo([Config.meta], "META"));

        rule "obus_doc" ~prod:"obus.odocl"
          (fun _ _ -> Echo(List.map (sprintf "obus/%s\n") Config.modules, "obus.odocl"));

        rule "obus_lib" ~prod:"obus.mllib"
          (fun _ _ -> Echo(List.map (sprintf "obus/%s\n") Config.all_modules, "obus.mllib"));

        rule "mli_to_install" ~prod:"lib-dist"
          (fun _ _ -> Echo(List.map (fun s -> sprintf "obus/%s.mli\n" (String.uncapitalize s)) Config.modules, "lib-dist"));

        (* When one link an OCaml library/binary/package, one should use -linkpkg *)
        flag ["ocaml"; "link"] & A"-linkpkg";

        (* For each ocamlfind package one inject the -package option when
         * compiling, computing dependencies, generating documentation and
         * linking. *)
        List.iter begin fun pkg ->
          flag ["ocaml"; "compile";  "pkg_"^pkg] & S[A"-package"; A pkg];
          flag ["ocaml"; "ocamldep"; "pkg_"^pkg] & S[A"-package"; A pkg];
          flag ["ocaml"; "doc";      "pkg_"^pkg] & S[A"-package"; A pkg];
          flag ["ocaml"; "link";     "pkg_"^pkg] & S[A"-package"; A pkg];
        end (find_packages ());

        (* Like -package but for extensions syntax. Morover -syntax is useless
         * when linking. *)
        List.iter begin fun syntax ->
          flag ["ocaml"; "compile";  "syntax_"^syntax] & S[A"-syntax"; A syntax];
          flag ["ocaml"; "ocamldep"; "syntax_"^syntax] & S[A"-syntax"; A syntax];
          flag ["ocaml"; "doc";      "syntax_"^syntax] & S[A"-syntax"; A syntax];
        end (find_syntaxes ());

        List.iter begin fun tag ->
          flag ["ocaml"; "compile"; tag] & S[A"-ppopt"; A("syntax/" ^ tag ^ ".cmo")];
          flag ["ocaml"; "ocamldep"; tag] & S[A"-ppopt"; A("syntax/" ^ tag ^ ".cmo")];
          flag ["ocaml"; "doc"; tag] & S[A"-ppopt"; A("syntax/" ^ tag ^ ".cmo")];
          dep ["ocaml"; "ocamldep"; tag] ["syntax/" ^ tag ^ ".cmo"]
        end Config.intern_syntaxes;

    | _ -> ()
  end
