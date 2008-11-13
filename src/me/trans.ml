(* Translation *)

open Semant;;
open Common;;

(* +++ At some point abstract this out per-machine-arch. *)
let is_2addr_machine = true;;
let ptr_mem = Il.M32;;
let fp_abi_operand = Il.Reg (Il.HWreg X86.esp);;
let pp_abi_operand = Il.Reg (Il.HWreg X86.ebp);;
let cp_abi_operand = Il.Mem (Il.M32, Some (Il.HWreg X86.ebp), Asm.IMM 0L);;
let rp_abi_operand = Il.Mem (Il.M32, Some (Il.HWreg X86.ebp), Asm.IMM 4L);;
(* --- At some point abstract this out per-machine-arch. *)

let marker = Il.Imm (Asm.IMM 0xdeadbeefL);;
let imm_true = Il.Imm (Asm.IMM 1L);;
let imm_false = Il.Imm (Asm.IMM 0L);;
let mark e = e.Il.emit_pc;;
let patch e i = 
  e.Il.emit_quads.(i) <- { e.Il.emit_quads.(i)
                           with Il.quad_dst = Il.Label (mark e) }
;;  
let badlab = Il.Label (-1);;

let rec trans_lval_path emit lvp = 
  match lvp with 
      Ast.RES_pr FP -> fp_abi_operand
    | Ast.RES_pr PP -> pp_abi_operand
    | Ast.RES_pr CP -> cp_abi_operand
    | Ast.RES_pr RP -> rp_abi_operand
    | Ast.RES_idx (a, b) -> 
        let av = trans_lval_path emit a in
        let bv = trans_lval_path emit b in          
		let tmp = Il.Reg (Il.next_vreg emit) in 
		  Il.emit emit Il.ADD tmp av bv;
          tmp
    | Ast.RES_off (off, lv) -> 
        (match trans_lval_path emit lv with             
             Il.Mem (m, v, Asm.IMM off') -> 
               Il.Mem (m, v, Asm.IMM (Int64.add off off'))
           | v -> 
               let tmp = Il.Reg (Il.next_vreg emit) in
                 Il.emit emit Il.ADD tmp v (Il.Imm (Asm.IMM off));
                 tmp)
    | Ast.RES_deref lv -> 
        (match trans_lval_path emit lv with 
             Il.Reg r -> 
               Il.Mem (ptr_mem, Some r, Asm.IMM 0L)
           | v -> 
		       let tmp = (Il.next_vreg emit) in 
		         Il.emit emit Il.MOV (Il.Reg tmp) v Il.Nil;
                 Il.Mem (ptr_mem, Some tmp, Asm.IMM 0L))
;;

let trans_lval emit lv = 
  match lv.Ast.lval_src.node with 
      (* FIXME: only do this if the temp is subword-sized. *)
      Ast.LVAL_base (Ast.BASE_temp n) -> 
        begin
          let tab = emit.Il.emit_temp_to_vreg_map in 
          if Hashtbl.mem tab n
          then Il.Reg (Il.Vreg (Hashtbl.find tab n))
          else 
            let vr = (Il.next_vreg emit) in
              (match vr with 
                   Il.Vreg v -> Hashtbl.add tab n v
                 | _ -> ());              
              Il.Reg vr
        end
    | _ -> 
        begin
          match !(lv.Ast.lval_res) with 
              None -> raise (Semant_err (None, "unresolved lval in trans_lval"))
            | Some res -> trans_lval_path emit res.Ast.res_path
        end
;;

let trans_expr e expr = 
  let emit = Il.emit e in
	match expr with 
		Ast.EXPR_literal (Ast.LIT_nil) -> 
		  Il.Nil

	  | Ast.EXPR_literal (Ast.LIT_bool false) -> 
		  Il.Imm (Asm.IMM 0L)
            
	  | Ast.EXPR_literal (Ast.LIT_bool true) -> 
		  Il.Imm (Asm.IMM 1L)

	  | Ast.EXPR_literal (Ast.LIT_char c) -> 
		  Il.Imm (Asm.IMM (Int64.of_int (Char.code c)))

	  | Ast.EXPR_binary (binop, a, b) -> 
		  let lhs = trans_lval e a in
		  let rhs = trans_lval e b in
		  let dst = Il.Reg (Il.next_vreg e) in 
          let arith op = 
            if is_2addr_machine
            then 
			  (emit Il.MOV dst lhs Il.Nil;
               emit op dst dst rhs)
            else
			  emit op dst lhs rhs;
			dst
          in
          let rela cjmp = 
            if is_2addr_machine
            then 
              begin
                let t = Il.Reg (Il.next_vreg e) in
                  emit Il.MOV t lhs Il.Nil;
                  emit Il.CMP Il.Nil t rhs
              end
            else 
              emit Il.CMP Il.Nil lhs rhs;
            emit Il.MOV dst imm_true Il.Nil;
            let j = mark e in
              emit cjmp badlab Il.Nil Il.Nil;
              emit Il.MOV dst imm_false Il.Nil;
              patch e j;
              dst
          in
            begin 
		      match binop with
                  Ast.BINOP_or -> arith Il.OR
                | Ast.BINOP_and -> arith Il.AND
                    
                | Ast.BINOP_lsl -> arith Il.LSL
                | Ast.BINOP_lsr -> arith Il.LSR
                | Ast.BINOP_asr -> arith Il.ASR
                    
                | Ast.BINOP_add -> arith Il.ADD
                | Ast.BINOP_sub -> arith Il.SUB
                    
                (* FIXME: switch on type of operands. *)
                (* FIXME: wire to reg X86.eax, sigh.  *)
                (* 
                   | Ast.BINOP_mul -> Il.UMUL
                   | Ast.BINOP_div -> Il.UDIV
                   | Ast.BINOP_mod -> Il.UMOD
                *)
                    
                | Ast.BINOP_eq -> rela Il.JE                
                | Ast.BINOP_ne -> rela Il.JNE                
                | Ast.BINOP_lt -> rela Il.JL
                | Ast.BINOP_le -> rela Il.JLE
                | Ast.BINOP_ge -> rela Il.JGE
                | Ast.BINOP_gt -> rela Il.JG
                    
			    | _ -> raise (Invalid_argument "Semant.trans_expr: unimplemented binop")
            end

	  | Ast.EXPR_unary (unop, a) -> 
		  let src = trans_lval e a in
		  let dst = Il.Reg (Il.next_vreg e) in 
		  let op = match unop with
			  Ast.UNOP_not -> Il.NOT
			| Ast.UNOP_neg -> Il.NEG
		  in
            if is_2addr_machine
            then 
			  (emit Il.MOV dst src Il.Nil;
               emit op dst dst Il.Nil)
            else               
			  emit op dst src Il.Nil;
			dst
	  | _ -> marker (* raise (Invalid_argument "Semant.trans_expr: unimplemented translation") *)
;;


let rec trans_stmt e stmt =
  let emit = Il.emit e in
    match stmt.node with 
	    Ast.STMT_copy (lv_dst, e_src) -> 
		  let dst = trans_lval e lv_dst in
		  let src = trans_expr e e_src in
		    emit Il.MOV dst src Il.Nil
              
	  | Ast.STMT_block stmts -> 
		  Array.iter (trans_stmt e) stmts.Ast.block_stmts
          
      | Ast.STMT_while sw -> 
          let back_jmp_target = mark e in 
          let (head_stmts, head_lval) = sw.Ast.while_lval in
		    Array.iter (trans_stmt e) head_stmts;
            let v = trans_lval e head_lval in
              emit Il.CMP Il.Nil v imm_false;
              let fwd_jmp_quad = mark e in
                emit Il.JE badlab Il.Nil Il.Nil;
                trans_stmt e sw.Ast.while_body;
                emit Il.JMP (Il.Label back_jmp_target) Il.Nil Il.Nil;
                patch e fwd_jmp_quad
                  
      | Ast.STMT_if si -> 
          let v = trans_lval e si.Ast.if_test in 
            emit Il.CMP Il.Nil v imm_true;
            let skip_thn_clause_jmp = mark e in 
              emit Il.JE badlab Il.Nil Il.Nil;
              trans_stmt e si.Ast.if_then;
              begin 
                match si.Ast.if_else with 
                    None -> patch e skip_thn_clause_jmp
                  | Some els -> 
                      let skip_els_clause_jmp = mark e in
                        emit Il.JE badlab Il.Nil Il.Nil;
                        patch e skip_thn_clause_jmp;
                        trans_stmt e els;
                        patch e skip_els_clause_jmp                        
              end

      | _ -> ()
                
(* 

    | Ast.STMT_do_while sw ->
  | STMT_foreach of stmt_foreach
  | STMT_for of stmt_for
  | STMT_try of stmt_try
  | STMT_put of (proto option * lval option)
  | STMT_ret of (proto option * lval option)
  | STMT_be of (proto option * lval * (lval array))
  | STMT_alt_tag of stmt_alt_tag
  | STMT_alt_type of stmt_alt_type
  | STMT_alt_port of stmt_alt_port
  | STMT_prove of (constrs)
  | STMT_check of (constrs)
  | STMT_checkif of (constrs * stmt)
  | STMT_call of (lval * lval * (lval array))
  | STMT_send of (lval * lval)
  | STMT_recv of (lval * lval)
  | STMT_decl of stmt_decl 
  | STMT_use of (ty * ident * lval)
	| _ -> raise (Invalid_argument "Semant.trans_stmt: unimplemented translation")
*)

and trans_fn emit fn = 
  trans_stmt emit fn.Ast.fn_body

and trans_prog emit p = 
  trans_mod_items emit p.Ast.prog_mod

and trans_mod_item emit name item = 
  match item.node with 
	  Ast.MOD_ITEM_fn f -> trans_fn emit f.Ast.decl_item
	| Ast.MOD_ITEM_mod m -> trans_mod_items emit m.Ast.decl_item
	| Ast.MOD_ITEM_prog p -> trans_prog emit p.Ast.decl_item
	| _ -> ()
 

and trans_mod_items emit items = 
  Hashtbl.iter (trans_mod_item emit) items

and trans_crate crate = 
  let emit = Il.new_emitter X86.n_hardregs in
	trans_mod_items emit crate;
    emit

(* 
 * Local Variables:
 * fill-column: 70; 
 * indent-tabs-mode: nil
 * compile-command: "make -C .. 2>&1 | sed -e 's/\\/x\\//x:\\//g'"; 
 * End:
 *)
