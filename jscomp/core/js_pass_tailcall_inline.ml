(* Copyright (C) 2015-2016 Bloomberg Finance L.P.
 * 
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * In addition to the permissions granted to you by the LGPL, you may combine
 * or link a "work that uses the Library" with a publicly distributed version
 * of this file to produce a combined library or application, then distribute
 * that combined work under the terms of your choosing, with no requirement
 * to comply with the obligations normally placed on you by section 4 of the
 * LGPL version 3 (or the corresponding section of a later version of the LGPL
 * should you choose to use a later version).
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 * 
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA. *)






(* When we inline a function call, if we don't do a beta-reduction immediately, there is 
   a chance that it is ignored, (we can not assume that each pass is robust enough)

   After we do inlining, it makes sense to do another constant folding and propogation 
 *)

(* Check: shall we inline functions with while loop? if it is used only once, 
   it makes sense to inline it
*)

module S = Js_stmt_make
(* module E = Js_exp_make *)


let substitue_variables (map : Ident.t Map_ident.t) = 
    object (self)  
      inherit Js_map.map
      method! ident id =
         Map_ident.find_default map id id 
    end         

(* 1. recursive value ? let rec x = 1 :: x
    non-terminating
    2. duplicative identifiers ..
    remove it at the same time is a bit unsafe,
    since we have to guarantee that the one use
    case is substituted
    we already have this? in [defined_idents]
*)

let inline_call
  no_tailcall 
  params (args : J.expression list) processed_blocks =  
  if no_tailcall then   
    let map, block =   
      Ext_list.fold_right2 
        params args  (Map_ident.empty,  processed_blocks)
        (fun param arg (map,acc) ->  
           match arg.expression_desc with 
           | Var (Id id) ->  
             Map_ident.add map param id, acc 
           | _ -> 
             map, S.define_variable ~kind:Variable param arg :: acc) in 
    if Map_ident.is_empty map then block 
    else (substitue_variables map) # block block        
  else    
  (*
      At this time, when tailcall happened, the parameter can be assigned
      for example {[
        function (_x,y){
          _x = u
        }
      ]}
      if it is substitued, the assignment will align the value which is incorrect
  *)
    Ext_list.fold_right2 
      params args  processed_blocks
      (fun param arg acc ->  
         S.define_variable ~kind:Variable param arg :: acc) 

(** There is a side effect when traversing dead code, since 
    we assume that substitue a node would mark a node as dead node,

    so if we traverse a dead node, this would get a wrong result.
    it does happen in such scenario
    {[
      let generic_basename is_dir_sep current_dir_name name =
        let rec find_end n =
          if n < 0 then String.sub name 0 1
          else if is_dir_sep name n then find_end (n - 1)
          else find_beg n (n + 1)
        and find_beg n p =
          if n < 0 then String.sub name 0 p
          else if is_dir_sep name n then String.sub name (n + 1) (p - n - 1)
          else find_beg (n - 1) p
        in
        if name = ""
        then current_dir_name
        else find_end (String.length name - 1)
    ]}
    [find_beg] can potentially be expanded in [find_end] and in [find_end]'s expansion, 
    if the order is not correct, or even worse, only the wrong one [find_beg] in [find_end] get expanded 
    (when we forget to recursive apply), then some code non-dead [find_beg] will be marked as dead, 
    while it is still called 
*)
let subst (export_set : Set_ident.t) stats  = 
  object (self)
    inherit Js_map.map as super
    method! statement st = 
      match st.statement_desc with 
      | Variable 
          {value = _ ;
           ident_info = {used_stats = Dead_pure}
          } 

        ->
        S.block []
      | Variable { ident_info = {used_stats = Dead_non_pure} ;
                   value = Some v  ; _ }        
        -> S.exp v
      | _ -> super#statement st 
    method! variable_declaration 
        ({ident; value = _ ; property = _ ; ident_info = _}  as v)
      =  
      (* TODO: replacement is a bit shaky, the problem is the lambda we stored is
         not consistent after we did some subsititution, and the dead code removal
         does rely on this (otherwise, when you do beta-reduction you have to regenerate names)
      *)
      let v = super # variable_declaration v in
      Hash_ident.add stats ident v; (* see #278 before changes *)
      v
    method! block bs = 
      match bs with
      | ({statement_desc = 
            Variable ({value =
                         Some ({expression_desc = Fun _; _ } as v )
                      } as vd) ; comment = _} as st) :: rest  -> 
        let is_export = Set_ident.mem export_set vd.ident in
        if is_export then 
          self#statement st :: self#block rest 
        else 
          begin 
            match Hash_ident.find_opt stats vd.ident with 
            (* TODO: could be improved as [mem] *)
            | None -> 
              if Js_analyzer.no_side_effect_expression v 
              then S.exp v  :: self#block rest 
              else self#block rest 

            | Some _ -> self#statement st  :: self#block rest 
          end

      | [{statement_desc = 
           Return {return_value = 
                     {expression_desc = 
                        Call({expression_desc = Var (Id id)},args,_info)}} } as st ]
        -> 
        begin match Hash_ident.find_opt stats id with 

          | Some ({ value = 
                      Some {expression_desc = Fun (false, params, block, env) ; comment = _}; 
                    (*TODO: don't inline method tail call yet, 
                      [this] semantics are weird 
                    *)              
                    property = (Alias | StrictOpt | Strict);
                    ident_info = {used_stats = Once_pure };
                    ident = _
                  } as v)
            when Ext_list.same_length params args 
            -> 
            Js_op_util.update_used_stats v.ident_info Dead_pure;
            let no_tailcall = Js_fun_env.no_tailcall env in 
            let processed_blocks = ( self#block block) (* see #278 before changes*) in 
            inline_call no_tailcall params args processed_blocks
            (* Ext_list.fold_right2 
              params args  processed_blocks
              (fun param arg acc ->  
                 S.define_variable ~kind:Variable param arg :: acc)                                                 *)
            (* Mark a function as dead means it will never be scanned, 
               here we inline the function
            *)

          | (None | Some _) ->
            [self#statement st ]
        end
      | x :: xs 
        ->
        self#statement x :: self#block xs
      | [] 
        -> 
        []

  end


let tailcall_inline (program : J.program) = 
  let stats = Js_pass_get_used.get_stats program in
  let export_set = program.export_set in
  (subst export_set stats )#program program

    
