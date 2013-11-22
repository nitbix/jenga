
(* jem - jenga monitor *)

open Core.Std
open No_polymorphic_compare let _ = _squelch_unused_module_warning_
open Async.Std

let retry_span = sec 0.5

let terminal_type =
  match Core.Std.Sys.getenv "TERM" with
  | None -> ""
  | Some x -> x

let dont_emit_kill_line = String.(terminal_type = "dumb")

let message =
  if dont_emit_kill_line
  then fun fmt -> ksprintf (fun s -> Printf.printf "%s\r%!" s) fmt
  else fun fmt -> ksprintf (fun s -> Printf.printf "\027[2K%s\r%!" s) fmt

let run ~root_dir ~string_of_mon =

  let last_mon = ref None in
  let estimator =
    (* The bigger the decay-factor, the more stable the estimate *)
    Finish_time_estimator.create ~decay_factor_per_second:0.95
  in

  let string_of_mon mon =
    string_of_mon mon
    ^ Finish_time_estimator.estimated_finish_time_string estimator
  in

  let string_of_last_mon () =
    match !last_mon with
    | None -> "no progress seen!"
    | Some mon -> string_of_mon mon
  in

  let suck_mon_pipe conn =
    let stop = ref false in
    let fresh = ref false in
    don't_wait_for (
      let rec loop q =
        Clock.after (sec 0.5) >>= fun () ->
        if !stop then return ()
        else
          if !fresh then (fresh := false; loop 1)
          else (
            let qmes = String.concat (List.init q ~f:(fun _ -> "?")) in
            message "%s %s" (string_of_last_mon ()) qmes;
            loop (q+1);
          )
      in loop 1
    );
    Rpc.Pipe_rpc.dispatch_exn Rpc_intf.progress_stream conn () >>= fun (reader,_id) ->
    Pipe.iter_without_pushback reader ~f:(fun mon ->
      last_mon := Some mon;
      fresh := true;
      let todo = Progress.Snapped.todo (Mon.progress mon) in
      Finish_time_estimator.push_todo estimator todo;
      message "%s" (string_of_mon mon);
    ) >>= fun () ->
    stop := true;
    return ()
  in

  let poll_for_connection ~retry =
    Server_lock.server_location ~root_dir >>= function
    | `server_not_running ->
      message "%s (not running)" (string_of_last_mon ()); (*root_dir*)
      retry()
    | `info info ->
      let host = Server_lock.Info.host info in
      let port = Server_lock.Info.port info in
      let host = if String.(host = Unix.gethostname()) then "localhost" else host in
      match port with
      | 0 ->
        message "%s (jenga running in -no-server mode)" (string_of_last_mon ());
        retry();

      | _ ->
      let server_name = sprintf "%s:%d" host port in
      let where_to_connect = Tcp.to_host_and_port host port in
      try_with (fun () ->
        Tcp.with_connection where_to_connect (fun _ reader writer ->
          Rpc.Connection.create reader writer ~connection_state:() >>= function
          | Error exn ->
            (* when does this ever come?.. *)
            message "with_rpc_connection: %s\n%s" server_name (Exn.to_string exn);
            return false
          | Ok conn ->
            suck_mon_pipe conn >>= fun () ->
            (*message "lost connection with: %s" server_name;*)
            return true
        )
      )
      >>= function
      | Ok ok -> if ok then retry() else return 1
      | Error exn ->
        message "failed to connect with: %s\n%s" server_name (Exn.to_string exn);
        return 2
  in
  let rec retry () =
    Clock.after retry_span >>= fun () ->
    poll_for_connection ~retry
  in
  poll_for_connection ~retry


module Spec = Command.Spec
let (+>) = Spec.(+>)
let (++) = Spec.(++)

let todo_breakdown =
  Spec.step (fun m x -> m ~todo_breakdown:x)
  +> Spec.flag "todo" Spec.no_arg
    ~doc:" display breakdown for 'todo' counts"

let good_breakdown =
  Spec.step (fun m x -> m ~good_breakdown:x)
  +> Spec.flag "good" Spec.no_arg
    ~doc:" display breakdown for 'good' counts"

let show_work =
  Spec.step (fun m x -> m ~show_work:x)
  +> Spec.flag "work" Spec.no_arg
    ~doc:" display counts for 'work' done: stat/digest/ls/external-jobs/db-saves"

let error fmt = ksprintf (fun s -> Printf.eprintf "%s\n%!" s) fmt

let main () =
  Command.run (
    Command.basic (todo_breakdown ++ good_breakdown ++ show_work)
      ~summary:"Jenga monitor - monitor jenga running in the current repo."
      ~readme:Progress.readme
      (fun ~todo_breakdown ~good_breakdown ~show_work  () ->

        match Path.Root.discover() with | `cant_find_root ->
          error "Cant find '%s' in start-dir or any ancestor dir"
            Misc.jenga_root_basename
        | `ok ->
          let root_dir = Path.to_absolute_string Path.the_root in
          Misc.in_async ~f:(fun () ->

            let string_of_mon mon =
              let progress = Mon.progress mon in
              let effort = Mon.effort mon in
              let eff_string ~switch =
                if not switch then "" else
                  sprintf " [ %s ]" (Effort.Snapped.to_string effort)
              in

              Progress.Snapped.to_string ~todo_breakdown ~good_breakdown progress
              ^ eff_string ~switch:show_work
            in
            run ~root_dir ~string_of_mon
          )
      )
  )