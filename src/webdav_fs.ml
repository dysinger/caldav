[@@@landmark "auto"]

type file = [ `File of string list ]

type dir = [ `Dir of string list ]

type file_or_dir = [ file | dir ]

module type S =

sig

  val (>>==) : ('a, 'b) result Lwt.t -> ('a -> ('c, 'b) result Lwt.t) -> ('c, 'b) result Lwt.t

  type t

  type error

  type write_error

  val basename : file_or_dir -> string

  val create_file : dir -> string -> file

  val dir_from_string : string -> dir

  val file_from_string : string -> file

  val from_string : t -> string -> (file_or_dir, error) result Lwt.t

  val to_string : file_or_dir -> string

  val parent : file_or_dir -> dir

  val get_property_map : t -> file_or_dir -> Properties.t Lwt.t

  val write_property_map : t -> file_or_dir -> Properties.t ->
    (unit, write_error) result Lwt.t

  val size : t -> file -> (int64, error) result Lwt.t

  val read : t -> file -> (Cstruct.t * Properties.t, error) result Lwt.t

  val stat : t -> file_or_dir -> (Mirage_fs.stat, error) result Lwt.t

  val exists : t -> string -> bool Lwt.t

  val dir_exists : t -> dir -> bool Lwt.t

  val listdir : t -> dir -> (file_or_dir list, error) result Lwt.t

  val mkdir : t -> dir -> Properties.t -> (unit, write_error) result Lwt.t

  val write : t -> file -> Cstruct.t -> Properties.t -> (unit, write_error) result Lwt.t

  val destroy : ?recursive:bool -> t -> file_or_dir -> (unit, write_error) result Lwt.t

  val pp_error : error Fmt.t

  val pp_write_error : write_error Fmt.t

  val valid : t -> Webdav_config.config -> (unit, [> `Msg of string ]) result Lwt.t
end

let src = Logs.Src.create "webdav.fs" ~doc:"webdav fs logs"
module Log = (val Logs.src_log src : Logs.LOG)

module Make (Fs:Mirage_fs_lwt.S) = struct

  open Lwt.Infix

  module Xml = Webdav_xml

  type t = Fs.t
  type error = Fs.error
  type write_error = Fs.write_error

  let (>>==) a f = a >>= function
    | Error e -> Lwt.return (Error e)
    | Ok res  -> f res

  let (>>|=) a f = a >|= function
    | Error e -> Error e
    | Ok res  -> f res

  let isdir fs name =
    Fs.stat fs name >>|= fun stat ->
    Ok stat.Mirage_fs.directory

  let basename = function
    | `File path | `Dir path ->
      match List.rev path with
      | base::_ -> base
      | [] -> invalid_arg "basename of root directory not allowed"

  let create_file (`Dir data) name =
    `File (data @ [name])

  (* TODO: no handling of .. done here yet *)
  let data str = Astring.String.cuts ~empty:false ~sep:"/" str

  let dir_from_string str = `Dir (data str)

  let file_from_string str = `File (data str)

  let from_string fs str =
    isdir fs str >>|= fun dir ->
    Ok (if dir then `Dir (data str) else `File (data str))

  let to_string =
    let a = Astring.String.concat ~sep:"/" in
    function
    | `File data -> "/" ^ a data
    | `Dir data -> "/" ^ a data ^ "/"

  let parent f_or_d =
    let parent p =
      match List.rev p with
      | _ :: tl -> `Dir (List.rev tl)
      | [] -> `Dir []
    in
    match f_or_d with
    | `Dir d -> parent d
    | `File f -> parent f

  let propfilename =
    let ext = ".prop.xml" in
    function
    | `Dir data -> `File (data @ [ ext ])
    | `File data -> match List.rev data with
      | filename :: path -> `File (List.rev path @ [ filename ^ ext ])
      | [] -> assert false (* no file without a name *)

  let get_properties fs f_or_d =
    let propfile = to_string (propfilename f_or_d) in
    Fs.size fs propfile >>== fun size ->
    Fs.read fs propfile 0 (Int64.to_int size)

  (* TODO: check call sites, used to do:
      else match Xml.get_prop "resourcetype" map with
        | Some (_, c) when List.exists (function `Node (_, "collection", _) -> true | _ -> false) c -> name ^ "/"
        | _ -> name in
  *)
  let write_property_map fs f_or_d map =
    match Properties.unsafe_find (Xml.dav_ns, "getlastmodified") map with
    | None ->
      Log.err (fun m -> m "map %s without getlastmodified" (to_string f_or_d)) ;
      assert false
    | Some (_, [Xml.Pcdata str]) ->
      Log.debug (fun m -> m "found %s" str) ;
      begin match Ptime.of_rfc3339 str with
        | Error (`RFC3339 (_, e)) ->
          Printf.printf "expected RFC3339, got %s\n%!" str ;
          Log.err (fun m -> m "expected RFC3339 timestamp in map of %s, got %s (%a)"
                      (to_string f_or_d) str Ptime.pp_rfc3339_error e) ;
          assert false
        | Ok _ ->
          (*    let data = Properties.to_string map in *)
          let data = Sexplib.Sexp.to_string (Properties.to_sexp map) in
          let filename = to_string (propfilename f_or_d) in
          (* Log.debug (fun m -> m "writing property map %s: %s" filename data) ; *)
          Fs.destroy fs filename >>= fun _ ->
          Fs.write fs filename 0 (Cstruct.of_string data)
      end
    | Some _ ->
      Log.err (fun m -> m "map %s with non-singleton pcdata for getlastmodified" (to_string f_or_d)) ;
      assert false

  let size fs (`File file) =
    let name = to_string (`File file) in
    Fs.size fs name

  let stat fs f_or_d = Fs.stat fs (to_string f_or_d)

  let exists fs str =
    Fs.stat fs str >|= function
    | Ok _ -> true
    | Error _ -> false

  let dir_exists fs (`Dir dir) =
    Fs.stat fs (to_string (`Dir dir)) >|= function
    | Ok s when s.Mirage_fs.directory -> true
    | _ -> false

  let listdir fs (`Dir dir) =
    let dir_string = to_string (`Dir dir) in
    Fs.listdir fs dir_string >>== fun files ->
    Lwt_list.fold_left_s (fun acc fn ->
        if Astring.String.is_suffix ~affix:".prop.xml" fn then
          Lwt.return acc
        else
          let str = dir_string ^ fn in
          isdir fs str >|= function
          | Error _ -> acc
          | Ok is_dir ->
            let f_or_d =
              if is_dir
              then dir_from_string str
              else file_from_string str
            in
            f_or_d :: acc)
      [] files >|= fun files ->
    Ok files

  let get_raw_property_map fs f_or_d =
    get_properties fs f_or_d >|= function
    | Error e ->
      Log.err (fun m -> m "error while getting properties for %s %a" (to_string f_or_d) Fs.pp_error e) ;
      None
    | Ok data ->
      let str = Cstruct.(to_string @@ concat data) in
      Some (Properties.of_sexp (Sexplib.Sexp.of_string str))

      (* match Xml.string_to_tree str with
         | None ->
           Log.err (fun m -> m "couldn't convert %s to xml tree" str) ;
           None
         | Some t -> Some (Properties.from_tree t) *)

  (* let open_fs_error x =
       (x : ('a, Fs.error) result Lwt.t :> ('a, [> Fs.error ]) result Lwt.t) *)

  (* careful: unsafe_find, unsafe_add *)
  let get_property_map fs f_or_d =
    get_raw_property_map fs f_or_d >|= function
    | None -> Properties.empty
    | Some map -> match f_or_d with
      | `File _ -> map
      | `Dir d ->
        match Properties.unsafe_find (Xml.dav_ns, "getlastmodified") map with
        | Some _ -> map
        | None ->
          let initial_date =
            match Properties.unsafe_find (Xml.dav_ns, "creationdate") map with
            | None -> ([], [ Xml.Pcdata (Ptime.to_rfc3339 Ptime.epoch) ])
            | Some x -> x
          in
          Properties.unsafe_add (Xml.dav_ns, "getlastmodified") initial_date map

  let read fs (`File file) =
    let name = to_string (`File file) in
    Fs.size fs name >>== fun length ->
    Fs.read fs name 0 (Int64.to_int length) >>== fun data ->
    get_property_map fs (`File file) >|= fun props ->
    Ok (Cstruct.concat data, props)

  let mkdir fs (`Dir dir) propmap =
    Fs.mkdir fs (to_string (`Dir dir)) >>== fun () ->
    write_property_map fs (`Dir dir) propmap

  let write fs (`File file) data propmap =
    let filename = to_string (`File file) in
    Fs.destroy fs filename >>= fun _ ->
    Fs.write fs filename 0 data >>== fun () ->
    write_property_map fs (`File file) propmap

  let destroy_file_or_empty_dir fs f_or_d =
    let propfile = propfilename f_or_d in
    Fs.destroy fs (to_string propfile) >>== fun () ->
    Fs.destroy fs (to_string f_or_d)

  (* TODO maybe push the recursive remove to FS *)
  let rec destroy ?(recursive = false) fs f_or_d =
    (if recursive then
       match f_or_d with
       | `File _ -> Lwt.return @@ Ok ()
       | `Dir d ->
         listdir fs (`Dir d) >>= function
         | Error `Is_a_directory -> Lwt.return @@ Error `Is_a_directory
         | Error `No_directory_entry -> Lwt.return @@ Error `No_directory_entry
         | Error `Not_a_directory -> Lwt.return @@ Error `Not_a_directory
         | Error _ -> assert false
         | Ok f_or_ds ->
           Lwt_list.fold_left_s (fun result f_or_d ->
               match result with
               | Error e -> Lwt.return @@ Error e
               | Ok () -> destroy ~recursive fs f_or_d) (Ok ()) f_or_ds
     else Lwt.return @@ Ok ()) >>= function
    | Error e -> Lwt.return @@ Error e
    | Ok () -> destroy_file_or_empty_dir fs f_or_d

  let pp_error = Fs.pp_error
  let pp_write_error = Fs.pp_write_error

  (* TODO check the following invariants:
      - every resource has a .prop.xml file
      - there are no references to non-existing principals (e.g. in <acl><ace>)
      - all principals (apart from groups) have a password and salt (of type Pcdata)
      - all local URLs use the correct hostname *)
  let valid fs config =
    get_property_map fs (`Dir [config.Webdav_config.principals ; "root"]) >|= fun root_map ->
    match
      Properties.unsafe_find (Xml.robur_ns, "password") root_map,
      Properties.unsafe_find (Xml.robur_ns, "salt") root_map
    with
    | Some _, Some _ -> Ok ()
    | _ -> Error (`Msg "root user does not have password and salt")

end
