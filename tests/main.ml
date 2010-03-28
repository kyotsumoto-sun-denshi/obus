(*
 * main.ml
 * -------
 * Copyright : (c) 2010, Jeremie Dimino <jeremie@dimino.org>
 * Licence   : BSD3
 *
 * This file is a part of obus, an ocaml implementation of D-Bus.
 *)

open Lwt

let tty = Unix.isatty Unix.stdout

let title msg =
  if tty then
    Lwt_io.printf "\027[34;1m%s\r=[ \027[37;1m%s\027[34;1m ]=\n\027[0m" (String.make 80 '=') msg
  else
    Lwt_io.printlf "=[ %s ]=" msg

let rec run_tests failures total = function
  | [] ->
      if tty then
        if failures = 0 then
          Lwt_io.printl "\027[32;1mAll tests succeeded!\027[0m"
        else
          Lwt_io.printlf "\027[31;1m%d of %d tests failed.\027[0m" failures total
      else
        if failures = 0 then
          Lwt_io.printl "All tests succeeded!"
        else
          Lwt_io.printlf "%d of %d tests failed." failures total
  | (name, test) :: rest ->
      lwt () = title name in
      begin
        try_lwt
          test ()
        with exn ->
          lwt () = Lwt_io.printlf "test failed with: %s" (Printexc.to_string exn) in
          return false
      end >>= function
        | true ->
            lwt () = Lwt_io.print "\n" in
            run_tests failures (total + 1) rest
        | false ->
            lwt () = Lwt_io.print "\n" in
            run_tests (failures + 1) (total + 1) rest

lwt () =
  run_tests 0 0 [
    "serialization", Test_serialization.test;
  ]

