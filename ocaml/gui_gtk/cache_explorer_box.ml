(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** GTK cache explorer dialog (for "0install store manage") *)

open Zeroinstall.General
open Support.Common

module Python = Zeroinstall.Python
module F = Zeroinstall.Feed
module U = Support.Utils
module FC = Zeroinstall.Feed_cache
module FeedAttr = Zeroinstall.Constants.FeedAttr
module Feed_url = Zeroinstall.Feed_url
module Manifest = Zeroinstall.Manifest

let rec size_of_item system path =
  match system#lstat path with
  | None -> 0L
  | Some info ->
      match info.Unix.st_kind with
      | Unix.S_REG | Unix.S_LNK -> Int64.of_int info.Unix.st_size
      | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> log_warning "Bad file kind for %s" path; 0L
      | Unix.S_DIR ->
          match system#readdir path with
          | Success items -> items |> Array.fold_left (fun acc item -> Int64.add acc (size_of_item system (path +/ item))) 0L
          | Problem ex -> log_warning ~ex "Can't scan %s" path; 0L

(** Get the size for an implementation. Get the size from the .manifest if possible. *)
let size_of_impl (system:system) path : Int64.t =
  let man = path +/ ".manifest" in
  match system#lstat man with
  | None -> size_of_item system path
  | Some info ->
      let size = ref @@ Int64.of_int info.Unix.st_size in    (* (include the size of the .manifest file itself) *)
      man |> system#with_open_in [Open_rdonly; Open_binary] (fun stream ->
        try
          while true do
            let line = input_line stream in
            match line.[0] with
            | 'X' | 'F' ->
                begin match Str.bounded_split_delim U.re_space line 5 with
                | [_type; _hash; _mtime; item_size; _name] -> size := Int64.add !size (Int64.of_string item_size)
                | _ -> () end
            | _ -> ()
          done
        with End_of_file -> ()
      );
      !size

(* We have two models: the underlying model (CacheModel) and a sorted view of it, which is
 * what the TreeView displays. It's very important not to confuse the iterators of one model
 * with those of the other, or you may act on the wrong data.
 *
 * For example, to delete a row you need to call the delete operation on the underlying model,
 * using an underlying iterator. But the TreeView's get_selected_rows returns iterators in the
 * sorted model.
 *
 * This module isolates the underlying model and its iterators from the rest of the code, so
 * mixups aren't possible.
 *)
module CacheModel :
  sig
    type t
    type iter
    val list_store : GTree.column_list -> t
    val model_sort : t -> GTree.model_sort
    val get_iter_first : t -> iter option
    val set : t -> row:iter -> column:'a GTree.column -> 'a -> unit
    val get : t -> row:iter -> column:'a GTree.column -> 'a
    val remove : t -> iter -> bool
    val convert_iter_to_child_iter : GTree.model_sort -> Gtk.tree_iter -> iter
    val append : t -> iter
    val iter_next : t -> iter -> bool
  end = struct
    type t = GTree.list_store
    type iter = Gtk.tree_iter

    let list_store cols = GTree.list_store cols
    let model_sort model = GTree.model_sort model
    let get_iter_first (model:t) = model#get_iter_first
    let set (model:t) ~(row:iter) ~column value = model#set ~row ~column value
    let get (model:t) ~(row:iter) ~column = model#get ~row ~column
    let remove (model:t) (row:iter) = model#remove row
    let convert_iter_to_child_iter (model:GTree.model_sort) (iter:Gtk.tree_iter) = model#convert_iter_to_child_iter iter
    let append (model:t) = model#append ()
    let iter_next (model:t) (row:iter) = model#iter_next row
  end

let cache_help = Help_box.create "Cache Explorer Help" [
("Overview",
"When you run a program using 0install, it downloads a suitable implementation (version) of the program and of \
each library it uses. Each of these is stored in the cache, each in its own directory.
\n\
0install lets you have many different versions of each program on your computer at once. This is useful, \
since it lets you use an old version if needed, and different programs may need to use \
different versions of a single library in some cases.
\n\
The cache viewer shows you all the implementations in your cache. \
This is useful to find versions you don't need anymore, so that you can delete them and \
free up some disk space.");

("Operations",
"When you select one or more implementations, the details are shown in the box at the bottom, with some buttons \
along the side:\n
Delete will delete the directory.\n\
Verify will check that the contents of the directory haven't been modified.\n\
Open will open the directory in your file manager.");

("Unowned implementations",
"The cache viewer searches through all your feeds (XML files) to find out which implementations \
they use. The 'Name' and 'Version' columns show what the implementation is used for. \
If no feed can be found for an implementation, it is shown as '(unowned)'.
\n\
Unowned implementations can result from old versions of a program no longer being listed \
in the feed file or from sharing the cache with other users.");

("Temporary files",
"Temporary directories (listed as '(temporary)') are created when unpacking an implementation after \
downloading it. If the archive is corrupted, the unpacked files may be left there. Unless \
you are currently unpacking new programs, it should be fine to delete all of these (hint: click on the 'Name' \
column title to sort by name, then select all of them using Shift-click.");
]

let show_verification_box config ~parent paths =
  let box = GWindow.message_dialog
    ~parent
    ~buttons:GWindow.Buttons.close
    ~message_type:`INFO
    ~resizable:true
    ~title:"Verify"
    ~message:"Verifying..."
    () in
  box#show ();

  let swin = GBin.scrolled_window
    ~packing:(box#vbox#pack ~expand:true)
    ~hpolicy:`AUTOMATIC
    ~vpolicy:`AUTOMATIC
    ~show:false
    () in

  let report_text = GText.view ~packing:swin#add () in
  report_text#misc#modify_font (GPango.font_description "mono");
  let n_good = ref 0 in
  let n_bad = ref 0 in

  let report_problem msg =
    swin#misc#show ();
    report_text#buffer#insert msg in

  let cancelled = ref false in
  box#connect#response ~callback:(fun _ ->
    cancelled := true;
    box#destroy ()
  ) |> ignore;

  let n_items = List.length paths in
  let n = ref 0 in

  Gdk.Window.set_cursor box#misc#window (Lazy.force Gtk_utils.busy_cursor);
  Gtk_utils.async ~parent:box (fun () ->
    try_lwt
      let rec loop = function
        | _ when !cancelled -> raise Lwt.Canceled
        | [] -> Lwt.return ()
        | x::xs ->
            begin try_lwt
              incr n;
              box#set_markup (Printf.sprintf "Checking item %d of %d" !n n_items);
              let digest = Manifest.parse_digest (Filename.basename x) in
              lwt () = Lwt_preemptive.detach (Manifest.verify config.system ~digest) x in
              incr n_good;
              Lwt.return ()
            with Safe_exception (msg, _) ->
              let space = if !n_bad = 0 then "" else "\n\n" in
              incr n_bad;
              report_problem @@ Printf.sprintf "%s%s:\n%s\n" space x msg;
              Lwt.return ()
            end >>
            loop xs in
      lwt () = loop paths in
      if !n_bad = 1 && !n_good = 0 then
        box#set_markup "<b>Verification failed!</b>"
      else if !n_bad > 0 then
        box#set_markup (Printf.sprintf "<b>Verification failed</b>\nFound bad items (%d / %d)" !n_bad (!n_bad + !n_good))
      else if !n_good = 1 then
        box#set_markup "Verification successful!"
      else
        box#set_markup (Printf.sprintf "Verification successful (%d items)" !n_good);
      Lwt.return ()
    with Lwt.Canceled ->
      Lwt.return ()
    finally
      if not (!cancelled) then
        Gdk.Window.set_cursor box#misc#window (Lazy.force Gtk_utils.default_cursor);
      Lwt.return ()
  )

let confirm_deletion ~parent n_items =
  let message =
    if n_items = 1 then "Delete this item?"
    else Printf.sprintf "Delete these %d selected items?" n_items in
  let box = GWindow.dialog
    ~parent
    ~title:"Confirm"
    () in
  GMisc.label ~packing:box#vbox#pack ~xpad:20 ~ypad:20 ~text:message () |> ignore;
  box#add_button_stock `CANCEL `CANCEL;
  box#add_button_stock `DELETE `DELETE;
  let result, set_result = Lwt.wait () in
  box#set_default_response `DELETE;
  box#connect#response ~callback:(fun response ->
    box#destroy ();
    Lwt.wakeup set_result (
      match response with
      | `DELETE -> `delete
      | `CANCEL | `DELETE_EVENT -> `cancel
    )
  ) |> ignore;
  box#show ();
  result

let open_cache_explorer config =
  let finished, set_finished = Lwt.wait () in

  let dialog = GWindow.dialog ~title:"0install Cache Explorer" () in
  dialog#misc#set_sensitive false;

  let swin = GBin.scrolled_window
    ~packing:(dialog#vbox#pack ~expand:true)
    ~hpolicy:`AUTOMATIC
    ~vpolicy:`AUTOMATIC
    () in

  (* Model *)
  let cols = new GTree.column_list in
  let owner_col = cols#add Gobject.Data.string in
  let impl_dir_col = cols#add Gobject.Data.string in
  let version_str_col = cols#add Gobject.Data.string in
  let size_col = cols#add Gobject.Data.int64 in
  let size_str_col = cols#add Gobject.Data.string in

  let model = CacheModel.list_store cols in
  let sorted_model = CacheModel.model_sort model in

  (* View *)
  let view = GTree.view
    ~model:sorted_model
    ~packing:swin#add
    ~enable_search:true
    ~search_column:owner_col.GTree.index
    ~headers_clickable:true
    () in
  let renderer = GTree.cell_renderer_text [] in
  let owner_vc = GTree.view_column ~title:"Name" ~renderer:(renderer, ["text", owner_col]) () in
  let version_vc = GTree.view_column ~title:"Version" ~renderer:(renderer, ["text", version_str_col]) () in
  let size_vc = GTree.view_column ~title:"Size" ~renderer:(renderer, ["text", size_str_col]) () in

  owner_vc#set_sort_column_id owner_col.GTree.index;
  size_vc#set_sort_column_id size_col.GTree.index;

  view#append_column owner_vc |> ignore;
  view#append_column version_vc |> ignore;
  view#append_column size_vc |> ignore;

  let selection = view#selection in

  (* Details area *)
  let details_frame = GBin.frame
    ~packing:dialog#vbox#pack
    ~border_width:5
    ~shadow_type:`OUT () in

  let table = GPack.table
    ~packing:details_frame#add
    ~columns:3 ~rows:2
    ~col_spacings:4
    ~border_width:4
    ~homogeneous:false
    () in

  GMisc.label ~packing:(table#attach ~top:0 ~left:0) ~text:"Feed:" ~xalign:1.0 () |> ignore;
  GMisc.label ~packing:(table#attach ~top:1 ~left:0) ~text:"Path:" ~xalign:1.0 () |> ignore;
  GMisc.label ~packing:(table#attach ~top:2 ~left:0) ~text:"Details:" ~xalign:1.0 () |> ignore;

  let details_iface = GMisc.label ~packing:(table#attach ~top:0 ~left:1 ~expand:`X) ~xalign:0.0 ~selectable:true () in
  let details_path = GMisc.label ~packing:(table#attach ~top:1 ~left:1 ~expand:`X) ~xalign:0.0 ~selectable:true () in
  let details_extra = GMisc.label ~packing:(table#attach ~top:2 ~left:1 ~expand:`X) ~xalign:0.0 ~selectable:true () in
  details_iface#set_ellipsize `MIDDLE;
  details_path#set_ellipsize `MIDDLE;
  details_extra#set_ellipsize `END;

  let delete = GButton.button ~packing:(table#attach ~top:0 ~left:2) ~stock:`DELETE () in
  delete#connect#clicked ~callback:(fun () ->
    let iters = selection#get_selected_rows |> List.map (fun sorted_path ->
      sorted_model#get_iter sorted_path |> CacheModel.convert_iter_to_child_iter sorted_model
    ) in
    dialog#misc#set_sensitive false;
    Gdk.Window.set_cursor dialog#misc#window (Lazy.force Gtk_utils.busy_cursor);
    Gtk_utils.async ~parent:dialog (fun () ->
      try_lwt
        let rec loop = function
          | [] -> Lwt.return ()
          | x::xs ->
              let dir = CacheModel.get model ~row:x ~column:impl_dir_col in
              lwt () = Lwt_preemptive.detach (U.rmtree ~even_if_locked:true config.system) dir in
              let removed = CacheModel.remove model x in
              assert removed;
              loop xs in
        match_lwt confirm_deletion ~parent:dialog (List.length iters) with
        | `delete -> loop iters
        | `cancel -> Lwt.return ()
      finally
        Gdk.Window.set_cursor dialog#misc#window (Lazy.force Gtk_utils.default_cursor);
        dialog#misc#set_sensitive true;
        Lwt.return ()
    )
  ) |> ignore;

  let verify = Gtk_utils.mixed_button ~packing:(table#attach ~top:1 ~left:2) ~stock:`FIND ~label:"Verify" () in
  verify#connect#clicked ~callback:(fun () ->
    let dirs = selection#get_selected_rows |> List.map (fun path ->
      let row = sorted_model#get_iter path in
      sorted_model#get ~row ~column:impl_dir_col
    ) in
    show_verification_box config ~parent:dialog dirs
  ) |> ignore;

  let open_button = GButton.button ~packing:(table#attach ~top:2 ~left:2) ~stock:`OPEN () in
  open_button#connect#clicked ~callback:(fun () ->
    match selection#get_selected_rows with
    | [path] ->
        let row = sorted_model#get_iter path in
        let dir = sorted_model#get ~row ~column:impl_dir_col in
        U.xdg_open_dir ~exec:false config.system dir
    | _ -> log_warning "Invalid selection!"
  ) |> ignore;

  details_frame#misc#set_sensitive false;

  (* Buttons *)
  dialog#add_button_stock `HELP `HELP;
  (* Lablgtk uses the wrong response code for HELP, so we have to do this manually. *)
  let actions = dialog#action_area in
  actions#set_child_secondary (List.hd actions#children) true;

  dialog#add_button_stock `CLOSE `CLOSE;

  dialog#connect#response ~callback:(function
    | `DELETE_EVENT | `CLOSE -> dialog#destroy (); Lwt.wakeup set_finished ()
    | `HELP -> cache_help#display
  ) |> ignore;
  dialog#show ();

  (* Make sure the GUI appears before we start the (slow) scan *)
  Gdk.X.flush ();

  (* Populate model *)
  let all_digests = Zeroinstall.Stores.get_available_digests config.system config.stores in
  let ok_feeds = ref [] in

  (* Look through cached feeds for implementation owners *)
  let all_feed_urls = FC.list_all_feeds config in
  all_feed_urls |> StringSet.iter (fun url ->
    try
      match FC.get_cached_feed config (`remote_feed url) with
      | Some feed -> ok_feeds := feed :: !ok_feeds
      | None -> log_warning "Feed listed but now missing! %s" url
    with ex ->
      log_info ~ex "Error loading feed %s" url;
  );

  (* Map each digest to its implementation *)
  let impl_of_digest = Hashtbl.create 1024 in
  !ok_feeds |> List.iter (fun feed ->
    (* For each implementation... *)
    feed.F.implementations |> StringMap.iter (fun _id impl ->
      match impl.F.impl_type with
      | F.CacheImpl info ->
          (* For each digest... *)
          info.F.digests |> List.iter (fun parsed_digest ->
            let digest = Manifest.format_digest parsed_digest in
            if Hashtbl.mem all_digests digest then (
              Hashtbl.add impl_of_digest digest (feed, impl)
            )
          )
      | F.PackageImpl _ | F.LocalImpl _ -> assert false
    );
  );

  (* Add each cached implementation to the model *)
  all_digests |> Hashtbl.iter (fun digest dir ->
    let row = CacheModel.append model in
    CacheModel.set model ~row ~column:impl_dir_col @@ dir +/ digest;
    try
      let feed, impl = Hashtbl.find impl_of_digest digest in
      CacheModel.set model ~row ~column:owner_col feed.F.name;
      CacheModel.set model ~row ~column:version_str_col @@ F.get_attr_ex FeedAttr.version impl;
    with Not_found ->
      try
        Manifest.parse_digest digest |> ignore;
        CacheModel.set model ~row ~column:owner_col "(unowned)";
      with _ ->
        CacheModel.set model ~row ~column:owner_col "(temporary)";
  );

  (* Now go back and fill in the sizes *)
  lwt () =
    match CacheModel.get_iter_first model with
    | Some row ->
        let rec loop () =
          let dir = CacheModel.get model ~row ~column:impl_dir_col in
          lwt size = Lwt_preemptive.detach (size_of_impl config.system) dir in
          CacheModel.set model ~row ~column:size_col size;
          CacheModel.set model ~row ~column:size_str_col (U.format_size size);
          if CacheModel.iter_next model row then loop ()
          else Lwt.return () in
        loop ()
    | None -> Lwt.return () in

  (* Sort by size initially *)
  sorted_model#set_sort_column_id size_col.GTree.index `DESCENDING;

  (* Update the details panel when the selection changes *)
  selection#set_mode `MULTIPLE;
  selection#connect#changed ~callback:(fun () ->
    let interface, path, extra, sensitive, single =
      match selection#get_selected_rows with
      | [] -> ("", "", [], false, false)
      | [path] ->
          let row = sorted_model#get_iter path in
          let dir = sorted_model#get ~row ~column:impl_dir_col in
          let digest = Filename.basename dir in
          begin try
            let feed, impl = Hashtbl.find impl_of_digest digest in
            let extra = [
              "arch:" ^ Zeroinstall.Arch.format_arch impl.F.os impl.F.machine;
              "langs:" ^ (F.get_langs impl |> List.map Support.Locale.format_lang |> String.concat ",");
            ] in
            (Feed_url.format_url feed.F.url, dir, extra, true, true)
          with Not_found ->
            let extra =
              match config.system#readdir dir with
              | Problem ex -> ["error:" ^ Printexc.to_string ex]
              | Success items -> ["files:" ^ (Array.to_list items |> String.concat ",")] in
            ("-", dir, extra, true, true) end
      | paths ->
          (Printf.sprintf "(%d selected items)" (List.length paths), "", [], true, false) in
    details_iface#set_text interface;
    details_path#set_text path;
    details_extra#set_text (String.concat ", " extra);
    details_frame#misc#set_sensitive sensitive;
    open_button#misc#set_sensitive single;
  ) |> ignore;


  dialog#misc#set_sensitive true;

  finished
