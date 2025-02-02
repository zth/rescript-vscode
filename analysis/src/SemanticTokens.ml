(*
   Generally speaking, semantic highlighting here takes care of categorizing identifiers,
   since the kind of an identifier is highly context-specific and hard to catch with a grammar.

   The big exception is labels, whose location is not represented in the AST
   E.g. function definition such as (~foo as _) =>, application (~foo=3) and prop <div foo=3>.
   Labels are handled in the grammar, not here.
   Punned labels such as (~foo) => are both labels and identifiers. They are overridden here.

   There are 2 cases where the grammar and semantic highlighting work jointly.
   The styles emitted in the grammar and here need to be kept in sync.
   1) For jsx angled brackets, the grammar handles basic cases such as />
      whose location is not in the AST.
      Instead < and > are handled here. Those would be difficult to disambiguate in a grammar.
   2) Most operators are handled in the grammar. Except < and > are handled here.
      The reason is again that < and > would be difficult do disambiguate in a grammar.
*)

module Token = struct
  (* This needs to stay synced with the same legend in `server.ts` *)
  (* See https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_semanticTokens *)
  type tokenType =
    | Operator  (** < and > *)
    | Variable  (** let x = *)
    | Type  (** type t = *)
    | JsxTag  (** the < and > in <div> *)
    | Class  (** module M = *)
    | EnumMember  (** variant A or poly variant #A *)
    | Property  (** {x:...} *)
    | JsxLowercase  (** div in <div> *)

  type tokenModifiers = NoModifier

  let tokenTypeToString = function
    | Operator -> "0"
    | Variable -> "1"
    | Type -> "2"
    | JsxTag -> "3"
    | Class -> "4"
    | EnumMember -> "5"
    | Property -> "6"
    | JsxLowercase -> "7"

  let tokenTypeDebug = function
    | Operator -> "Operator"
    | Variable -> "Variable"
    | Type -> "Type"
    | JsxTag -> "JsxTag"
    | Class -> "Class"
    | EnumMember -> "EnumMember"
    | Property -> "Property"
    | JsxLowercase -> "JsxLowercase"

  let tokenModifiersToString = function NoModifier -> "0"

  type token = int * int * int * tokenType * tokenModifiers

  type emitter = {
    mutable tokens : token list;
    mutable lastLine : int;
    mutable lastChar : int;
  }

  let createEmitter () = {tokens = []; lastLine = 0; lastChar = 0}

  let add ~line ~char ~length ~type_ e =
    let modifiers = NoModifier in
    e.tokens <- (line, char, length, type_, modifiers) :: e.tokens

  let emitToken buf (line, char, length, type_, modifiers) e =
    let deltaLine = line - e.lastLine in
    let deltaChar = if deltaLine = 0 then char - e.lastChar else char in
    e.lastLine <- line;
    e.lastChar <- char;
    if Buffer.length buf > 0 then Buffer.add_char buf ',';
    Buffer.add_string buf
      (string_of_int deltaLine ^ "," ^ string_of_int deltaChar ^ ","
     ^ string_of_int length ^ "," ^ tokenTypeToString type_ ^ ","
      ^ tokenModifiersToString modifiers)

  let emit e =
    let sortedTokens =
      e.tokens
      |> List.sort (fun (l1, c1, _, _, _) (l2, c2, _, _, _) ->
             if l1 = l2 then compare c1 c2 else compare l1 l2)
    in
    let buf = Buffer.create 1 in
    sortedTokens |> List.iter (fun t -> e |> emitToken buf t);
    Buffer.contents buf
end

let locToPositions (loc : Location.t) =
  (Utils.tupleOfLexing loc.loc_start, Utils.tupleOfLexing loc.loc_end)

let posToString (loc, col) = Printf.sprintf "(%d,%d)" loc col

let locToString (loc : Location.t) =
  let posStart, posEnd = locToPositions loc in
  Printf.sprintf "%s->%s" (posToString posStart) (posToString posEnd)

let isLowercaseId id =
  id <> ""
  &&
  let c = id.[0] in
  c == '_' || (c >= 'a' && c <= 'z')

let isUppercaseId id =
  id <> ""
  &&
  let c = id.[0] in
  c >= 'A' && c <= 'Z'

let emitFromPos posStart posEnd ~type_ emitter =
  let length =
    if fst posStart = fst posEnd then snd posEnd - snd posStart else 0
  in
  if length > 0 then
    emitter
    |> Token.add ~line:(fst posStart) ~char:(snd posStart) ~length ~type_

let emitFromLoc ~loc ~type_ emitter =
  let posStart, posEnd = locToPositions loc in
  emitter |> emitFromPos posStart posEnd ~type_

let emitLongident ?(backwards = false) ?(jsx = false)
    ?(lowerCaseToken = if jsx then Token.JsxLowercase else Token.Variable)
    ?(upperCaseToken = Token.Class) ?(lastToken = None) ?(posEnd = None) ~pos
    ~lid ~debug emitter =
  let rec flatten acc lid =
    match lid with
    | Longident.Lident txt -> txt :: acc
    | Ldot (lid, txt) ->
      let acc = if jsx && txt = "createElement" then acc else txt :: acc in
      flatten acc lid
    | _ -> acc
  in
  let rec loop pos segments =
    match segments with
    | [id] when isUppercaseId id || isLowercaseId id ->
      let type_ =
        match lastToken with
        | Some type_ -> type_
        | None -> if isUppercaseId id then upperCaseToken else lowerCaseToken
      in
      let posAfter = (fst pos, snd pos + String.length id) in
      let posEnd, lenMismatch =
        (* There could be a length mismatch when ids are quoted
           e.g. variable /"true" or object field {"x":...} *)
        match posEnd with
        | Some posEnd -> (posEnd, posEnd <> posAfter)
        | None -> (posAfter, false)
      in
      if debug then
        Printf.printf "Lident: %s %s%s %s\n" id (posToString pos)
          (if lenMismatch then "->" ^ posToString posEnd else "")
          (Token.tokenTypeDebug type_);
      emitter |> emitFromPos pos posEnd ~type_
    | id :: segments when isUppercaseId id || isLowercaseId id ->
      let type_ = if isUppercaseId id then upperCaseToken else lowerCaseToken in
      if debug then
        Printf.printf "Ldot: %s %s %s\n" id (posToString pos)
          (Token.tokenTypeDebug type_);
      let length = String.length id in
      emitter |> emitFromPos pos (fst pos, snd pos + length) ~type_;
      loop (fst pos, snd pos + length + 1) segments
    | _ -> ()
  in
  let segments = flatten [] lid in
  if backwards then (
    let totalLength = segments |> String.concat "." |> String.length in
    if snd pos >= totalLength then
      loop (fst pos, snd pos - totalLength) segments)
  else loop pos segments

let emitVariable ~id ~debug ~loc emitter =
  if debug then Printf.printf "Variable: %s %s\n" id (locToString loc);
  emitter |> emitFromLoc ~loc ~type_:Variable

let emitJsxOpen ~lid ~debug ~loc emitter =
  emitter
  |> emitLongident
       ~pos:(Utils.tupleOfLexing loc.Location.loc_start)
       ~lid ~jsx:true ~debug

let emitJsxClose ~lid ~debug ~pos emitter =
  emitter |> emitLongident ~backwards:true ~pos ~lid ~jsx:true ~debug

let emitJsxTag ~debug ~name ~pos emitter =
  if debug then Printf.printf "JsxTag %s: %s\n" name (posToString pos);
  emitter |> emitFromPos pos (fst pos, snd pos + 1) ~type_:Token.JsxTag

let emitType ~lid ~debug ~loc emitter =
  emitter
  |> emitLongident ~lowerCaseToken:Token.Type
       ~pos:(Utils.tupleOfLexing loc.Location.loc_start)
       ~lid ~debug

let emitRecordLabel ~(label : Longident.t Location.loc) ~debug emitter =
  emitter
  |> emitLongident ~lowerCaseToken:Token.Property
       ~pos:(Utils.tupleOfLexing label.loc.loc_start)
       ~posEnd:(Some (Utils.tupleOfLexing label.loc.loc_end))
       ~lid:label.txt ~debug

let emitVariant ~(name : Longident.t Location.loc) ~debug emitter =
  emitter
  |> emitLongident ~lastToken:(Some Token.EnumMember)
       ~pos:(Utils.tupleOfLexing name.loc.loc_start)
       ~lid:name.txt ~debug

let command ~debug ~emitter ~path =
  let processTypeArg (coreType : Parsetree.core_type) =
    if debug then Printf.printf "TypeArg: %s\n" (locToString coreType.ptyp_loc)
  in
  let typ (mapper : Ast_mapper.mapper) (coreType : Parsetree.core_type) =
    match coreType.ptyp_desc with
    | Ptyp_constr ({txt = lid; loc}, args) ->
      emitter |> emitType ~lid ~debug ~loc;
      args |> List.iter processTypeArg;
      Ast_mapper.default_mapper.typ mapper coreType
    | _ -> Ast_mapper.default_mapper.typ mapper coreType
  in
  let type_declaration (mapper : Ast_mapper.mapper)
      (tydecl : Parsetree.type_declaration) =
    emitter
    |> emitType ~lid:(Lident tydecl.ptype_name.txt) ~debug
         ~loc:tydecl.ptype_name.loc;
    Ast_mapper.default_mapper.type_declaration mapper tydecl
  in
  let pat (mapper : Ast_mapper.mapper) (p : Parsetree.pattern) =
    match p.ppat_desc with
    | Ppat_var {txt = id} ->
      if isLowercaseId id then
        emitter |> emitVariable ~id ~debug ~loc:p.ppat_loc;
      Ast_mapper.default_mapper.pat mapper p
    | Ppat_construct ({txt = Lident ("true" | "false")}, _) ->
      (* Don't emit true or false *)
      Ast_mapper.default_mapper.pat mapper p
    | Ppat_record (cases, _) ->
      cases
      |> List.iter (fun (label, _) -> emitter |> emitRecordLabel ~label ~debug);
      Ast_mapper.default_mapper.pat mapper p
    | Ppat_construct (name, _) ->
      emitter |> emitVariant ~name ~debug;
      Ast_mapper.default_mapper.pat mapper p
    | Ppat_type {txt = lid; loc} ->
      emitter |> emitType ~lid ~debug ~loc;
      Ast_mapper.default_mapper.pat mapper p
    | _ -> Ast_mapper.default_mapper.pat mapper p
  in
  let expr (mapper : Ast_mapper.mapper) (e : Parsetree.expression) =
    match e.pexp_desc with
    | Pexp_ident {txt = lid; loc} ->
      if lid <> Lident "not" then
        emitter
        |> emitLongident
             ~pos:(Utils.tupleOfLexing loc.loc_start)
             ~posEnd:(Some (Utils.tupleOfLexing loc.loc_end))
             ~lid ~debug;
      Ast_mapper.default_mapper.expr mapper e
    | Pexp_apply ({pexp_desc = Pexp_ident lident; pexp_loc}, args)
      when Res_parsetree_viewer.isJsxExpression e ->
      (*
         Angled brackets:
          - These are handled in the grammar:  <>  </>  </  />
          - Here we handle `<` and `>`

         Component names:
          - handled like other Longitent.t, except lowercase id is marked Token.JsxLowercase
      *)
      emitter (* --> <div... *)
      |> emitJsxTag ~debug ~name:"<"
           ~pos:
             (let pos = Utils.tupleOfLexing e.pexp_loc.loc_start in
              (fst pos, snd pos - 1 (* the AST skips the loc of < somehow *)));
      emitter |> emitJsxOpen ~lid:lident.txt ~debug ~loc:pexp_loc;

      let posOfGreatherthanAfterProps =
        let rec loop = function
          | (Asttypes.Labelled "children", {Parsetree.pexp_loc = {loc_start}})
            :: _ ->
            Utils.tupleOfLexing loc_start
          | _ :: args -> loop args
          | [] -> (* should not happen *) (-1, -1)
        in

        loop args
      in
      let posOfFinalGreatherthan =
        let pos = Utils.tupleOfLexing e.pexp_loc.loc_end in
        (fst pos, snd pos - 1)
      in
      let selfClosing =
        fst posOfGreatherthanAfterProps == fst posOfFinalGreatherthan
        && snd posOfGreatherthanAfterProps + 1 == snd posOfFinalGreatherthan
        (* there's an off-by one somehow in the AST *)
      in
      (if not selfClosing then
       let lineStart, colStart = Utils.tupleOfLexing pexp_loc.loc_start in
       let lineEnd, colEnd = Utils.tupleOfLexing pexp_loc.loc_end in
       let length = if lineStart = lineEnd then colEnd - colStart else 0 in
       let lineEndWhole, colEndWhole = Utils.tupleOfLexing e.pexp_loc.loc_end in
       if length > 0 && colEndWhole > length then (
         emitter
         |> emitJsxClose ~debug ~lid:lident.txt
              ~pos:(lineEndWhole, colEndWhole - 1);
         emitter (* <foo ...props > <-- *)
         |> emitJsxTag ~debug ~name:">" ~pos:posOfGreatherthanAfterProps;
         emitter (* <foo> ... </foo> <-- *)
         |> emitJsxTag ~debug ~name:">" ~pos:posOfFinalGreatherthan));

      let _ = args |> List.map (fun (_lbl, arg) -> mapper.expr mapper arg) in
      e
    | Pexp_apply
        ( {
            pexp_desc =
              Pexp_ident {txt = Longident.Lident (("<" | ">") as op); loc};
          },
          [_; _] ) ->
      if debug then Printf.printf "Binary operator %s %s\n" op (locToString loc);
      emitter |> emitFromLoc ~loc ~type_:Operator;
      Ast_mapper.default_mapper.expr mapper e
    | Pexp_record (cases, _) ->
      cases
      |> List.iter (fun (label, _) -> emitter |> emitRecordLabel ~label ~debug);
      Ast_mapper.default_mapper.expr mapper e
    | Pexp_field (_, label) | Pexp_setfield (_, label, _) ->
      emitter |> emitRecordLabel ~label ~debug;
      Ast_mapper.default_mapper.expr mapper e
    | Pexp_construct ({txt = Lident ("true" | "false")}, _) ->
      (* Don't emit true or false *)
      Ast_mapper.default_mapper.expr mapper e
    | Pexp_construct (name, _) ->
      emitter |> emitVariant ~name ~debug;
      Ast_mapper.default_mapper.expr mapper e
    | _ -> Ast_mapper.default_mapper.expr mapper e
  in
  let module_expr (mapper : Ast_mapper.mapper) (me : Parsetree.module_expr) =
    match me.pmod_desc with
    | Pmod_ident {txt = lid; loc} ->
      emitter
      |> emitLongident ~pos:(Utils.tupleOfLexing loc.loc_start) ~lid ~debug;
      Ast_mapper.default_mapper.module_expr mapper me
    | _ -> Ast_mapper.default_mapper.module_expr mapper me
  in
  let module_binding (mapper : Ast_mapper.mapper)
      (mb : Parsetree.module_binding) =
    emitter
    |> emitLongident
         ~pos:(Utils.tupleOfLexing mb.pmb_name.loc.loc_start)
         ~lid:(Longident.Lident mb.pmb_name.txt) ~debug;
    Ast_mapper.default_mapper.module_binding mapper mb
  in
  let module_declaration (mapper : Ast_mapper.mapper)
      (md : Parsetree.module_declaration) =
    emitter
    |> emitLongident
         ~pos:(Utils.tupleOfLexing md.pmd_name.loc.loc_start)
         ~lid:(Longident.Lident md.pmd_name.txt) ~debug;
    Ast_mapper.default_mapper.module_declaration mapper md
  in
  let module_type (mapper : Ast_mapper.mapper) (mt : Parsetree.module_type) =
    match mt.pmty_desc with
    | Pmty_ident {txt = lid; loc} ->
      emitter
      |> emitLongident ~upperCaseToken:Token.Type
           ~pos:(Utils.tupleOfLexing loc.loc_start)
           ~lid ~debug;
      Ast_mapper.default_mapper.module_type mapper mt
    | _ -> Ast_mapper.default_mapper.module_type mapper mt
  in
  let module_type_declaration (mapper : Ast_mapper.mapper)
      (mtd : Parsetree.module_type_declaration) =
    emitter
    |> emitLongident ~upperCaseToken:Token.Type
         ~pos:(Utils.tupleOfLexing mtd.pmtd_name.loc.loc_start)
         ~lid:(Longident.Lident mtd.pmtd_name.txt) ~debug;
    Ast_mapper.default_mapper.module_type_declaration mapper mtd
  in
  let open_description (mapper : Ast_mapper.mapper)
      (od : Parsetree.open_description) =
    emitter
    |> emitLongident
         ~pos:(Utils.tupleOfLexing od.popen_lid.loc.loc_start)
         ~lid:od.popen_lid.txt ~debug;
    Ast_mapper.default_mapper.open_description mapper od
  in
  let label_declaration (mapper : Ast_mapper.mapper)
      (ld : Parsetree.label_declaration) =
    emitter
    |> emitRecordLabel
         ~label:{loc = ld.pld_name.loc; txt = Longident.Lident ld.pld_name.txt}
         ~debug;
    Ast_mapper.default_mapper.label_declaration mapper ld
  in
  let constructor_declaration (mapper : Ast_mapper.mapper)
      (cd : Parsetree.constructor_declaration) =
    emitter
    |> emitVariant
         ~name:{loc = cd.pcd_name.loc; txt = Longident.Lident cd.pcd_name.txt}
         ~debug;
    Ast_mapper.default_mapper.constructor_declaration mapper cd
  in

  let mapper =
    {
      Ast_mapper.default_mapper with
      constructor_declaration;
      expr;
      label_declaration;
      module_declaration;
      module_binding;
      module_expr;
      module_type;
      module_type_declaration;
      open_description;
      pat;
      typ;
      type_declaration;
    }
  in

  if Filename.check_suffix path ".res" then (
    let parser =
      Res_driver.parsingEngine.parseImplementation ~forPrinter:false
    in
    let {Res_driver.parsetree = structure; diagnostics} =
      parser ~filename:path
    in
    if debug then
      Printf.printf "structure items:%d diagnostics:%d \n"
        (List.length structure) (List.length diagnostics);
    mapper.structure mapper structure |> ignore)
  else
    let parser = Res_driver.parsingEngine.parseInterface ~forPrinter:false in
    let {Res_driver.parsetree = signature; diagnostics} =
      parser ~filename:path
    in
    if debug then
      Printf.printf "signature items:%d diagnostics:%d \n"
        (List.length signature) (List.length diagnostics);
    mapper.signature mapper signature |> ignore

let semanticTokens ~currentFile =
  let emitter = Token.createEmitter () in
  command ~emitter ~debug:false ~path:currentFile;
  Printf.printf "{\"data\":[%s]}" (Token.emit emitter)
