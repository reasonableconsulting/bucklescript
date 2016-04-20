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

let (<< ) = Nativeint.shift_left
let (>>>) = Nativeint.shift_right_logical
let (|~) = Nativeint.logor
let (^) = Nativeint.logxor

external ( *~ ) : nativeint -> nativeint -> nativeint = "caml_int32_mul" 
external ( +~ ) : nativeint -> nativeint -> nativeint = "caml_int32_add"



let rotl32 (x : nativeint) n  = 
  (x << n) |~ (x >>> (32 - n))


let mix h  d = 
  let d = ref d in 
  d := !d *~ 0xcc9e2d51n ;
  d := rotl32 !d 15 ;
  d := !d *~ 0x1b873593n ;
  let h = ref (h ^ !d) in
  h := rotl32 !h 13 ;
  !h +~ (!h << 2)  +~ 0xe6546b64n  

let final_mix h = 
  let h = ref (h ^ (h >>> 16)) in
  h := !h *~ 0x85ebca6bn ;
  h := !h ^ (!h >>> 13);
  h := !h *~ 0xc2b2ae35n ;
  !h ^ (!h >>> 16)
  (* Nativeint.logand  (!h ^ (!h >>> 16)) 0x3FFFFFFFn *)

let caml_hash_mix_string h  s = 
  let len = String.length s in
  let block = len / 4 - 1  in
  let hash = ref h in  
  for i = 0 to block  do 
    let j = 4 * i in 
    let w = 
      Char.code s.[j] lor 
      (Char.code s.[j+1] lsl 8) lor 
      (Char.code s.[j+2] lsl 16) lor 
      (Char.code s.[j+3] lsl 24)
    in
    hash := mix !hash (Nativeint.of_int w)
  done ;
  let modulo =  len land 0b11 in 
  if modulo <> 0 then 
    begin 
      let w =
        if modulo = 3 then 
          (Char.code s.[len - 1] lsl 16) lor 
          (Char.code s.[len - 2] lsl 8) lor
          (Char.code s.[len - 3])
        else if modulo = 2 then 
          (Char.code s.[len -1] lsl 8) lor 
          Char.code s.[len -2]
        else Char.code s.[len - 1] 
      in 
      hash := mix !hash (Nativeint.of_int w)
    end;
  hash := !hash ^ (Nativeint.of_int len) ;
  !hash 


let caml_hash count _limit seed obj = 
  let hash = ref seed in 
  if Js.typeof obj = "number" then
    begin 
      let u = (Nativeint.of_float (Obj.magic obj)) in
      hash := mix !hash (u +~ u +~ 1n) ;
      final_mix !hash
    end
  else if Js.typeof obj = "string" then 
    begin 
      hash := caml_hash_mix_string !hash (Obj.magic obj : string);
      final_mix !hash
    end
    (* TODO: hash [null] [undefined] as well *)
  else 

    let queue = Caml_queue.create () in 
    let num = ref count in 
    let () = 
      Caml_queue.push obj queue; 
      decr num 
    in 
    while not @@ Caml_queue.is_empty queue && !num > 0 do
      let obj = Caml_queue.unsafe_pop queue in 
      if Js.typeof obj = "number" then
        begin 
          hash := mix !hash (Nativeint.of_float (Obj.magic obj));
          decr num ;
        end
      else if Js.typeof obj = "string" then 
        begin 
          hash := caml_hash_mix_string !hash (Obj.magic obj : string);
          decr num 
        end
      else if Js.typeof obj = "boolean" then 
        ()
      else if Js.typeof obj = "undefined" then 
        ()
      else if Js.typeof obj = "symbol" then 
        assert false (* TODO *)
      else if Js.typeof obj = "function" then
        () 
      else 
        let tag = Obj.tag obj in 
        hash := mix !hash (Nativeint.of_int tag) ;
        let block = 
          let v = Obj.size obj - 1 in if v <  !num then v else !num in 
        for i = 0 to block do
          Caml_queue.push (Obj.field obj i ) queue
        done 
    done;
    final_mix !hash 
    