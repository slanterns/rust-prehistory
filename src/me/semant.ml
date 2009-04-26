
(*
 * This module performs most of the semantic lowering:
 *
 *   - building frames full of typed slots
 *   - calculating the size of every type
 *   - resolving every name to a slot
 *   - checking type compatibility of every slot
 *   - running the type-state dataflow algorithm
 *   - checking type-states
 *   - inferring points of allocation and deallocation
 *)

open Common;;


type slots_table = (Ast.slot_key,node_id) Hashtbl.t
type items_table = (Ast.ident,node_id) Hashtbl.t
type block_slots_table = (node_id,slots_table) Hashtbl.t
type block_items_table = (node_id,items_table) Hashtbl.t
;;


type text = {
  text_node: node_id;
  text_quads: Il.quads;
  text_n_vregs: int;
}
;;

type file_grouped_texts = (node_id, ((text list) ref)) Hashtbl.t;;

(* The node_id in the Constr_pred constr_key is the innermost block_id
   of any of the constr's pred name or cargs; this is the *outermost*
   block_id in which its constr_id can possibly be shared. It serves
   only to uniquely identify the constr.
   
   The node_id in the Constr_init constr_key is just a slot id. 
   Constr_init is the builtin (un-named) constraint that means "slot is
   initialized". Not every slot is.
 *)
type constr_key =
    Constr_pred of (Ast.constr * node_id)
  | Constr_init of node_id

type ctxt =
    { ctxt_sess: Session.sess;
      ctxt_block_slots: block_slots_table;
      ctxt_block_items: block_items_table;
      ctxt_all_slots: (node_id,Ast.slot) Hashtbl.t;
      ctxt_all_items: (node_id,Ast.mod_item') Hashtbl.t;
      ctxt_all_item_types: (node_id,Ast.ty) Hashtbl.t;
      ctxt_item_files: (node_id,filename) Hashtbl.t;
      ctxt_lval_to_referent: (node_id,node_id) Hashtbl.t;
      ctxt_slot_aliased: (node_id,unit) Hashtbl.t;

      ctxt_constrs: (constr_id,constr_key) Hashtbl.t;
      ctxt_constr_ids: (constr_key,constr_id) Hashtbl.t;
      ctxt_preconditions: (node_id,Bitv.t) Hashtbl.t;
      ctxt_postconditions: (node_id,Bitv.t) Hashtbl.t;
      ctxt_prestates: (node_id,Bitv.t) Hashtbl.t;
      ctxt_poststates: (node_id,Bitv.t) Hashtbl.t;

      ctxt_slot_vregs: (node_id,((int option) ref)) Hashtbl.t;
      ctxt_slot_layouts: (node_id,layout) Hashtbl.t;
      ctxt_block_layouts: (node_id,layout) Hashtbl.t;
      ctxt_fn_header_layouts: (node_id,layout) Hashtbl.t;
      ctxt_frame_sizes: (node_id,int64) Hashtbl.t;
      ctxt_call_sizes: (node_id,int64) Hashtbl.t;
      ctxt_fn_fixups: (node_id,fixup) Hashtbl.t;
      ctxt_file_fixups: (node_id,fixup) Hashtbl.t;
      ctxt_prog_fixups: (node_id,fixup) Hashtbl.t;
      ctxt_spill_fixups: (node_id,fixup) Hashtbl.t;
      ctxt_abi: Abi.abi;
      mutable ctxt_data_items: Asm.item list;
      ctxt_c_to_proc_fixup: fixup;
      ctxt_proc_to_c_fixup: fixup;
      ctxt_texts: file_grouped_texts;
      mutable ctxt_anon_text_quads: Il.quads list;
      ctxt_main_prog: fixup;
      ctxt_main_name: string;
    }
;;

let new_ctxt sess abi crate =
  { ctxt_sess = sess;
    ctxt_block_slots = Hashtbl.create 0;
    ctxt_block_items = Hashtbl.create 0;
    ctxt_all_slots = Hashtbl.create 0;
    ctxt_all_items = Hashtbl.create 0;
    ctxt_all_item_types = Hashtbl.create 0;
    ctxt_item_files = crate.Ast.crate_files;
    ctxt_lval_to_referent = Hashtbl.create 0;
    ctxt_slot_aliased = Hashtbl.create 0;
    ctxt_constrs = Hashtbl.create 0;
    ctxt_constr_ids = Hashtbl.create 0;
    ctxt_preconditions = Hashtbl.create 0;
    ctxt_postconditions = Hashtbl.create 0;
    ctxt_prestates = Hashtbl.create 0;
    ctxt_poststates = Hashtbl.create 0;
    ctxt_slot_vregs = Hashtbl.create 0;
    ctxt_slot_layouts = Hashtbl.create 0;
    ctxt_block_layouts = Hashtbl.create 0;
    ctxt_fn_header_layouts = Hashtbl.create 0;
    ctxt_frame_sizes = Hashtbl.create 0;
    ctxt_call_sizes = Hashtbl.create 0;
    ctxt_fn_fixups = Hashtbl.create 0;
    ctxt_file_fixups = Hashtbl.create 0;
    ctxt_prog_fixups = Hashtbl.create 0;
    ctxt_spill_fixups = Hashtbl.create 0;
    ctxt_abi = abi;
    ctxt_data_items = [];
    ctxt_c_to_proc_fixup = new_fixup "c-to-proc glue";
    ctxt_proc_to_c_fixup = new_fixup "proc-to-c glue";
    ctxt_texts = Hashtbl.create 0;
    ctxt_anon_text_quads = [];
    ctxt_main_prog = new_fixup "main prog fixup";
    ctxt_main_name = Ast.fmt_to_str Ast.fmt_name crate.Ast.crate_main
  }
;;

exception Semant_err of ((node_id option) * string)
;;

let err (idopt:node_id option) =
  let k s =
    raise (Semant_err (idopt, s))
  in
    Printf.ksprintf k
;;

(* Convenience accessors. *)
let lval_to_referent (cx:ctxt) (id:node_id) : node_id =
  if Hashtbl.mem cx.ctxt_lval_to_referent id
  then Hashtbl.find cx.ctxt_lval_to_referent id
  else err (Some id) "Unresolved lval"
;;

let lval_to_slot (cx:ctxt) (id:node_id) : Ast.slot =
  let referent = lval_to_referent cx id in
    if Hashtbl.mem cx.ctxt_all_slots referent
    then Hashtbl.find cx.ctxt_all_slots referent
    else err (Some referent) "Unknown slot"
;;

let lval_ty (cx:ctxt) (id:node_id) : Ast.ty =
  let referent = lval_to_referent cx id in
    match htab_search cx.ctxt_all_slots referent with
        Some s ->
          begin
            match s.Ast.slot_ty with
                Some t -> t
              | None -> err (Some referent) "Referent has un-inferred type"
          end
      | None -> (Hashtbl.find cx.ctxt_all_item_types referent)
;;

let get_block_layout (cx:ctxt) (id:node_id) : layout =
  if Hashtbl.mem cx.ctxt_block_layouts id
  then Hashtbl.find cx.ctxt_block_layouts id
  else err (Some id) "Unknown block layout"
;;

let get_fn_fixup (cx:ctxt) (id:node_id) : fixup =
  if Hashtbl.mem cx.ctxt_fn_fixups id
  then Hashtbl.find cx.ctxt_fn_fixups id
  else err (Some id) "Fn without fixup"
;;

let get_prog_fixup (cx:ctxt) (id:node_id) : fixup =
  if Hashtbl.mem cx.ctxt_prog_fixups id
  then Hashtbl.find cx.ctxt_prog_fixups id
  else err (Some id) "Prog without fixup"
;;

let get_framesz (cx:ctxt) (id:node_id) : int64 =
  if Hashtbl.mem cx.ctxt_frame_sizes id
  then Hashtbl.find cx.ctxt_frame_sizes id
  else err (Some id) "Missing framesz"
;;

let get_callsz (cx:ctxt) (id:node_id) : int64 =
  if Hashtbl.mem cx.ctxt_call_sizes id
  then Hashtbl.find cx.ctxt_call_sizes id
  else err (Some id) "Missing callsz"
;;

let slot_ty (s:Ast.slot) : Ast.ty =
  match s.Ast.slot_ty with
      Some t -> t
    | None -> err None "untyped slot"
;;


(* Constraint manipulation. *)

let rec apply_atoms_to_carg_path
    (atoms:Ast.atom array)
    (cp:Ast.carg_path)
    : Ast.carg_path =
  match cp with
      Ast.CARG_ext (Ast.CARG_base Ast.BASE_formal,
                    Ast.COMP_idx i) ->
        begin
          match atoms.(i) with
              Ast.ATOM_lval (Ast.LVAL_base nbi) ->
                Ast.CARG_base (Ast.BASE_named nbi.node)
            | _ -> err None "Unhandled form of atom"
        end
    | Ast.CARG_ext (cp', e) ->
        Ast.CARG_ext (apply_atoms_to_carg_path atoms cp', e)
    | _ -> cp
;;

let apply_atoms_to_carg
    (atoms:Ast.atom array)
    (carg:Ast.carg)
    : Ast.carg =
  match carg with
      Ast.CARG_path cp ->
        Ast.CARG_path (apply_atoms_to_carg_path atoms cp)
    | Ast.CARG_lit _ -> carg
;;

let apply_atoms_to_constr
    (atoms:Ast.atom array)
    (constr:Ast.constr)
    : Ast.constr =
  { constr with
      Ast.constr_args =
      Array.map (apply_atoms_to_carg atoms) constr.Ast.constr_args }
;;


(* Mappings between mod items and their respective types. *)

let rec ty_mod_of_mod (inside:bool) (m:Ast.mod_items) : Ast.mod_type_items =
  let ty_items = Hashtbl.create (Hashtbl.length m) in
  let add n i = Hashtbl.add ty_items n (mod_type_item_of_mod_item inside i) in
    Hashtbl.iter add m;
    ty_items

and mod_type_item_of_mod_item (inside:bool) (item:Ast.mod_item) : Ast.mod_type_item =
  let decl params item =
    { Ast.decl_params = params;
      Ast.decl_item = item }
  in
  let ty =
    match item.node with
        Ast.MOD_ITEM_opaque_type td ->
          if inside
          then
            Ast.MOD_TYPE_ITEM_public_type td
          else
            (match (td.Ast.decl_params, td.Ast.decl_item) with
                 (params, Ast.TY_lim _) ->
                   Ast.MOD_TYPE_ITEM_opaque_type
                     (decl params Ast.LIMITED)
               | (params, _) ->
                   Ast.MOD_TYPE_ITEM_opaque_type
                     (decl params Ast.UNLIMITED))
      | Ast.MOD_ITEM_public_type td ->
          Ast.MOD_TYPE_ITEM_public_type td
      | Ast.MOD_ITEM_pred pd ->
          Ast.MOD_TYPE_ITEM_pred
            (decl pd.Ast.decl_params (ty_pred_of_pred pd.Ast.decl_item))
      | Ast.MOD_ITEM_mod md ->
            Ast.MOD_TYPE_ITEM_mod
              (decl md.Ast.decl_params (ty_mod_of_mod true md.Ast.decl_item))
      | Ast.MOD_ITEM_fn fd ->
          Ast.MOD_TYPE_ITEM_fn
            (decl fd.Ast.decl_params (ty_fn_of_fn fd.Ast.decl_item))
      | Ast.MOD_ITEM_prog pd ->
          Ast.MOD_TYPE_ITEM_prog
            (decl pd.Ast.decl_params (ty_prog_of_prog pd.Ast.decl_item))
  in
    { id = item.id;
      node = ty }

and ty_prog_of_prog (prog:Ast.prog) : Ast.ty_prog =
  let init_ty =
    match prog.Ast.prog_init with
        None -> None
      | Some init -> Some (arg_slots init.node.Ast.init_input_slots)
  in init_ty

and arg_slots (slots:((Ast.slot identified) * Ast.ident) array) : Ast.slot array =
  Array.map (fun (sid,_) -> sid.node) slots

and ty_fn_of_fn (fn:Ast.fn) : Ast.ty_fn =
  ({ Ast.sig_input_slots = arg_slots fn.Ast.fn_input_slots;
     Ast.sig_input_constrs = fn.Ast.fn_input_constrs;
     Ast.sig_output_slot = fn.Ast.fn_output_slot.node },
   fn.Ast.fn_aux )

and ty_pred_of_pred (pred:Ast.pred) : Ast.ty_pred =
  (arg_slots pred.Ast.pred_input_slots,
   pred.Ast.pred_input_constrs)


and ty_of_mod_item (inside:bool) (item:Ast.mod_item) : Ast.ty =
  let check_concrete params ty =
    if Array.length params = 0
    then ty
    else err (Some item.id) "item has parametric type in type_of_mod_item"
  in
    match item.node with
        Ast.MOD_ITEM_opaque_type td ->
          check_concrete td.Ast.decl_params Ast.TY_type

      | Ast.MOD_ITEM_public_type td ->
          check_concrete td.Ast.decl_params Ast.TY_type

      | Ast.MOD_ITEM_pred pd ->
          check_concrete pd.Ast.decl_params
            (Ast.TY_pred (ty_pred_of_pred pd.Ast.decl_item))

      | Ast.MOD_ITEM_mod md ->
          check_concrete md.Ast.decl_params
            (Ast.TY_mod (ty_mod_of_mod inside md.Ast.decl_item))

      | Ast.MOD_ITEM_fn fd ->
          check_concrete fd.Ast.decl_params
            (Ast.TY_fn (ty_fn_of_fn fd.Ast.decl_item))

      | Ast.MOD_ITEM_prog pd ->
          check_concrete pd.Ast.decl_params
            (Ast.TY_prog (ty_prog_of_prog pd.Ast.decl_item))
;;

(* Scopes and the visitor that builds them. *)

type scope =
    SCOPE_block of node_id
  | SCOPE_mod_item of Ast.mod_item
  | SCOPE_mod_type_item of Ast.mod_type_item

let scope_stack_managing_visitor
    (scopes:scope Stack.t)
    (inner:Walk.visitor)
    : Walk.visitor =
  let visit_block_pre b =
    Stack.push (SCOPE_block b.id) scopes;
    inner.Walk.visit_block_pre b
  in
  let visit_block_post b =
    inner.Walk.visit_block_post b;
    ignore (Stack.pop scopes)
  in
  let visit_mod_item_pre n p i =
    Stack.push (SCOPE_mod_item i) scopes;
    inner.Walk.visit_mod_item_pre n p i
  in
  let visit_mod_item_post n p i =
    inner.Walk.visit_mod_item_post n p i;
    ignore (Stack.pop scopes)
  in
  let visit_mod_type_item_pre n p i =
    Stack.push (SCOPE_mod_type_item i) scopes;
    inner.Walk.visit_mod_type_item_pre n p i
  in
  let visit_mod_type_item_post n p i =
    inner.Walk.visit_mod_type_item_post n p i;
    ignore (Stack.pop scopes)
  in
    { inner with
        Walk.visit_block_pre = visit_block_pre;
        Walk.visit_block_post = visit_block_post;
        Walk.visit_mod_item_pre = visit_mod_item_pre;
        Walk.visit_mod_item_post = visit_mod_item_post;
        Walk.visit_mod_type_item_pre = visit_mod_type_item_pre;
        Walk.visit_mod_type_item_post = visit_mod_type_item_post; }
;;

(* Generic lookup, used for slots, items, types, etc. *)
(* 
 * FIXME: currently doesn't lookup inside type-item scopes
 * nor return type variables bound by items. 
 *)
let lookup
    (cx:ctxt)
    (scopes:scope Stack.t)
    (key:Ast.slot_key)
    : ((scope * node_id) option) =
  let check_items scope ident items =
    if Hashtbl.mem items ident
    then
      let item = Hashtbl.find items ident in
        Some (scope, item.id)
    else
      None
  in
  let check_scope scope =
    match scope with
        SCOPE_block block_id ->
          let block_slots = Hashtbl.find cx.ctxt_block_slots block_id in
          let block_items = Hashtbl.find cx.ctxt_block_items block_id in
            if Hashtbl.mem block_slots key
            then
              let id = Hashtbl.find block_slots key in
                Some (scope, id)
            else
              begin
                match key with
                    Ast.KEY_temp _ -> None
                  | Ast.KEY_ident ident ->
                      if Hashtbl.mem block_items ident
                      then
                        let id = Hashtbl.find block_items ident in
                          Some (scope, id)
                      else
                        None
              end
      | SCOPE_mod_item item ->
          begin
            match key with
                Ast.KEY_temp _ -> None
              | Ast.KEY_ident ident ->
                  begin
                    let match_input_slot islots =
                      arr_search islots
                        (fun _ (sloti,ident') ->
                           if ident = ident'
                           then Some (scope, sloti.id)
                           else None)
                    in
                    match item.node with
                        Ast.MOD_ITEM_fn f ->
                          match_input_slot f.Ast.decl_item.Ast.fn_input_slots

                      | Ast.MOD_ITEM_pred p ->
                          match_input_slot p.Ast.decl_item.Ast.pred_input_slots

                      | Ast.MOD_ITEM_mod m ->
                          check_items scope ident m.Ast.decl_item

                      | Ast.MOD_ITEM_prog p ->
                          check_items scope ident p.Ast.decl_item.Ast.prog_mod

                      | _ -> None
                  end
            end
      | _ -> None
  in
    stk_search scopes check_scope
;;


let run_passes
    (cx:ctxt)
    (passes:Walk.visitor array)
    (log:string->unit)
    (items:Ast.mod_items)
    : unit =
  let do_pass i p =
    let logger s = log (Printf.sprintf "pass %d: %s" i s) in
      Walk.walk_mod_items
        (Walk.mod_item_logging_visitor logger p)
        items
  in
  let sess = cx.ctxt_sess in
    if sess.Session.sess_failed
    then ()
    else
      try
        Array.iteri do_pass passes
      with
          Semant_err (ido, str) ->
            begin
              let spano = match ido with
                  None -> None
                | Some id -> (Session.get_span sess id)
              in
                match spano with
                    None ->
                      Session.fail sess "Error: %s\n%!" str
                  | Some span ->
                      Session.fail sess "%s:E:Error: %s\n%!"
                        (Session.string_of_span span) str
            end
;;

(* Layout calculations. *)

let new_layout (off:int64) (sz:int64) (align:int64) : layout =
  { layout_offset = off;
    layout_size = sz;
    layout_align = align }
;;

let align_to (align:int64) (v:int64) : int64 =
  if align = 0L || align = 1L
  then v
  else
    let rem = Int64.rem v align in
      if rem = 0L
      then v
      else
        let padding = Int64.sub align rem in
          Int64.add v padding
;;

let pack (offset:int64) (layouts:layout array) : layout =
  let pack_one (off,align) curr =
    curr.layout_offset <- align_to curr.layout_align off;
    ((Int64.add curr.layout_offset curr.layout_size),
     (i64_max align curr.layout_align))
  in
  let (final,align) = Array.fold_left pack_one (offset,0L) layouts in
  let sz = Int64.sub final offset in
    new_layout offset sz align
;;

let rec layout_ty (abi:Abi.abi) (off:int64) (t:Ast.ty) : layout =
  match t with
      Ast.TY_nil -> new_layout off 0L 0L
        (* FIXME: bool should be 1L/1L, once we have sub-word-sized moves working. *)
    | Ast.TY_bool -> new_layout off 4L 4L
    | Ast.TY_mach m ->
        let sz = Int64.of_int (bytes_of_ty_mach m) in
          new_layout off sz sz
    | Ast.TY_char -> new_layout off 4L 4L
    | Ast.TY_tup slots ->
        let layouts = Array.map (layout_slot abi 0L) slots in
          pack off layouts
    | Ast.TY_rec slots ->
        let layouts = Array.map (fun (_,slot) -> layout_slot abi 0L slot) slots in
          pack off layouts
    | _ ->
        new_layout off abi.Abi.abi_word_sz abi.Abi.abi_word_sz

and layout_slot (abi:Abi.abi) (off:int64) (s:Ast.slot) : layout =
  match s.Ast.slot_ty with
      None -> raise (Semant_err (None, "layout_slot on untyped slot"))
    | Some t -> layout_ty abi off t
;;

let layout_rec (abi:Abi.abi) (atab:Ast.ty_rec) : ((Ast.ident * (Ast.slot * layout)) array) =
  let layouts = Array.map (fun (_,slot) -> layout_slot abi 0L slot) atab in
    begin
      ignore (pack 0L layouts);
      assert ((Array.length layouts) = (Array.length atab));
      Array.mapi (fun i layout ->
                    let (ident, slot) = atab.(i) in
                      (ident, (slot, layout))) layouts
    end
;;

let layout_tup (abi:Abi.abi) (tup:Ast.ty_tup) : (layout array) =
  let layouts = Array.map (layout_slot abi 0L) tup in
    ignore (pack 0L layouts);
    layouts
;;

let word_slot (abi:Abi.abi) : Ast.slot =
  { Ast.slot_mode = Ast.MODE_interior;
    Ast.slot_ty = Some (Ast.TY_mach abi.Abi.abi_word_ty) }
;;

let word_write_alias_slot (abi:Abi.abi) : Ast.slot =
  { Ast.slot_mode = Ast.MODE_write_alias;
    Ast.slot_ty = Some (Ast.TY_mach abi.Abi.abi_word_ty) }
;;

let layout_call_tup (abi:Abi.abi) (tfn:Ast.ty_fn) : (layout array) =
  let (tsig,taux) = tfn in
  let slots = tsig.Ast.sig_input_slots in
  let proc_ptr = word_slot abi in
  let out_ptr = word_slot abi in
  let slots' = Array.append [| out_ptr; proc_ptr |] slots in
    layout_tup abi slots'
;;


(*
 * Local Variables:
 * fill-column: 70;
 * indent-tabs-mode: nil
 * buffer-file-coding-system: utf-8-unix
 * compile-command: "make -C .. 2>&1 | sed -e 's/\\/x\\//x:\\//g'";
 * End:
 *)
