open Cohttp_lwt_unix
open Lwt.Infix

module Fs = Webdav_fs

(* Apply the [Webmachine.Make] functor to the Lwt_unix-based IO module
 * exported by cohttp. For added convenience, include the [Rd] module
 * as well so you don't have to go reaching into multiple modules to
 * access request-related information. *)
module Wm = struct
  module Rd = Webmachine.Rd
  include Webmachine.Make(Cohttp_lwt_unix__Io)
end

let file_to_propertyfile filename =
  filename ^ ".prop.xml"

let get_properties fs filename =
  let propfile = file_to_propertyfile filename in
  Fs.size fs propfile >>= function
  | Error e -> 
    Format.printf "get_properties failed %s %a\n" propfile Fs.pp_error e;
    Lwt.return (Error e)
  | Ok size -> Fs.read fs propfile 0 (Int64.to_int size)

let get_property_tree fs filename =
  get_properties fs filename >|= function
  | Error _ -> None
  | Ok data -> Webdav.string_to_tree Cstruct.(to_string @@ concat data)

let process_properties fs prefix url f =
  Printf.printf "processing properties of %s\n" url ;
  get_property_tree fs url >|= function
  | None -> `Not_found
  | Some xml ->
    Printf.printf "read tree %s\n" (Webdav.tree_to_string xml) ;
    let xml' = f xml in
    Printf.printf "^^^^ read tree %s\n" (Webdav.tree_to_string xml') ;
    let res = `OK in
    let status =
      Format.sprintf "%s %s"
        (Cohttp.Code.string_of_version `HTTP_1_1)
        (Cohttp.Code.string_of_status res)
    in
    let open Tyxml.Xml in
    let tree =
      node "response"
        [ node "href" [ pcdata (prefix ^ "/" ^ url) ] ;
          node "propstat" [
            Webdav.tree_to_tyxml xml' ;
            node "status" [ pcdata status ] ] ]
    in
    `Single_response tree

let process_property_leaf fs prefix req url =
  let f = match req with
   | `Propname -> Webdav.drop_pcdata
   | `All_prop includes -> (fun id -> id)
   | `Props ps -> Webdav.filter_in_ps ps
  in process_properties fs prefix url f

(* exclude property files *)
let real_files files =
  let ends_in_prop x = not @@ Astring.String.is_suffix ~affix:"prop.xml" x in
  List.filter ends_in_prop files

let process_files fs prefix url req els =
  real_files (url :: els) |> 
  Lwt_list.map_s (process_property_leaf fs prefix req) >|= fun answers ->
  (* answers : [ `Not_found | `Single_response of Tyxml.Xml.node ] list *)
  let nodes = List.fold_left (fun acc element ->
      match element with
      | `Not_found -> acc
      | `Single_response node -> node :: acc) [] answers
  in
  let multistatus =
    Tyxml.Xml.(node
                 ~a:[ string_attrib "xmlns" (Tyxml_xml.W.return "DAV:") ]
                 "multistatus" nodes)
  in
  `Response (Webdav.tyxml_to_body multistatus)

let dav_ns = Tyxml.Xml.string_attrib "xmlns" (Tyxml_xml.W.return "DAV:")

let propfind fs url prefix req =
  Fs.stat fs url >>= function
  | Error _ -> assert false
  | Ok stat when stat.directory ->
    begin
      Fs.listdir fs url >>= function
      | Error _ -> assert false
      | Ok els -> process_files fs prefix url req els
    end
  | Ok _ ->
    process_property_leaf fs prefix req url >|= function
    | `Not_found -> `Property_not_found
    | `Single_response t ->
      let outer =
        Tyxml.Xml.(node ~a:[ dav_ns ] "multistatus" [ t ])
      in
      `Response (Webdav.tyxml_to_body outer)

let parse_depth = function
  | None -> Ok `Infinity
  | Some "0" -> Ok `Zero
  | Some "1" -> Ok `One
  | Some "infinity" -> Ok `Infinity
  | _ -> Error `Bad_request

let to_status x = Cohttp.Code.code_of_status x

let error_xml element =
  Tyxml.Xml.(node ~a:[ dav_ns ] "error" [ node element [] ])
  |> Webdav.tyxml_to_body

let ptime_to_http_date ptime = 
  let (y, m, d), ((hh, mm, ss), _)  = Ptime.to_date_time ptime
  and weekday = match Ptime.weekday ptime with
  | `Mon -> "Mon"
  | `Tue -> "Tue"
  | `Wed -> "Wed"
  | `Thu -> "Thu"
  | `Fri -> "Fri"
  | `Sat -> "Sat"
  | `Sun -> "Sun"
  and month = [|"Jan"; "Feb"; "Mar"; "Apr"; "May"; "Jun"; "Jul"; "Aug"; "Sep"; "Oct"; "Nov"; "Dec"|]
  in 
  Printf.sprintf "%s, %02d %s %04d %02d:%02d:%02d GMT" weekday d (Array.get month (m-1)) y hh mm ss 

let write_property_tree fs name is_dir tree : (unit, [> Mirage_fs.write_error]) result Lwt.t =
  let propfile = Webdav.tyxml_to_body tree in
  let trailing_slash = if is_dir then "/" else "" in
  let filename = file_to_propertyfile (name ^ trailing_slash) in
  Fs.write fs filename 0 (Cstruct.of_string propfile)

let create_properties fs name content_type is_dir length =
  Printf.printf "Creating properties!!! %s \n" name;
  let props file =
    Webdav.create_properties ~content_type
      is_dir (ptime_to_http_date (Ptime_clock.now ())) length file
  in
  write_property_tree fs name is_dir (props name)

(* mkdir -p with properties *)
let create_dir_rec fs name =
  let segments = Astring.String.cuts ~sep:"/" name in
  let rec prefixes = function
    | [] -> []
    | h :: t -> [] :: (List.map (fun a -> h :: a) (prefixes t)) in
  let directories = prefixes segments in
  let create_dir path =
    let filename = String.concat "/" path in 
    Mirage_fs_mem.mkdir fs filename >>= fun _ ->
    create_properties fs filename "text/directory" true 0 >|= fun _ ->
    Printf.printf "creating properties %s\n" filename;
    () in 
  Lwt_list.iter_s create_dir directories

let etag str = Digest.to_hex @@ Digest.string str

let last_modified_pure fs file =
  get_property_tree fs file >|= function 
  | None -> 
    Printf.printf "error while building tree, file %s" file;
    assert false
  | Some xml ->
    match Webdav.filter_in_ps [ "getlastmodified" ] xml with
    | `Node (_, _, (`Node (_, _, `Pcdata last_modified :: _) :: _)) -> last_modified
    | _ -> 
      Printf.printf "error while retrieving last_modified, file %s" file;
      assert false

(* assumption: path is a directory - otherwise we return none *)
(* out: ( name * typ * last_modified ) list - non-recursive *)
let list_dir fs dir =
  let list_file file =
    let full_filename = dir ^ file in
    last_modified_pure fs full_filename >>= fun last_modified ->
    Fs.stat fs full_filename >|= function
    | Error _ -> assert false
    | Ok stat -> 
    let is_dir = stat.Mirage_fs.directory in
    full_filename, is_dir, last_modified in
  Fs.listdir fs dir >>= function
  | Error e -> assert false
  | Ok files -> Lwt_list.map_p list_file (real_files files)

let print_dir prefix files = 
  let print_file (file, is_dir, last_modified) =
    Printf.sprintf "<tr><td><a href=\"%s/%s\">%s</a></td><td>%s</td><td>%s</td></tr>"
      prefix file file (if is_dir then "directory" else "text/calendar") last_modified in
  String.concat "\n" (List.map print_file files)

let apply_updates fs id updates =
  let remove name t = 
    let f node kids tail = match node with
    | `Node (a, n, _) -> if n = name then tail else `Node (a, n, kids) :: tail 
    | `Pcdata d -> `Pcdata d :: tail in 
    match Webdav.tree_fold f [] [t] with
    | [tree] -> Some tree
    | _ -> None
  in 
  let update_fun t = 
    let apply t update = match t, update with
      | None, _ -> None
      | Some t, `Set (k, v) -> Some t
      | Some t, `Remove k   -> remove k t in
    List.fold_left apply t updates in
  get_property_tree fs id >>= fun tree -> match update_fun tree with
  | None -> assert false
  | Some t -> write_property_tree fs id false (Webdav.tree_to_tyxml t)
      

(** A resource for querying an individual item in the database by id via GET,
    modifying an item via PUT, and deleting an item via DELETE. *)
class handler prefix fs = object(self)
  inherit [Cohttp_lwt.Body.t] Wm.resource

  method private write_calendar rd =
    Cohttp_lwt.Body.to_string rd.Wm.Rd.req_body >>= fun body ->
    let name = self#id rd in
    let content_type =
      match Cohttp.Header.get rd.Wm.Rd.req_headers "Content-Type" with
      | None -> "text/calendar"
      | Some x -> x
    in
    match Icalendar.parse body with
    | Error e ->
      Printf.printf "error %s while parsing calendar\n" e ;
      Wm.continue false rd
    | Ok cal ->
      let ics = Icalendar.to_ics cal in
      create_dir_rec fs name >>= fun () ->
      Fs.write fs name 0 (Cstruct.of_string ics) >>= fun _ ->
      create_properties fs name content_type false (String.length ics) >>= fun _ ->
      let etag = etag ics in
      let rd = Wm.Rd.with_resp_headers (fun header ->
          let header' = Cohttp.Header.remove header "ETag" in
          Cohttp.Header.add header' "Etag" etag) rd
      in
      Wm.continue true rd

  method private read_calendar rd =
    let file = self#id rd in

    let (>>==) a f = a >>= function
    | Error e -> 
      Format.printf "Error %s: %a\n" file Fs.pp_error e ;
      Wm.continue `Empty rd
    | Ok res  -> f res in

    Fs.stat fs file >>== function
    | stat when stat.Mirage_fs.directory ->
      Printf.printf "is a directory\n" ;
      list_dir fs file >>= fun files ->
      let listing = print_dir prefix files in
      Wm.continue (`String listing) rd
    | _ -> 
      Fs.size fs file >>== fun bytes ->
      Fs.read fs (self#id rd) 0 (Int64.to_int bytes) >>== fun data ->
      let value = String.concat "" @@ List.map Cstruct.to_string data in
      get_property_tree fs file >>= function
      | None -> Wm.continue `Empty rd
      | Some xml ->
        let get_ct xml = match xml with
          | `Node (a, "prop", children) ->
            let ct =
              List.find
                (function `Node (_, "getcontenttype", _) -> true | _ -> false)
                children
            in
            begin match ct with
              | `Node (_, _, [ `Pcdata contenttype ]) -> contenttype
              | _ -> assert false
            end
          | _ -> assert false
        in
        let ct = try get_ct xml with _ -> "text/calendar" in
        let rd =
          Wm.Rd.with_resp_headers (fun header ->
              let header' = Cohttp.Header.remove header "Content-Type" in
              Cohttp.Header.add header' "Content-Type" ct)
            rd
        in
        Wm.continue (`String value) rd

  method allowed_methods rd =
    Wm.continue [`GET; `HEAD; `PUT; `DELETE; `OPTIONS; `Other "PROPFIND"; `Other "PROPPATCH"; `Other "COPY" ; `Other "MOVE"] rd

  method known_methods rd =
    Wm.continue [`GET; `HEAD; `PUT; `DELETE; `OPTIONS; `Other "PROPFIND"; `Other "PROPPATCH"; `Other "COPY" ; `Other "MOVE"] rd

  method charsets_provided rd =
    Wm.continue [
      "utf-8", (fun id -> id)
    ] rd

  method resource_exists rd =
    (* Printf.printf "RESOURCE exists %s \n" (self#id rd); *)
    Fs.stat fs (self#id rd) >>= function
    | Error _ ->
      (* Printf.printf "FALSE\n"; *)
      Wm.continue false rd
    | Ok _ ->
      (* Printf.printf "TRUE\n"; *)
      Wm.continue true rd

  method content_types_provided rd =
    Wm.continue [
      "text/calendar", self#read_calendar
    ] rd

  method content_types_accepted rd =
    Wm.continue [
      "text/calendar", self#write_calendar
    ] rd

  method private process_propfind rd =
    let depth = Cohttp.Header.get rd.Wm.Rd.req_headers "Depth" in
    let find_property req rd = 
      propfind fs (self#id rd) prefix req >>= function 
      | `Response body -> Wm.continue `Multistatus { rd with Wm.Rd.resp_body = `String body }
      | `Property_not_found -> Wm.continue `Property_not_found rd in
    match parse_depth depth with
    | Error `Bad_request -> Wm.respond (to_status `Bad_request) rd
    | Ok `Infinity ->
      let body = `String (error_xml "propfind-finite-depth") in
      Printf.printf "FORBIDDEN\n";
      Wm.respond ~body (to_status `Forbidden) rd
    | Ok d ->
      (* TODO actually deal with depth d (`Zero or `One) *)
      Cohttp_lwt.Body.to_string rd.Wm.Rd.req_body >>= fun body -> 
      match Webdav.parse_propfind_xml body with
      | None -> Wm.continue `Property_not_found rd
      | Some req -> find_property req rd

  method private process_proppatch rd =
    Cohttp_lwt.Body.to_string rd.Wm.Rd.req_body >>= fun body ->
    Printf.printf "PROPPATCH:%s\n" body; 
    match Webdav.parse_propupdate_xml body with
    | None -> Wm.respond (to_status `Bad_request) rd
    | Some updates -> 
        apply_updates fs (self#id rd) updates >>= function
        | Error _ -> Wm.respond (to_status `Bad_request) rd
        | Ok ()   -> Wm.continue `Ok rd

  method process_property rd =
    let replace_header h = Cohttp.Header.replace h "Content-Type" "application/xml" in
    let rd' = Wm.Rd.with_resp_headers replace_header rd in
    match rd'.Wm.Rd.meth with
    | `Other "PROPFIND" -> self#process_propfind rd' 
    | `Other "PROPPATCH" -> self#process_proppatch rd'

  method delete_resource rd =
    Fs.destroy fs (self#id rd) >>= fun res ->
    let deleted, resp_body =
      match res with
      | Ok () -> true, `String "{\"status\":\"ok\"}"
      | Error _ -> false, `String "{\"status\":\"not found\"}"
    in
    Wm.continue deleted { rd with Wm.Rd.resp_body }

  method last_modified rd =
    let file = self#id rd in
    Printf.printf "last modified in webmachine %s\n" file;
    let to_lwt_option = function
    | Error _ -> Lwt.return None
    | Ok _ -> 
      last_modified_pure fs file >|= fun last_modified ->
      Some last_modified in
    Fs.stat fs file >>= to_lwt_option >>= fun res ->
    Wm.continue res rd
    
  method generate_etag rd =
    let file = self#id rd in
    Fs.stat fs file >>= function
    | Error _ -> Wm.continue None rd
    | Ok stat ->
      last_modified_pure fs (self#id rd) >>= fun lm ->
      let add_headers h = Cohttp.Header.add_list h [ ("Last-Modified", lm) ] in
      let rd = Wm.Rd.with_resp_headers add_headers rd in
      (if stat.Mirage_fs.directory
      then
        list_dir fs file >|= fun files ->
        Some (etag ( print_dir prefix files ))
      else  
        Fs.read fs file 0 (Int64.to_int stat.Mirage_fs.size) >|= function
        | Error _ -> None 
        | Ok bufs -> Some (etag @@ Cstruct.to_string @@ Cstruct.concat bufs)) >>= fun result ->
      Wm.continue result rd

  method finish_request rd =
    let add_headers h = Cohttp.Header.add_list h [ ("DAV", "1") ] in
    let rd = Wm.Rd.with_resp_headers add_headers rd in
    Printf.printf "returning %s\n%!"
      (Cohttp.Header.to_string rd.Wm.Rd.resp_headers) ;
    Wm.continue () rd

  method private id rd =
    let url = Uri.path (rd.Wm.Rd.uri) in
    let pl = String.length prefix in
    let path =
      let p = String.sub url pl (String.length url - pl) in
      if String.length p > 0 && String.get p 0 = '/' then
        String.sub p 1 (String.length p - 1)
      else
        p
    in
    (* Printf.printf "path is %s\n" path ; *)
    path
end

let initialise_fs fs =
  let create_file name data =
    Fs.write fs name 0 (Cstruct.of_string data) >>= fun _ ->
    create_properties fs name "application/json" false (String.length data) in
  create_dir_rec fs "users" >>= fun _ ->
  create_dir_rec fs "__uids__/10000000-0000-0000-0000-000000000001/calendar" >>= fun _ ->
  create_file "1" "{\"name\":\"item 1\"}" >>= fun _ ->
  create_file "2" "{\"name\":\"item 2\"}" >>= fun _ ->
  Lwt.return_unit

let main () =
  (* listen on port 8080 *)
  let port = 8080 in
  (* create the file system *)
  Fs.connect () >>= fun fs ->
  (* the route table *)
  let routes = [
    ("/", fun () -> new handler "/" fs) ;
    ("/principals", fun () -> new handler "/principals" fs) ;
    ("/calendars", fun () -> new handler "/calendars" fs) ;
    ("/calendars/*", fun () -> new handler "/calendars" fs) ;
  ] in
  let callback (ch, conn) request body =
    let open Cohttp in
    (* Perform route dispatch. If [None] is returned, then the URI path did not
     * match any of the route patterns. In this case the server should return a
     * 404 [`Not_found]. *)
    Printf.printf "resource %s meth %s headers %s\n"
      (Request.resource request)
      (Code.string_of_method (Request.meth request))
      (Header.to_string (Request.headers request)) ;
    Wm.dispatch' routes ~body ~request
    >|= begin function
      | None        -> (`Not_found, Header.init (), `String "Not found", [])
      | Some result -> result
    end
    >>= fun (status, headers, body, path) ->
      (* If you'd like to see the path that the request took through the
       * decision diagram, then run this example with the [DEBUG_PATH]
       * environment variable set. This should suffice:
       *
       *  [$ DEBUG_PATH= ./crud_lwt.native]
       *
       *)
      let path =
        match Sys.getenv "DEBUG_PATH" with
        | _ -> Printf.sprintf " - %s" (String.concat ", " path)
        | exception Not_found   -> ""
      in
      Printf.eprintf "%d - %s %s%s"
        (Code.code_of_status status)
        (Code.string_of_method (Request.meth request))
        (Uri.path (Request.uri request))
        path;
      (* Finally, send the response to the client *)
      Server.respond ~headers ~body ~status ()
  in
  (* create the server and handle requests with the function defined above *)
  let conn_closed (ch, conn) =
    Printf.printf "connection %s closed\n%!"
      (Sexplib.Sexp.to_string_hum (Conduit_lwt_unix.sexp_of_flow ch))
  in
  initialise_fs fs >>= fun () ->
  let config = Server.make ~callback ~conn_closed () in
  Server.create  ~mode:(`TCP(`Port port)) config
  >>= (fun () -> Printf.eprintf "hello_lwt: listening on 0.0.0.0:%d%!" port;
      Lwt.return_unit)

let () =  Lwt_main.run (main ())
