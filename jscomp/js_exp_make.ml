(* BuckleScript compiler
 * Copyright (C) 2015-2016 Bloomberg Finance L.P.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exception;
 * either version 2.1 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
*)

(* Author: Hongbo Zhang  *)

let no_side_effect = Js_analyzer.no_side_effect_expression

type binary_op =   ?comment:string -> J.expression -> J.expression -> J.expression 
type unary_op =  ?comment:string -> J.expression -> J.expression
(*
  remove pure part of the expression
  and keep the non-pure part while preserve the semantics 
  (modulo return value)
 *)
let rec extract_non_pure (x : J.expression)  = 
  match x.expression_desc with 
  | Var _
  | Str _
  | Number _ -> None (* Can be refined later *)
  | Access (a,b) -> 
    begin match extract_non_pure a , extract_non_pure b with 
      | None, None -> None
      | _, _ -> Some x 
    end
  | Array (xs,_mutable_flag)  ->
    if List.for_all (fun x -> extract_non_pure x = None)  xs then
      None 
    else Some x 
  | Seq (a,b) -> 
    begin match extract_non_pure a , extract_non_pure b with 
      | None, None  ->  None
      | Some u, Some v ->  
        Some { x with expression_desc =  Seq(u,v)}
      (* may still have some simplification*)
      | None, (Some _ as v) ->  v
      | (Some _ as u), None -> u 
    end
  | _ -> Some x 

(* TODO Should this comment be removed *)
(* let  non_pure_output_of_exp ( x : J.expresion) : Js_output.t  =  *)
(*   let rec aux x =  *)
(*   match x with  *)
(*   | Var _ *)
(*   | Str _ *)
(*   | Number _ -> `Empty *)
(*   | Access (a,b) ->  *)
(*       begin match aux a , aux b with  *)
(*       | `Empty, `Empty -> `Empty *)
(*       | _, _ -> `Exp x  *)
(*       end *)
(*   | Array xs  -> *)
(*       if List.for_all (fun x -> aux x = `Empty)  xs then *)
(*         `Empty *)
(*       else `Exp x  *)
(*   | Seq (a,b) ->  *)
(*       begin match aux a , aux b with  *)
(*       | `Empty, `Empty  ->  `Empty *)
(*       | `Exp u, `Exp v ->   *)
(*           `Block ([S.exp u],  v) *)
(*       | None, ((`Exp _) as v) ->  v *)
(*       | (`Exp _ as u), None -> u  *)
(*       | `Block (b1, e1), `Block (b2, e2) ->  *)
(*           `Block (b1 @ (S.exp e1 :: b2 ) , e2) *)
(*       end *)
(*   | _ -> `Exp  x  in *)
(*   match aux x with *)
(*   | `Empty ->  Js_output.dummy *)



(* type nonrec t = t  a [bug in pretty printer] *)
type t = J.expression 

let mk ?comment exp : t = 
  {expression_desc = exp ; comment  }

let var ?comment  id  : t = 
  {expression_desc = Var (Id id); comment }

let runtime_var_dot ?comment (x : string)  (e1 : string) : J.expression = 
  {expression_desc = 
     Var (Qualified(Ext_ident.create_js x,Runtime, Some e1)); comment }

let runtime_var_vid  x  e1 : J.vident = 
  Qualified(Ext_ident.create_js x,Runtime, Some e1)

let ml_var_dot ?comment ( id  : Ident.t) e : J.expression =     
  {expression_desc = Var (Qualified(id, Ml, Some e)); comment }

let external_var_dot ?comment (id : Ident.t) name fn : t = 
  {expression_desc = Var (Qualified(id, External name, Some fn)); comment }

let ml_var ?comment (id : Ident.t) : t  = 
  {expression_desc = Var (Qualified (id, Ml, None)); comment}

let str ?(pure=true) ?comment s : t =  {expression_desc = Str (pure,s); comment}
let raw_js_code ?comment s : t = {expression_desc = Raw_js_code s ; comment }

let anything_to_string ?comment (e : t) : t =  
  match e.expression_desc with 
  | Str _ -> e 
  | _ -> {expression_desc = Anything_to_string e ; comment}

(* we can do constant folding here, but need to make sure the result is consistent
   {[
     let f x = string_of_int x        
     ;; f 3            
   ]}     
   {[
     string_of_int 3
   ]}
*)
let int_to_string ?comment (e : t) : t = 
  anything_to_string ?comment e 
(* Shared mutable state is evil 
    [Js_fun_env.empty] is a mutable state ..
*)    
let fun_ ?comment  ?immutable_mask
    params block  : t = 
  let len = List.length params in
  {
    expression_desc = Fun ( params,block, Js_fun_env.empty ?immutable_mask len ); 
    comment
  }

let dummy_obj ?comment ()  : t = 
  {comment  ; expression_desc = Object []}

let is_instance_array ?comment e : t = 
  {comment; expression_desc = Bin(InstanceOf, e , str "Array") }

(* TODO: complete 
    pure ...
*)        
let rec seq ?comment (e0 : t) (e1 : t) : t = 
  match e0.expression_desc, e1.expression_desc with 
  | (Seq( a, {expression_desc = Number _ ;  })
    | Seq( {expression_desc = Number _ ;  },a)), _
    -> 
    seq ?comment a e1
  | _, ( Seq( {expression_desc = Number _ ;  }, a)) -> 
    (* Return value could not be changed*)
    seq ?comment e0 a
  | _, ( Seq(a,( {expression_desc = Number _ ;  } as v ) ))-> 
    (* Return value could not be changed*)
    seq ?comment (seq  e0 a) v

  | _ -> 
    {expression_desc = Seq(e0,e1); comment}


let int ?comment ?c  i : t = 
  {expression_desc = Number (Int {i; c}) ; comment}

let access ?comment (e0 : t)  (e1 : t) : t = 
  match e0.expression_desc, e1.expression_desc with
  | Array (l,_mutable_flag) , Number (Int {i; _}) when no_side_effect e0-> 
    List.nth l  i  (* Float i -- should not appear here *)
  | _ ->
    { expression_desc = Access (e0,e1); comment} 

let string_access ?comment (e0 : t)  (e1 : t) : t = 
  match e0.expression_desc, e1.expression_desc with
  | Str (_,s) , Number (Int {i; _}) when i >= 0 && i < String.length s -> 
    (* TODO: check exception when i is out of range..
       RangeError?
    *)
    str (String.make 1 s.[i])
  | _ ->
    { expression_desc = String_access (e0,e1); comment} 

let index ?comment (e0 : t)  (e1 : int) : t = 
  match e0.expression_desc with
  | Array (l,_mutable_flag)  when no_side_effect e0 -> 
    List.nth l  e1  (* Float i -- should not appear here *)
  | Caml_block (l,_mutable_flag, _, _)  when no_side_effect e0 -> 
    List.nth l  e1  (* Float i -- should not appear here *)

  | _ -> { expression_desc = Access (e0, int e1); comment} 

let call ?comment ?info e0 args : t = 
  let info = match info with 
    | None -> Js_call_info.dummy
    | Some x -> x in
  {expression_desc = Call(e0,args,info); comment }

let flat_call ?comment e0 es : t = 
  (* TODO: optimization when es is known at compile time
      to be an array
  *)
  {expression_desc = FlatCall (e0,es); comment }

(* Dot .....................**)        
let runtime_call ?comment module_name fn_name args = 
  call ?comment ~info:{arity=Full} (runtime_var_dot  module_name fn_name) args

let runtime_ref module_name fn_name = 
  runtime_var_dot  module_name fn_name


(* only used in property access, 
    Invariant: it should not call an external module .. *)
let js_var ?comment  (v : string) =
  var ?comment (Ext_ident.create_js v )

let js_global ?comment  (v : string) =
  var ?comment (Ext_ident.create_js v )

(** used in normal property
    like [e.length], no dependency introduced
*)
let dot ?comment (e0 : t)  (e1 : string) : t = 
  { expression_desc = Dot (e0,  e1, true); comment} 

let undefined  = js_global "undefined"


(** coupled with the runtime *)
let is_caml_block ?comment (e : t) : t = 
  {expression_desc = Bin ( NotEqEq, dot e "length" , undefined); 
   comment}

(* This is a property access not external module *)

let array_length ?comment (e : t) : t = 
  match e.expression_desc with 
  (* TODO: use array instead? *)
  | (Array (l, _) | Caml_block(l,_,_,_)) when no_side_effect e -> int ?comment (List.length l)
  | _ -> { expression_desc = Length (e, Array) ; comment }

let string_length ?comment (e : t) : t =
  match e.expression_desc with 
  | Str(_,v) -> int ?comment (String.length v)
  | _ -> { expression_desc = Length (e, String) ; comment }

let bytes_length ?comment (e : t) : t = 
  match e.expression_desc with 
  (* TODO: use array instead? *)
  | Array (l, _) -> int ?comment (List.length l)
  | Str(_,v) -> int ?comment (String.length v)
  | _ -> { expression_desc = Length (e, Bytes) ; comment }

let function_length ?comment (e : t) : t = 
  match e.expression_desc with 
  | Fun(params, _, _) -> int ?comment (List.length params)
  (* TODO: optimize if [e] is know at compile time *)
  | _ -> { expression_desc = Length (e, Function) ; comment }

(** no dependency introduced *)
let js_global_dot ?comment (x : string)  (e1 : string) : t = 
  { expression_desc = Dot (js_var x,  e1, true); comment} 

let char_of_int ?comment (v : t) : t = 
  match v.expression_desc with
  | Number (Int {i; _}) ->
    str  (String.make 1(Char.chr i))
  | Char_to_int v -> v 
  | _ ->  {comment ; expression_desc = Char_of_int v}

let char_to_int ?comment (v : t) : t = 
  match v.expression_desc with 
  | Str (_, x) ->
    assert (String.length x = 1) ;
    int ~comment:(Printf.sprintf "%S"  x )  
      (Char.code x.[0])
  | Char_of_int v -> v 
  | _ -> {comment; expression_desc = Char_to_int v }

let array_append ?comment e el : t = 
  { comment ; expression_desc = Array_append (e, el)}

let array_copy ?comment e : t = 
  { comment ; expression_desc = Array_copy e}

(* Note that this return [undefined] in JS, 
    it should be wrapped to avoid leak [undefined] into 
    OCaml
*)    
let dump ?comment level el : t = 
  {comment ; expression_desc = Dump(level,el)}

let to_json_string ?comment e : t = 
  { comment; expression_desc = Json_stringify e }

let rec string_append ?comment (e : t) (el : t) : t = 
  match e.expression_desc , el.expression_desc  with 
  | Str(_,a), String_append ({expression_desc = Str(_,b)}, c) ->
    string_append ?comment (str (a ^ b)) c 
  | String_append (c,{expression_desc = Str(_,b)}), Str(_,a) ->
    string_append ?comment c (str (b ^ a))
  | String_append (a,{expression_desc = Str(_,b)}),
    String_append ({expression_desc = Str(_,c)} ,d) ->
    string_append ?comment (string_append a (str (b ^ c))) d 
  | Str (_,a), Str (_,b) -> str ?comment (a ^ b)
  | _, Anything_to_string b -> string_append ?comment e b 
  | Anything_to_string b, _ -> string_append ?comment b el
  | _, _ -> {comment ; expression_desc = String_append(e,el)}






let float_mod ?comment e1 e2 : J.expression = 
  { comment ; 
    expression_desc = Bin (Mod, e1,e2)
  }

let obj ?comment properties : t = 
  {expression_desc = Object properties; comment }

let tag_ml_obj ?comment e : t =  
  e (* tag is enough  *)
(* {comment; expression_desc = Tag_ml_obj e  } *)

(* currently only in method call, no dependency introduced
*)
let var_dot ?comment (x : Ident.t)  (e1 : string) : t = 
  {expression_desc = Dot (var x,  e1, true); comment} 

let bind_call ?comment obj  (e1 : string) args  : t = 
  call {expression_desc = 
     Bind ({expression_desc = Dot (obj,  e1, true); comment} , obj);
   comment = None } args 

let bind_var_call ?comment (x : Ident.t)  (e1 : string) args  : t = 
  let obj =  var x in 
  call {expression_desc = 
     Bind ({expression_desc = Dot (obj,  e1, true); comment} , obj);
   comment = None } args 


(* Dot .....................**)        

let float ?comment f : t = 
  {expression_desc = Number (Float {f}); comment}

let zero_float_lit : t = 
  {expression_desc = Number (Float {f = "0." }); comment = None}

(* let eqeq ?comment e0 e1 : t = {expression_desc = Bin(EqEq, e0,e1); comment} *)

let assign ?comment e0 e1 : t = {expression_desc = Bin(Eq, e0,e1); comment}


(** Convert a javascript boolean to ocaml boolean
    It's necessary for return value
     this should be optmized away for [if] ,[cond] to produce 
    more readable code
*)         
let to_ocaml_boolean ?comment (e : t) : t = 
  match e.expression_desc with 
  | Int_of_boolean _
  | Number _ -> e 
  | _ -> {comment ; expression_desc = Int_of_boolean e}

let true_  = int ~comment:"true" 1 (* var (Jident.create_js "true") *)

let false_  = int ~comment:"false" 0

let bool v = if  v then true_ else false_

let rec triple_equal ?comment (e0 : t) (e1 : t ) : t = 
  match e0.expression_desc, e1.expression_desc with
  | Str (_,x), Str (_,y) ->  (* CF*)
    bool (Ext_string.equal x y)
  | Char_to_int a , Char_to_int b -> 
    triple_equal ?comment a b 
  | Char_to_int a , Number (Int {i; c = Some v}) 
  | Number (Int {i; c = Some v}), Char_to_int a  -> 
    triple_equal ?comment a (str (String.make 1 v))
  | Number (Int {i = i0; _}), Number (Int {i = i1; _}) 
    -> 
    bool (i0 = i1)      
  | Char_of_int a , Char_of_int b -> 
    triple_equal ?comment a b 
  | _ -> 
    to_ocaml_boolean  {expression_desc = Bin(EqEqEq, e0,e1); comment}
let bin ?comment (op : J.binop) e0 e1 : t = 
  match op with 
  | EqEqEq -> triple_equal ?comment e0 e1
  | _ -> {expression_desc = Bin(op,e0,e1); comment}

(* TODO: Constant folding, Google Closure will do that?,
   Even if Google Clsoure can do that, we will see how it interact with other
   optimizations
   We wrap all boolean functions here, since OCaml boolean is a 
   bit different from Javascript, so that we can change it in the future
*)
let rec and_ ?comment (e1 : t) (e2 : t) = 
  match e1.expression_desc, e2.expression_desc with 
  | (Bin (NotEqEq, e1, 
          {expression_desc = Var (Id ({name = "undefined"; _} as id))})
    | Bin (NotEqEq, 
           {expression_desc = Var (Id ({name = "undefined"; _} as id))}, 
           e1)
    ), 
    _ when Ext_ident.is_js id -> 
    and_ e1 e2
  |  Int_of_boolean e1 , Int_of_boolean e2 -> 
    and_ ?comment e1 e2
  |  Int_of_boolean e1 , _ -> and_ ?comment e1 e2
  | _,  Int_of_boolean e2
    -> and_ ?comment e1 e2
  (* optimization if [e1 = e2], then and_ e1 e2 -> e2
     be careful for side effect        
  *)
  | Var i, Var j when Js_op_util.same_vident  i j 
    -> 
    to_ocaml_boolean e1
  | Var i, 
    (Bin (And,   {expression_desc = Var j ; _}, _) 
    | Bin (And ,  _, {expression_desc = Var j ; _}))
    when Js_op_util.same_vident  i j 
    ->
    to_ocaml_boolean e2          
  | _, _ ->     
    to_ocaml_boolean @@ bin ?comment And e1 e2 

let rec or_ ?comment (e1 : t) (e2 : t) = 
  match e1.expression_desc, e2.expression_desc with 
  | Int_of_boolean e1 , Int_of_boolean e2
    -> 
    or_ ?comment e1 e2
  | Int_of_boolean e1 , _  -> or_ ?comment e1 e2
  | _,  Int_of_boolean e2
    -> or_ ?comment e1 e2
  | Var i, Var j when Js_op_util.same_vident  i j 
    -> 
    to_ocaml_boolean e1
  | Var i, 
    (Bin (Or,   {expression_desc = Var j ; _}, _) 
    | Bin (Or ,  _, {expression_desc = Var j ; _}))
    when Js_op_util.same_vident  i j 
    -> to_ocaml_boolean e2          
  | _, _ ->     
    to_ocaml_boolean @@ bin ?comment Or e1 e2 

(* return a value of type boolean *)
(* TODO: 
     when comparison with Int
     it is right that !(x > 3 ) -> x <= 3 *)
let rec not ({expression_desc; comment} as e : t) : t =
  match expression_desc with 
  | Bin(EqEqEq , e0,e1)
    -> {expression_desc = Bin(NotEqEq, e0,e1); comment}
  | Bin(NotEqEq , e0,e1) -> {expression_desc = Bin(EqEqEq, e0,e1); comment}

  (* Note here the compiled js use primtive comparison only 
     for *primitive types*, so it is safe to do such optimization,
     for generic comparison, this does not hold        
  *)
  | Bin(Lt, a, b) -> {e with expression_desc = Bin (Ge,a,b)}
  | Bin(Ge,a,b) -> {e with expression_desc = Bin (Lt,a,b)}          
  | Bin(Le,a,b) -> {e with expression_desc = Bin (Gt,a,b)}
  | Bin(Gt,a,b) -> {e with expression_desc = Bin (Le,a,b)}

  | Number (Int {i; _}) -> 
    if i != 0 then false_ else true_
  | Int_of_boolean  e -> not e
  | Not e -> e 
  | x -> {expression_desc = Not e ; comment = None}

let rec econd ?comment (b : t) (t : t) (f : t) : t = 
  match b.expression_desc , t.expression_desc, f.expression_desc with

  | Number ((Int { i = 0; _}) ), _, _ 
    -> f  (* TODO: constant folding: could be refined *)
  | (Number _ | Array _ | Caml_block _), _, _ when no_side_effect b &&  no_side_effect f 
    -> t  (* a block can not be false in OCAML, CF - relies on flow inference*)
  | (Bin (Bor, v , {expression_desc = Number (Int {i = 0 ; _})})), _, _
    -> econd v t f 
  | Bin (NotEqEq, e1, 
         {expression_desc = Var (Id ({name = "undefined"; _} as id))}),
    _, _
    when Ext_ident.is_js id -> 
    econd e1 t f 

  | ((Bin ((EqEqEq, {expression_desc = Number (Int { i = 0; _}); _},x)) 
     | Bin (EqEqEq, x,{expression_desc = Number (Int { i = 0; _});_}))), _, _ 
    -> 
    econd ?comment x f t 

  | (Bin (Ge, 
          ({expression_desc = Length _ ;
            _}), {expression_desc = Number (Int { i = 0 ; _})})), _, _ 
    -> f

  | (Bin (Gt, 
          ({expression_desc = Length _;
            _} as pred ), {expression_desc = Number (Int {i = 0; })})), _, _
    ->
    (** Add comment when simplified *)
    econd ?comment pred t f 

  | _, (Cond (p1, branch_code0, branch_code1)), _
    when Js_analyzer.eq_expression branch_code1 f
    ->
    (* {[
         if b then (if p1 then branch_code0 else branch_code1)
         else branch_code1         
       ]}
       is equivalent to         
       {[
         if b && p1 then branch_code0 else branch_code1           
       ]}         
    *)      
    econd (and_ b p1) branch_code0 f
  | _, (Cond (p1, branch_code0, branch_code1)), _
    when Js_analyzer.eq_expression branch_code0 f
    ->
    (* the same as above except we revert the [cond] expression *)      
    econd (and_ b (not p1)) branch_code1 f

  | _, _, (Cond (p1', branch_code0, branch_code1))
    when Js_analyzer.eq_expression t branch_code0 
    (*
       {[
         if b then branch_code0 else (if p1' then branch_code0 else branch_code1)           
       ]}         
       is equivalent to         
       {[
         if b or p1' then branch_code0 else branch_code1           
       ]}         
    *)
    ->
    econd (or_ b p1') t branch_code1
  | _, _, (Cond (p1', branch_code0, branch_code1))
    when Js_analyzer.eq_expression t branch_code1
    ->
    (* the same as above except we revert the [cond] expression *)      
    econd (or_ b (not p1')) t branch_code0

  | Not e, _, _ -> econd ?comment e f t 
  | Int_of_boolean  b, _, _  -> econd ?comment  b t f

  | _ -> 
    if Js_analyzer.eq_expression t f then
      if no_side_effect b then t else seq  ?comment b t
    else
      {expression_desc = Cond(b,t,f); comment}


let rec float_equal ?comment (e0 : t) (e1 : t) : t = 
  match e0.expression_desc, e1.expression_desc with     
  | Number (Int {i = i0 ; _}), Number (Int {i = i1; }) -> 
    bool (i0 = i1)
  | (Bin(Bor, 
         {expression_desc = Number(Int {i = 0; _})}, 
         ({expression_desc = Caml_block_tag _; _} as a ))
    |
      Bin(Bor, 
          ({expression_desc = Caml_block_tag _; _} as a),
          {expression_desc = Number (Int {i = 0; _})})), 
    Number (Int {i = 0; _})
    ->  (** (x.tag | 0) === 0  *)
    not  a     
  | (Bin(Bor, 
         {expression_desc = Number(Int {i = 0; _})}, 
         ({expression_desc = Caml_block_tag _; _} as a ))
    |
      Bin(Bor, 
          ({expression_desc = Caml_block_tag _; _} as a),
          {expression_desc = Number (Int {i = 0; _})}))
  , Number _  ->  (* for sure [i != 0 ]*)
    (* since a is integer, if we guarantee there is no overflow 
       of a
       then [a | 0] is a nop unless a is undefined
       (which is applicable when applied to tag),
       obviously tag can not be overflowed. 
       if a is undefined, then [ a|0===0 ] is true 
       while [a === 0 ] is not true
       [a|0 === non_zero] is false and [a===non_zero] is false
       so we can not eliminate when the tag is zero          
    *)
    float_equal ?comment a e1
  | Number (Float {f = f0; _}), Number (Float {f = f1 ; }) when f0 = f1 -> 
    true_

  | Char_to_int a , Char_to_int b ->
    float_equal ?comment a b
  | Char_to_int a , Number (Int {i; c = Some v})
  | Number (Int {i; c = Some v}), Char_to_int a  ->
    float_equal ?comment a (str (String.make 1 v))
  | Char_of_int a , Char_of_int b ->
    float_equal ?comment a b

  | _ ->  
    to_ocaml_boolean {expression_desc = Bin(EqEqEq, e0,e1); comment}
let int_equal = float_equal 
let rec string_equal ?comment (e0 : t) (e1 : t) : t = 
  match e0.expression_desc, e1.expression_desc with     
  | Str (_, a0), Str(_, b0) 
    -> bool  (Ext_string.equal a0 b0)
  | _ , _ 
    ->
    to_ocaml_boolean {expression_desc = Bin(EqEqEq, e0,e1); comment}     


let arr ?comment mt es : t  = 
  {expression_desc = Array (es,mt) ; comment}
let make_block ?comment tag tag_info es mutable_flag : t = 
  {
    expression_desc = Caml_block( es, mutable_flag, tag,tag_info) ;
    comment = (match comment with 
        | None -> Lam_compile_util.comment_of_tag_info tag_info 
        | _ -> comment)
  }    

let uninitialized_object ?comment tag size : t = 
  { expression_desc = Caml_uninitialized_obj(tag,size); comment }

let uninitialized_array ?comment (e : t) : t  = 
  match e.expression_desc with 
  | Number (Int {i = 0 ; _}) -> arr ?comment NA []
  | _ -> {comment; expression_desc = Array_of_size e}



(* Invariant: this is relevant to how we encode string
*)           
let typeof ?comment (e : t) : t = 
  match e.expression_desc with 
  | Number _ 
  | Length _ 
    -> str ?comment "number"
  | Str _ 
    -> str ?comment "string" 

  | Array _
    -> str ?comment "object"
  | _ -> {expression_desc = Typeof e ; comment }

let is_type_number ?comment (e : t) : t = 
  string_equal ?comment (typeof e) (str "number")    



let new_ ?comment e0 args : t = 
  { expression_desc = New (e0,  Some args ); comment}

(** cannot use [boolean] in js   *)
let unknown_lambda ?(comment="unknown")  (lam : Lambda.lambda ) : t = 
  str ~pure:false ~comment (Lam_util.string_of_lambda lam)


let unit  () = int ~comment:"()" 0;; (* TODO: add a comment *)



let math ?comment v args  : t = 
  {comment ; expression_desc = Math(v,args)}

(* handle comment *)

let inc ?comment (e : t ) =
  match e with
  | {expression_desc = Number (Int ({i; _} as v));_ } -> 
    {e with expression_desc = Number (Int {v with i  = i + 1} )} (*comment ?*)
  | _ -> bin ?comment Plus e (int 1 )



let string_of_small_int_array ?comment xs : t = 
  {expression_desc = String_of_small_int_array xs; comment}



let dec ?comment (e : t ) =
  match e with
  | {expression_desc = Number (Int ({i; _} as v));_ } -> 
    {e with expression_desc = Number (Int ({ v with i = i - 1 }))} (*comment ?*)
  | _ -> bin ?comment Minus e (int 1 )



(* we are calling [Caml_primitive.primitive_name], since it's under our
   control, we should make it follow the javascript name convention, and
   call plain [dot]
*)          

let null ?comment () =     
  js_global ?comment "null"

let tag ?comment e : t = 
  {expression_desc = 
     Bin (Bor, {expression_desc = Caml_block_tag e; comment }, int 0 );
   comment = None }    

let bind ?comment fn obj  : t = 
  {expression_desc = Bind (fn, obj) ; comment }

let public_method_call meth_name obj label cache args = 
  let len = List.length args in 
  (** FIXME: not caml object *)


  econd (int_equal (tag obj ) (int 248))
    (
      if len <= 7 then          
        runtime_call Js_config.curry 
          ("js" ^ string_of_int (len + 1) )
          (label:: ( int cache) :: obj::args)
      else 
        runtime_call Js_config.curry "js"
          [label; 
           int cache;
           obj ;  
           arr NA (obj::args)
          ]
    )
    (* TODO: handle arbitrary length of args .. 
       we can reduce part of the overhead by using
       `__js` -- a easy ppx {{ x ##.hh }} 
       the downside is that no way to swap ocaml/js implementation 
       for object part, also need encode arity..
       how about x#|getElementById|2|
    *)
    (
      let fn = bind (dot obj meth_name) obj in
      if len = 0 then 
        dot obj meth_name
        (* Note that when no args supplied, 
           it is not necessarily a function, [bind]
           is dangerous
           so if user write such code
           {[
             let  u = x # say in
             u 3              
           ]}    
           It's reasonable to drop [this] support       
        *)
      else if len <=8 then 
        let len_str = string_of_int len in
        runtime_call Js_config.curry ("app"^len_str) 
          (fn ::  args)
      else 
        runtime_call Js_config.curry "app"           
          [fn  ; arr NA args ]            
    )

let set_tag ?comment e tag : t = 
  seq {expression_desc = Caml_block_set_tag (e,tag); comment } (unit ())

let set_length ?comment e tag : t = 
  seq {expression_desc = Caml_block_set_length (e,tag); comment } (unit ())
let obj_length ?comment e : t = 
  {expression_desc = Length (e, Caml_block); comment }
(* Arithmatic operations
   TODO: distinguish between int and float
   TODO: Note that we have to use Int64 to avoid integer overflow, this is fine
   since Js only have .

   like code below 
   {[
     MAX_INT_VALUE - (MAX_INT_VALUE - 100) + 20
   ]}

   {[
     MAX_INT_VALUE - x + 30
   ]}

   check: Re-association: avoid integer overflow
*) 
let rec to_int32  ?comment (e : J.expression)  : J.expression = 
  let expression_desc =  e.expression_desc in
  match expression_desc  with 
  | Bin(Bor, a, {expression_desc = Number (Int {i = 0});  _})
    -> 
    to_int32 ?comment a
  | _ ->
    { comment ;
      expression_desc = Bin (Bor, {comment = None; expression_desc }, int 0)
    }

let rec to_uint32 ?comment (e : J.expression)  : J.expression = 
  { comment ; 
    expression_desc = Bin (Lsr, e , int 0)
  }

let string_comp cmp ?comment  e0 e1 = 
  to_ocaml_boolean @@ bin ?comment cmp e0 e1


let rec int_comp (cmp : Lambda.comparison) ?comment  (e0 : t) (e1 : t) = 
  match cmp, e0.expression_desc, e1.expression_desc with
  | _, Call ({
      expression_desc = 
        Var (Qualified 
               (_, Runtime, 
                Some ("caml_int_compare" | "caml_int32_compare"))); _}, 
      [l;r], _), 
    Number (Int {i = 0})
    -> int_comp cmp l r (* = 0 > 0 < 0 *)
  | Ceq, _, _ -> int_equal e0 e1 
  | _ ->          
    to_ocaml_boolean @@ bin ?comment (Lam_compile_util.jsop_of_comp cmp) e0 e1

let float_comp cmp ?comment  e0 e1 = 
  to_ocaml_boolean @@ bin ?comment (Lam_compile_util.jsop_of_comp cmp) e0 e1

(* TODO: 
   we can apply a more general optimization here, 
   do some algebraic rewerite rules to rewrite [triple_equal]           
*)        
let is_out ?comment (e : t) (range : t) : t  = 
  begin match range.expression_desc, e.expression_desc with 

    | Number (Int {i = 1}), Var _ 
      ->         
      not (or_ (triple_equal e (int 0)) (triple_equal e (int 1)))                  
    | Number (Int {i = 1}), 
      (
        Bin (Plus , {expression_desc = Number (Int {i ; _}) }, {expression_desc = Var _; _})
      | Bin (Plus, {expression_desc = Var _; _}, {expression_desc = Number (Int {i ; _}) })
      ) 
      ->
      not (or_ (triple_equal e (int ( -i ))) (triple_equal e (int (1 - i))))        
    | Number (Int {i = 1}), 
      Bin (Minus ,  ({expression_desc = Var _; _} as x), {expression_desc = Number (Int {i ; _}) })        
      ->           
      not (or_ (triple_equal x (int ( i + 1 ))) (triple_equal x (int i)))        
    (* (x - i >>> 0 ) > k *)          
    | Number (Int {i = k}), 
      Bin (Minus ,  ({expression_desc = Var _; _} as x), 
           {expression_desc = Number (Int {i ; _}) })        
      ->           
      (or_ (int_comp Cgt x (int (i + k)))  (int_comp Clt x  (int i)))
    | Number (Int {i = k}), Var _  
      -> 
      (* Note that js support [ 1 < x < 3], 
         we can optimize it into [ not ( 0<= x <=  k)]           
      *)        
      or_ (int_comp Cgt e (int ( k)))  (int_comp Clt e  (int 0))

    | _, _ ->
      int_comp ?comment Cgt (to_uint32 e)  range 
  end

let rec float_add ?comment (e1 : t) (e2 : t) = 
  match e1.expression_desc, e2.expression_desc with 
  | Number (Int {i;_}), Number (Int {i = j;_}) -> 
    int ?comment (i + j)
  | _, Number (Int {i = j; c}) when j < 0 -> 
    float_minus ?comment e1 {e2 with expression_desc = Number (Int {i = -j; c})}       

  | Bin(Plus, a1 , ({expression_desc = Number (Int {i = k; _})}  )), 
    Number (Int { i =j; _}) -> 
    bin ?comment Plus a1 (int (k + j))

  (* TODO remove commented code  ?? *)
  (* | Bin(Plus, a0 , ({expression_desc = Number (Int a1)}  )), *)
  (*     Bin(Plus, b0 , ({expression_desc = Number (Int b1)}  )) *)
  (*   ->  *)
  (*   bin ?comment Plus a1 (int (a1 + b1)) *)

  (* | _, Bin(Plus,  b0, ({expression_desc = Number _}  as v)) *)
  (*   -> *)
  (*     bin ?comment Plus (bin ?comment Plus e1 b0) v *)
  (* | Bin(Plus, a1 , ({expression_desc = Number _}  as v)), _ *)
  (* | Bin(Plus, ({expression_desc = Number _}  as v),a1), _ *)
  (*   ->  *)
  (*     bin ?comment Plus (bin ?comment Plus a1 e2 ) v  *)
  (* | Number _, _ *)
  (*   ->  *)
  (*     bin ?comment Plus  e2 e1 *)
  | _ -> 
    bin ?comment Plus e1 e2
(* associative is error prone due to overflow *)
and float_minus ?comment  (e1 : t) (e2 : t) : t = 
  match e1.expression_desc, e2.expression_desc with 
  | Number (Int {i;_}), Number (Int {i = j;_}) -> 
    int ?comment (i - j)
  | _ -> 
    bin ?comment Minus e1 e2




let int32_add ?comment e1 e2 = 
  (* to_int32 @@  *)float_add ?comment e1 e2


let int32_minus ?comment e1 e2 : J.expression = 
  (* to_int32 @@ *)  float_minus ?comment e1 e2

let prefix_inc ?comment (i : J.vident)  = 
  let v : t = {expression_desc = Var i; comment = None} in
  assign ?comment  v (int32_add v (int 1))

let prefix_dec ?comment i  = 
  let v : t = {expression_desc = Var i; comment = None} in
  assign ?comment v (int32_minus v (int 1))

let float_mul ?comment e1 e2 = 
  bin ?comment Mul e1 e2 

let float_div ?comment e1 e2 = 
  bin ?comment Div e1 e2 
let float_notequal ?comment e1 e2 = 
  bin ?comment NotEqEq e1 e2

let int32_div ?comment e1 e2 : J.expression = 
  to_int32 (float_div ?comment e1 e2)


(* TODO: call primitive *)    
let int32_mul ?comment e1 e2 : J.expression = 
  { comment ; 
    expression_desc = Bin (Mul, e1,e2)
  }


(* TODO: check division by zero *)                
let int32_mod ?comment e1 e2 : J.expression = 
  { comment ; 
    expression_desc = Bin (Mod, e1,e2)
  }

let int32_lsl ?comment e1 e2 : J.expression = 
  { comment ; 
    expression_desc = Bin (Lsl, e1,e2)
  }

(* TODO: optimization *)    
let int32_lsr ?comment
    (e1 : J.expression) 
    (e2 : J.expression) : J.expression = 
  match e1.expression_desc, e2.expression_desc with
  | Number (Int { i = i1}), Number( Int {i = i2})
    ->
    int @@ Int32.to_int 
      (Int32.shift_right_logical
         (Int32.of_int i1) i2)
  | _ ,  Number( Int {i = i2})
    ->
    if i2 = 0 then 
      e1
    else 
      { comment ; 
        expression_desc = Bin (Lsr, e1,e2) (* uint32 *)
      }
  | _, _ ->
    to_int32  { comment ; 
                expression_desc = Bin (Lsr, e1,e2) (* uint32 *)
              }

let int32_asr ?comment e1 e2 : J.expression = 
  { comment ; 
    expression_desc = Bin (Asr, e1,e2)
  }

let int32_bxor ?comment e1 e2 : J.expression = 
  { comment ; 
    expression_desc = Bin (Bxor, e1,e2)
  }

let rec int32_band ?comment (e1 : J.expression) (e2 : J.expression) : J.expression = 
  match e1.expression_desc with 
  | Bin (Bor ,a, {expression_desc = Number (Int {i = 0})})
    -> 
    (* Note that in JS
       {[ -1 >>> 0 & 0xffffffff = -1]} is the same as 
       {[ (-1 >>> 0 | 0 ) & 0xffffff ]}
    *)
    int32_band a e2
  | _  ->
    { comment ; 
      expression_desc = Bin (Band, e1,e2)
    }

let int32_bor ?comment e1 e2 : J.expression = 
  { comment ; 
    expression_desc = Bin (Bor, e1,e2)
  }

(* let int32_bin ?comment op e1 e2 : J.expression =  *)
(*   {expression_desc = Int32_bin(op,e1, e2); comment} *)


(* TODO -- alpha conversion 
    remember to add parens..
*)
let of_block ?comment block e : t = 
  call ~info:{arity=Full}
    {
      comment ;
      expression_desc = 
        Fun ([], (block @ [{J.statement_desc = Return {return_value = e } ;
                            comment}]) , Js_fun_env.empty 0)
    } []

