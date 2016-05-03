(* This file is part of the Kind 2 model checker.

   Copyright (c) 2015 by the Board of Trustees of the University of Iowa

   Licensed under the Apache License, Version 2.0 (the "License"); you
   may not use this file except in compliance with the License.  You
   may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0 

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
   implied. See the License for the specific language governing
   permissions and limitations under the License. 

*)


open Lib

module Blah = NuLockStepDriver


(* |===| IO stuff *)


(* Opens a file in write mode, creating it if needed. *)
let openfile path = Unix.openfile path [
  Unix.O_TRUNC ; Unix.O_WRONLY ; Unix.O_CREAT
] 0o640

(* Formatter of a file descriptor. *)
let fmt_of_file file =
  Unix.out_channel_of_descr file |> Format.formatter_of_out_channel

(* Writes a graph in graphviz to file [<path>/<name>_<suff>.dot]. *)
let write_dot_to path name suff fmt_graph graph =
  mk_dir path ; (* Create directory if needed. *)
  let desc = (* Create descriptor for log file. *)
    Format.sprintf "%s/%s_%s.dot" path name suff |> openfile
  in
  (* Log graph in graphviz. *)
  Format.fprintf (fmt_of_file desc) "%a@.@." fmt_graph graph ;
  (* Close log file descriptor. *)
  Unix.close desc



(* |===| Module and type aliases *)


(* LSD module. *)
module Lsd = LockStepDriver

(* Term hash table. *)
module Map = Term.TermHashtbl
(* Term set. *)
module Set = Term.TermSet

(* Term. *)
type term = Term.t
(* A representative is just a term. *)
type rep = term

(* Maps terms to something. *)
type 'a map = 'a Map.t
(* Set of terms. *)
type set = Set.t

(* Term formatter. *)
let fmt_term = Term.pp_print_term



(* |===| Communication stuff. *)

(* Guards a term with init if in two state mode. *)
let sanitize_term two_state sys term =
  if two_state then (
    match Term.var_offsets_of_term term with
    | Some min, Some max when min != max ->
      Term.mk_or [ TransSys.init_flag_of_bound sys Numeral.zero ; term ]
    | _ -> term
  ) else term

(* Instantiates [invariants] for all the systems calling [sys] and communicates
them to the framework. *)
let communicate_invariants top_sys two_state sys invariants =
  if Set.is_empty invariants then 0 else (
    let invariants = Set.elements invariants in

    (* All intermediary invariants and top level ones. *)
    let ((_, top_invariants), intermediary_invariants) =
      if top_sys == sys then
       (top_sys, List.map (sanitize_term two_state sys) invariants), []
      else
       Term.mk_and invariants
       (* Guarding with init if needed. *)
       |> sanitize_term two_state sys
       (* Instantiating at all levels. *)
       |> TransSys.instantiate_term_all_levels 
         top_sys TransSys.prop_base (TransSys.scope_of_trans_sys sys)
    in

    intermediary_invariants |> List.iter (
      fun (sub_sys, terms) ->
        (* Adding invariants to the transition system. *)
        terms |> List.iter (TransSys.add_invariant sub_sys) ;
        (* Broadcasting invariants. *)
        terms |> List.iter (
          TransSys.scope_of_trans_sys sub_sys |> Event.invariant
        )
    ) ;

    let top_scope = TransSys.scope_of_trans_sys top_sys in

    top_invariants |> List.iter (
      fun inv ->
        (* Adding top level invariants to transition system. *)
        TransSys.add_invariant top_sys inv ;
        (* Communicate invariant. *)
        Event.invariant top_scope inv
    ) ;

    List.length top_invariants
  )




(* |===| Functor stuff *)


(** Signature of the modules describing an order relation over some values. *)
module type In = sig
  (** Short string description of the values, used in the logging prefix. *)
  val name : string
  (** Type of the values of the candidate terms. *)
  type t
  (** Value formatter. *)
  val fmt : Format.formatter -> t -> unit
  (** Equality over values. *)
  val eq : t -> t -> bool
  (** Ordering relation. *)
  val cmp : t -> t -> bool
  (** Creates the term corresponding to the ordering of two terms. *)
  val mk_cmp : Term.t -> Term.t -> Term.t
  (** Evaluates a term. *)
  val eval : TransSys.t -> Model.t -> Term.t -> t
  (** Mines a transition system for candidate terms. *)
  val mine : TransSys.t -> (TransSys.t * Term.TermSet.t) list
end

(** Signature of the module returned by the [Make] invariant generation functor
when given a module with signature [In]. *)
module type Out = sig
  (** Runs the invariant generator. *)
  val main : TransSys.t -> unit
  (** Clean exit for the invariant generator. *)
  val exit : unit -> unit
end



(** Constructs an invariant generation module from a value module.

The central notion used in the graph splitting algorithm is "chains". A chain
is just a list of representative / value pairs that represent the new nodes
obtained after splitting an old node.

Throughout the different algorithms, a chain is ordered by decreasing values.

Once a node is split, the chain is inserted in all the parents of the old node.
The update algorithm is designed such that a node is split iff all its parents
have already be split (that is, their value is known).

Inserting a chain in the parents consists in extracting the longest prefix from
the chain such that all the values are greater than that of the parent. So for
instance when inserting the chain [7, 3, 2, -1] (omitting the representatives)
for a parent with value 1, then the longest prefix is [7, 3, 2]. The graph is
thus updated by linking the parent to the representative with value 2. The rest
of the chain ([-1]) is inserted in all the parents of the parent. *)
module Make (Value : In) : Out = struct

  (* Reference to LSD for clean exit. *)
  let lsd_ref = ref None

  (* Kills the LSD instance. *)
  let no_more_lsd () = match !lsd_ref with
  | None -> ()
  | Some lsd -> Lsd.delete lsd

  (* Clean exit. *)
  let exit () =
    no_more_lsd () ;
    exit 0

  (** Prefix used for logging. *)
  let pref = Format.sprintf "[%s Inv Gen]" Value.name

  (** Structure storing all the graph information. *)
  type graph = {
    (** Maps representatives [t] to the set [{t_i}] of representatives such
    that, for all models seen so far and for all [t_i]s, [In.cmp t t_i]. *)
    map_up: set map ;
    (** Maps representatives [t] to the set [{t_i}] of representatives such
    that, for all models seen so far and for all [t_i]s, [In.cmp t_i t]. *)
    map_down: set map ;
    (** Maps representatives [t] to the set of terms [{t_i}] they represent.
    That is, for all models seen so far and for all [t_i]s,
    [In.value_eq t t_i]. *)
    classes: set map ;
    (** Maps representatives to the value they evaluate to in the current
    model. Cleared between each iteration ([clear] not [reset]). *)
    values: Value.t map ;
  }

  (* Graph constructor. *)
  let mk_graph rep candidates = {
    map_up = (
      let map = Map.create 107 in
      Map.replace map rep Set.empty ;
      map
    ) ;
    map_down = (
      let map = Map.create 107 in
      Map.replace map rep Set.empty ;
      map
    ) ;
    classes = (
      let map = Map.create 107 in
      Map.replace map rep candidates ;
      map
    ) ;
    values = Map.create 107 ;
  }

  (* Formats a graph to graphviz format. *)
  let fmt_graph_dot fmt { map_up ; map_down ; classes ; values } =
    Format.fprintf fmt
      "\
  digraph mode_graph {
    graph [bgcolor=black margin=0.0] ;
    node [
      style=filled
      fillcolor=black
      fontcolor=\"#1e90ff\"
      color=\"#666666\"
    ] ;
    edge [color=\"#1e90ff\" fontcolor=\"#222222\"] ;

    @[<v>" ;

    map_up |> Map.iter (
      fun key ->
        let key_len = 1 + (Set.cardinal (Map.find classes key)) in
        let key_value =
          try Map.find values key |> Format.asprintf "%a" Value.fmt
          with Not_found -> "_mada_"
        in
        Term.TermSet.iter (
          fun kid ->
            let kid_len = 1 + (Set.cardinal (Map.find classes kid)) in
            let kid_value =
              try Map.find values kid |> Format.asprintf "%a" Value.fmt
              with Not_found -> "_mada_"
            in
            Format.fprintf
              fmt "\"%a (%d, %s)\" -> \"%a (%d, %s)\" [\
                constraint=false\
              ] ;@ "
              fmt_term key key_len key_value
              fmt_term kid kid_len kid_value
        )
    ) ;

    map_down |> Map.iter (
      fun key ->
        let key_len = 1 + (Set.cardinal (Map.find classes key)) in
        let key_value =
          try Map.find values key |> Format.asprintf "%a" Value.fmt
          with Not_found -> "_mada_"
        in
        Term.TermSet.iter (
          fun kid ->
            let kid_len = 1 + (Set.cardinal (Map.find classes kid)) in
            let kid_value =
              try Map.find values kid |> Format.asprintf "%a" Value.fmt
              with Not_found -> "_mada_"
            in
            Format.fprintf
              fmt "\"%a (%d, %s)\" -> \"%a (%d, %s)\" [\
                color=\"red\"\
              ] ;@ "
              fmt_term key key_len key_value
              fmt_term kid kid_len kid_value
        )
    ) ;

    Format.fprintf fmt "@]@.}@."


  (** Logs the equivalence classes of a graph to graphviz. *)
  let fmt_graph_classes_dot fmt { classes ; values } =
    Format.fprintf fmt
      "\
  digraph mode_graph {
    graph [bgcolor=black margin=0.0] ;
    node [
      style=filled
      fillcolor=black
      fontcolor=\"#1e90ff\"
      color=\"#666666\"
    ] ;
    edge [color=\"#1e90ff\" fontcolor=\"#222222\"] ;

    @[<v>" ;

    classes |> Map.iter (
      fun rep set ->
        let rep_value =
          try Map.find values rep |> Format.asprintf "%a" Value.fmt
          with Not_found -> "_mada_"
        in
        Format.fprintf fmt "\"%a (%s)\" ->\"%a\" ;@ "
          fmt_term rep rep_value
          (pp_print_list
            (fun fmt term -> Format.fprintf fmt "@[<h>%a@]" fmt_term term)
            "\n")
          (Set.elements set)
    ) ;

    Format.fprintf fmt "@]@.}@."

  (* Checks that a graph makes sense. *)
  let check_graph ( { map_up ; map_down ; classes } as graph ) =
    Format.printf "Checking graph...@.@." ;
    Map.fold (
      fun rep reps ok ->

        let is_ok = ref true in

        if ( (* Fail if [rep] has no kids and is not [true] or [false]. *)
          Set.is_empty reps && rep <> Term.t_false && rep <> Term.t_true
        ) then (
          Event.log L_fatal
            "Inconsistent graph:@   \
            @[<v>representative [%a] has no kids@]"
            Term.pp_print_term rep ;
          is_ok := false
        ) ;

        ( try let _ = Map.find classes rep in ()
          with Not_found -> (
            Event.log L_fatal
              "Inconsistent graph:@   \
              @[<v>representative [%a] has no equivalence class@]"
              Term.pp_print_term rep ;
            is_ok := false
          )
        ) ;

        reps |> Set.iter (
          fun kid ->
            try (
              let kid_parents = Map.find map_down kid in
              if Set.mem rep kid_parents |> not then (
                (* Fail if [rep] is not a parent of [kid]. *)
                Event.log L_fatal
                  "Inconsistent graph:@   \
                  @[<v>representative [%a] is a kid of [%a]@ \
                  but [%a] is not a parent of [%a]@]"
                  Term.pp_print_term kid Term.pp_print_term rep
                  Term.pp_print_term rep Term.pp_print_term kid ;
                is_ok := false
              )
            ) with Not_found -> (
              (* Fail if [kid] does not appear in [map_down]. *)
              Event.log L_fatal
                "Inconsistent graph:@   \
                @[<v>representative [%a] does not appear in [map_down]@]"
                Term.pp_print_term kid ;
              is_ok := false
            )
        ) ;

        ok && ! is_ok
    ) map_up true
    |> function
    | true -> ()
    | false -> (
      Event.log L_fatal
        "Stopping invariant generation due to graph inconsistencies" ;
      no_more_lsd () ;
      let dump_path = "./" in
      Event.log L_fatal
        "Dumping current graph as graphviz in current directory" ;
      write_dot_to
        dump_path "inconsistent" "graph" fmt_graph_dot graph ;
      Event.log L_fatal
        "Dumping current classes as graphviz in current directory" ;
      write_dot_to
        dump_path "inconsistent" "classes" fmt_graph_classes_dot graph ;
      failwith "inconsistent graph"
    )


  (** Clears the [values] field of the graph ([clear] not [reset]). *)
  let clear { values } = Map.clear values

  (** Minimal list of terms encoding the current state of the graph. Contains
  - equality between representatives and their class, and
  - comparison terms between representatives.

  Used when querying the base instance of the LSD (graph stabilization).
  See also [all_terms_of], used for the step instance (induction check). *)
  let terms_of {map_up ; classes} known =
    let cond_cons cand l = if known cand then l else cand :: l in
    let eqs =
      Map.fold (
        fun rep set acc ->
          if Set.is_empty set then acc else
            cond_cons (rep :: Set.elements set |> Term.mk_eq) acc
      ) classes []
    in
    Map.fold (
      fun rep above acc ->
        above |> Set.elements |> List.fold_left (
          fun acc rep' -> cond_cons (Value.mk_cmp rep rep') acc
        ) acc
    ) map_up eqs

  (** Maximal list of terms encoding the current state of the graph. Contains
  - equality between representatives and their class, and
  - comparison terms between all members of the classes.

  Ignores all terms for which [known] is [true].

  Used when querying the step instance of the LSD (induction check). The idea
  is that while the comparison terms between representatives may not be
  inductive, some comparison terms between member of their respective class
  may be.

  See also [terms_of], used for the base instance (graph stabilization).
  This version produces a much larger number of terms. *)
  let all_terms_of {map_up ; classes} known =
    let cond_cons cand l = if known cand then l else cand :: l in
    (* let eqs =
      Map.fold (
        fun rep set acc ->
          if Set.is_empty set then acc else
            cond_cons (rep :: Set.elements set |> Term.mk_eq) acc
      ) classes []
    in *)
    Map.fold (
      fun rep above acc ->
        Set.fold (
          fun rep' acc ->
            (cond_cons (Value.mk_cmp rep rep') acc, true)
            |> Set.fold (
              fun rep_eq' (acc, fst) ->
                cond_cons (Value.mk_cmp rep rep_eq') acc
                |> Set.fold (
                  fun rep_eq acc ->
                    let acc =
                      if fst then (
                        cond_cons (Value.mk_cmp rep_eq rep') acc
                        |> cond_cons (Term.mk_eq [rep ; rep_eq])
                      ) else acc
                    in
                    cond_cons (Value.mk_cmp rep_eq rep_eq') acc
                ) (Map.find classes rep),
                false
            ) (Map.find classes rep')
            |> fst
        ) above acc
    ) map_up []

  (* Formats a chain. See functor level documentation. *)
  let fmt_chain fmt =
    Format.fprintf fmt "[%a]" (
      pp_print_list
      (fun fmt (rep, value) ->
        Format.fprintf fmt "<%a, %a>" fmt_term rep Value.fmt value)
      ", "
    )

  (** Applies a function [f] to the value [key] is bound to in [map].

  Optional parameter [not_found] is used if [key] is not bound in [map]:
  - if it's [None], [apply] fails
  - if it's [Some default], then a binding between [key] and [f default] will
    be created
  *)
  let apply ?(not_found=None) f key map =
    try
      Map.find map key |> f |> Map.replace map key
    with Not_found -> (
      match not_found with
      | None ->
        Format.asprintf "could not find %a in map" fmt_term key
        |> failwith
      | Some default -> f default |> Map.replace map key
    )

  (** Transitive recursive closure of the parent relation. *)
  let parent_trc map_down =
    let rec loop to_do set rep =
      let kids = Map.find map_down rep in
      let set, to_do =
        Set.fold (
          fun kid (set, to_do) ->
            if Set.mem kid set then set, to_do
            else Set.add kid set, Set.add kid to_do
        ) kids (Set.add rep set, to_do)
      in
      try (
        let rep = Set.choose to_do in
        loop (Set.remove rep to_do) set rep
      ) with Not_found -> set
    in
    loop Set.empty

  (** Adds an edge to the graph. Updates [map_up] and [map_down]. *)
  let add_up { map_up ; map_down } rep kid =
    apply ~not_found:(Some Set.empty) (Set.add kid) rep map_up ;
    apply ~not_found:(Some Set.empty) (Set.add rep) kid map_down


  (** Splits the class of a representative based on a model. Returns the
  resulting chain. *)
  let split sys { classes ; values ; map_up ; map_down } model rep =
    (* Format.printf "  splitting %a@." fmt_term rep ; *)

    let rep_val = Value.eval sys model rep in
    (* Class of the representative. Terms evaluating to a different value will
    be removed from this set. *)
    let rep_cl4ss = ref (Map.find classes rep) in

    (* Insertion in a list of triples composed of
    - a representative
    - its value in the model
    - its class (set of terms
    The list is ordered by decreasing values.

    Used to evaluate all the terms in [rep_cl4ss] and create the new classes.

    If a representative for the value we're inserting does not exist, then
    a new triple [term, value, Set.empty] is created at the right place in the
    sorted list. Otherwise, if the value is different from [rep_val], it is
    inserted in the set of the representative with that value.
    In both these cases, the term is removed from [rep_cl4ss].
    If the value is equal to [rep_val], nothing happens.

    The idea is that if all terms evaluate to the representative's value, no
    operation is performed. Once all terms in [rep_cl4ss] have been evaluated
    and "inserted", then the representative is inserted with the remaining
    terms form [rep_cl4ss]. *)
    let rec insert ?(is_rep=false) pref sorted term value =
      if is_rep || value <> rep_val then (
        let default = if is_rep then !rep_cl4ss else Set.empty in
        if not is_rep then rep_cl4ss := Set.remove term !rep_cl4ss ;

        match sorted with

        | [] ->
          (* No more elements, inserting. *)
          (term, value, default) :: pref |> List.rev

        | (rep, value', set) :: tail when value = value' ->
          (* Inserting. *)
          (rep, value', Set.add term set) :: tail |> List.rev_append pref

        | ( (_, value', _) :: _ as tail) when Value.cmp value' value ->
          (* Found a value lower than [value], inserting. *)
          (term, value, default) :: tail |> List.rev_append pref

        | head :: tail ->
          (* [head] is greater than [value], looping. *)
          insert ~is_rep:is_rep (head :: pref) tail term value

      ) else sorted
    in

    (* Creating new classes if necessary. *)
    let sorted =
      Set.fold (
        fun term sorted -> insert [] sorted term (Value.eval sys model term)
      ) !rep_cl4ss []
    in

    match sorted with

    (* No new class was created, all terms evaluate to the value of the 
    representative. *)
    | [] ->
      (* Format.printf
        "    all terms evaluate to %a@.@." Value.fmt rep_val ; *)
      (* Update values, no need to update classes. *)
      Map.replace values rep rep_val ;
      (* All terms in the class yield the same value. *)
      [ (rep, rep_val) ]

    (* New classes were created. *)
    | _ ->
      (* Format.printf "    class was split@.@." ; *)
      (* Representative's class was split, inserting [rep] and its updated
      class. *)
      insert ~is_rep:true [] sorted rep rep_val
      |> List.map (
        fun (rep, value, set) ->
          (* Update class map. *)
          Map.replace classes rep set ;
          (* Update values. *)
          Map.replace values rep value ;
          (* Insert with empty kids and parents if not already there. *)
          apply ~not_found:(Some Set.empty) identity rep map_up ;
          apply ~not_found:(Some Set.empty) identity rep map_down ;

          (rep, value)
      )


  (** Inserts a chain obtained by splitting [rep] in a graph.

  Remember that a node can be split iff all its parents have been split. *)
  let insert ({ map_up ; map_down ; values } as graph) rep chain =
    (* Format.printf "  inserting chain for %a@." fmt_term rep ;
    Format.printf "    chain: %a@." fmt_chain chain ; *)

    (* Nodes above [rep]. *)
    let above = Map.find map_up rep in
    (* Nodes below [rep]. *)
    let below = Map.find map_down rep in

    (* Format.printf
      "    %d above, %d below@." (Set.cardinal above) (Set.cardinal below) ; *)

    (* Greatest value in the chain. *)
    let greatest_rep, greatest_val = List.hd chain in

    (* Break all links from [rep], except if rep is the top of the chain. These
    links will be used to update the kids of [rep] in the future. Remember that
    a node can be split iff all its parents have been split. Hence all the kids
    of the current representative have not been split yet. *)
    if Term.equal rep greatest_rep |> not then (
      (* Format.printf "    breaking all links from %a@." fmt_term rep ; *)
      map_up |> apply (
        fun set ->
          (* Break downlinks. *)
          set |> Set.iter (
            fun rep' ->
              (* Format.printf
                "      breaking %a -> %a@." fmt_term rep fmt_term rep' ; *)
              map_down |> apply (Set.remove rep) rep'
          ) ;
          (* Break uplinks. *)
          Set.empty
      ) rep ;
      (* Format.printf "    linking greatest to above@." ; *)
      above |> Set.iter (
        fun above ->
          map_up |> apply (Set.add above) greatest_rep ;
          map_down |> apply (Set.add greatest_rep) above
      )
    ) else (
      (* Format.printf "    keeping uplinks: (original) %a = %a (greatest)@."
        fmt_term rep fmt_term greatest_rep ; *)
    ) ;

    (* Format.printf "    breaking all links to %a@." fmt_term rep ; *)

    (* Break all links to [rep]. *)
    map_down |> apply (
      fun set ->
        (* Break uplinks. *)
        set |> Set.iter (
          fun rep' ->
            (* Format.printf
              "      breaking %a -> %a@." fmt_term rep' fmt_term rep ; *)
            map_up |> apply (Set.remove rep) rep'
        ) ;
        (* Break uplinks. *)
        Set.empty
    ) rep ;

    (* Format.printf "    creating chain links@." ; *)
    
    (* Create links between the elements of the chain.

    Has to be done after we disconnect [rep], otherwise these links would also
    be disconnected. *)
    let rec link_chain last = function
      | (next, _) :: tail ->
        (* Format.printf
          "      creating %a -> %a@." fmt_term next fmt_term last ; *)
        add_up graph next last ;
        link_chain next tail
      | [] -> ()
    in
    ( match chain with
      | (head, _) :: tail -> link_chain head tail
      (* This case IS unreachable, because of the [List.hd chain] above that
      would crash if [chain] was empty. *)
      | [] -> failwith "unreachable"
    ) ;

    (* Returns the longest subchain above [value'], in INCREASING order.
    Assumes the chain is in DECREASING order. *)
    let rec longest_above pref value' = function
      | (rep, value) :: tail when Value.cmp value' value ->
        (* [value'] lower than the head, looping. *)
        longest_above (rep :: pref) value' tail
      | rest ->
        (* [value'] greaten than the head, done. *)
        pref, rest
    in

    (* Inserts a chain.
    - [known]: nodes below [rep] we have already seen
    - [continuation]: list of (sub)chain / parent left to handle
    - [chain]: (sub)chain we're currently inserting
    - [node]: the node we're trying to link to the chain *)
    let rec insert known continuation chain node =
      (* Format.printf "  inserting for %a@." fmt_term node ;

      Format.printf "  continuation: @[<v>%a@]@."
        (pp_print_list
          (fun fmt (chain, nodes) ->
            Format.fprintf fmt "chain: %a@ nodes: %a" fmt_chain chain (pp_print_list fmt_term ", ") nodes)
          "@ ")
        continuation ; *)

      let value = Map.find values node in

      (* Longest chain above current node. *)
      let chain_above, rest = longest_above [] value chain in

      (* Format.printf "    %d above, %d below@."
        (List.length chain_above) (List.length rest) ; *)

      (* Creating links. *)
      ( match chain_above with
        | [] ->
          (* [value] is greater than the greatest value in the (sub)chain. *)

          (* Linking [node] with [above] if [node] is in [below]. (This means
          [node] is a direct parent of [rep] that's greater than any element of
          the chain.) *)
          if Set.mem node below then (
            (* Format.printf "    linking node to above@." ; *)
            map_up |> apply (Set.union above) node ;
            above |> Set.iter (
              fun above -> map_down |> apply (Set.add node) above
            )
          )
        | lowest :: _ ->
          (* [lowest] is the LOWEST element of the chain above [node]. We thus
          link [node] to [lowest]. *)

          add_up graph node lowest ;

          (* I had this thing at some point, but it should not be needed.
          Keeping it just in case. *)

          (* (* Also linking with [above] is [node] is in [below]. *)
          if Set.mem node below then (
            (* Format.printf "    linking greatest to above@." ; *)
            map_up |> apply (Set.union above) greatest_rep ;
            above |> Set.iter (
              fun above -> map_down |> apply (Set.add greatest_rep) above
            )
          ) *)
      ) ;

      (* Anything left to insert below? *)
      match rest with
      | [] ->
        (* Chain completely inserted, add everything below [node] to
        [known]. *)
        let known = parent_trc map_down known node in
        (* Continuing. *)
        continue known continuation
      | _ ->
        (* Not done inserting the chain. *)
        (rest, Map.find map_down node |> Set.elements) :: continuation
        |> continue known

    (* Continuation for chain insertion. *)
    and continue known = function
      | ( chain, [node]) :: continuation ->
        if Set.mem node known then (
          (* Format.printf "    skipping known rep %a@." fmt_term node ; *)
          continue known continuation
        ) else (
          insert (Set.add node known) continuation chain node
        )
      | ( chain, node :: rest) :: continuation ->
        if Set.mem node known then (
          (* Format.printf "    skipping known rep %a@." fmt_term node ; *)
          continue known ( (chain, rest) :: continuation )
        ) else (
          insert (Set.add node known) (
            (chain, rest) :: continuation
          ) chain node
        )
      | (_, []) :: continuation -> continue known continuation
      | [] -> ()
    in

    match Set.elements below with

    (* Nothing below the node that was split. Linking everything above to
    greatest. Future splits will insert things in the right place. *)
    | [] ->
      (* Format.printf "    linking greatest to above@." ; *)
      map_up |> apply (Set.union above) greatest_rep ;
      above |> Set.iter (
        fun above -> map_down |> apply (Set.add greatest_rep) above
      )

    (* Need to insert the chain. *)
    | node :: rest ->
      (* Format.printf "    below:@[<v>%a%a@]@."
        fmt_term node
        (pp_print_list (fun fmt -> Format.fprintf fmt "@ %a" fmt_term) "")
        rest ; *)
      insert Set.empty [ (chain), rest ] chain node

  (* Finds a node that's not been split, but with all its parents split. *)
  let next_of_continuation { map_down ; values } =
    (* [skipped] contains the nodes with parents that have not been split
    yet. *)
    let rec loop skipped = function
      | [] -> assert (skipped = []) ; None
      | (nxt :: rest) :: tail ->
        (* Next rep of continuation is legal if all parents have been
        split. *)
        let legal_nxt =
          try
            Map.find map_down nxt
            |> Set.for_all (
              fun rep -> Map.mem values rep
            )
          with Not_found ->
            Format.asprintf "could not find rep %a in map down" fmt_term nxt
            |> failwith
        in
        if legal_nxt then
          Some (nxt, (List.rev_append skipped rest) :: tail)
        else
          loop (nxt :: skipped) (rest :: tail)
      | [] :: tail -> loop skipped tail
    in
    loop []

  (** Queries the lsd and updates the graph. Iterates until the graph is stable
  meaning the lsd returns unsat. *)
  let rec update sys known lsd out_cnt ({ map_up ; map_down } as graph) = match
    terms_of graph known |> Lsd.query_base lsd sys
  with
  | None ->
    (* Format.printf "unsat, done@.@." ; *)
    ()
  | Some model ->
    (* Format.printf "@.sat, updating graph: %d@." out_cnt ; *)

    (* Splits the graph based on the current model. *)
    let rec loop in_cnt continuation =
      (* Format.printf "@.starting update %d / %d@.@." out_cnt in_cnt ; *)
      match next_of_continuation graph continuation with
      | None -> ()
      | Some (nxt, continuation) -> (
        (* Format.printf "  nxt is %a@.@." fmt_term nxt ; *)
        (* Remember nodes above [nxt]. *)
        let above = Map.find map_up nxt |> Set.elements in
        (* Split and insert chain. *)
        split sys graph model nxt |> insert graph nxt ;
        (* Format.printf "@.  logging graph for %d / %d@." out_cnt in_cnt ; *)
        (* write_dot_to
          "graphs/" "graph" (Format.sprintf "%d_%d" out_cnt in_cnt)
          fmt_graph_dot graph ; *)
        (* Add nodes above [nxt] to continuation if any. *)
        match above with
        | [] -> ()
        | _ ->
          above :: continuation |> loop (in_cnt + 1)
      )
    in

    (* Retrieve all nodes that have no parents. *)
    let orphans =
      Map.fold (
        fun rep parents acc -> if Set.is_empty parents then rep :: acc else acc
      ) map_down []
    in

    (* Clear (NOT RESET) the value map for update. *)
    clear graph ;
    
    (* Stabilize graph. *)
    loop 0 [ orphans ] ;

    (* Checking if we should terminate before looping. *)
    Event.check_termination () ;

    (* Check if new graph is stable. *)
    update sys known lsd (out_cnt + 1) graph


  (** Goes through all the (sub)systems for the current [k]. Then loops
  after incrementing [k]. *)
  let rec system_iterator top_sys memory k = function

  | (sys, graph, non_trivial, trivial) :: graphs ->
    Event.log_uncond "Running on %a for %a"
      Scope.pp_print_scope (TransSys.scope_of_trans_sys sys)
      Numeral.pp_print_numeral k ;
    (* Creating LSD instance. *)
    let lsd = Lsd.create (Flags.Invgen.two_state ()) true sys in
    (* Memorizing LSD instance for clean exit. *)
    lsd_ref := Some lsd ;
    (* Unrolling to [k]. *)
    Lsd.unroll_sys_to lsd sys k ;

    (* Format.printf "LSD instance is at %a@.@." Numeral.pp_print_numeral (Lsd.get_k lsd sys) ; *)

    (* Prunes known invariant from a list of candidates. *)
    let prune cand = Set.mem cand non_trivial || Set.mem cand trivial in

    (* Checking if we should terminate before doing anything. *)
    Event.check_termination () ;

    (* Stabilize graph. *)
    ( try update sys prune lsd 0 graph with
      | e -> (
        Format.printf "caught exception %s@.@." (Printexc.to_string e) ;
        exit ()
      )
    ) ;
    (* write_dot_to
      "graphs/" "classes" (Format.asprintf "%a" Numeral.pp_print_numeral k)
      fmt_graph_classes_dot graph ; *)

    Event.log_uncond "Done stabilizing graph, checking consistency" ;

    (* Check graphs consistency. *)
    check_graph graph ;

    Event.log_uncond "Done checking consistency" ;

    (* Check for invariants. *)
    let non_trivial', trivial' =
      all_terms_of graph prune |> (
        Event.log_uncond "Done extracting candidate terms, querying step" ;
        Lsd.query_step lsd sys
      )
    in

    Event.log_uncond "Done extracting invariants, communicating" ;

    let non_trivial, trivial =
      non_trivial' |> List.fold_left (
        fun set inv -> Set.add inv set
      ) non_trivial,
      trivial' |> List.fold_left (
        fun set inv -> Set.add inv set
      ) trivial
    in

    (* Communicate invariants. *)
    ( match non_trivial', trivial' with
      | [], [] -> ()
      | [], _ ->
        Event.log L_info
          "%s @[<v>system %a at %a (%d/%d)@ found %d trivial invariants@]"
          pref
          Scope.pp_print_scope (TransSys.scope_of_trans_sys sys)
          Numeral.pp_print_numeral k
          (Set.cardinal non_trivial)
          (Set.cardinal trivial)
          (List.length trivial')
      | _ ->
        let trivial_blah fmt = match trivial' with
          | [] -> ()
          | _ ->
            Format.fprintf fmt "@ and %d trivial invariants"
              (List.length trivial')
        in

        (* Communicate non-trivial invariants. *)
        communicate_invariants
          top_sys (Flags.Invgen.two_state ()) sys non_trivial ;

        (* Communicate trivial invariants if asked. *)
        if Flags.Invgen.prune_trivial () |> not then (
          communicate_invariants
            top_sys (Flags.Invgen.two_state ()) sys trivial
          |> ignore
        ) ;

        (* TODO: take into account the number of invariants for top level when
        logging. *)

        Event.log_uncond
          "%s @[<v>system %a at %a (%d/%d)@ found %d invariants%t@]"
          pref
          Scope.pp_print_scope (TransSys.scope_of_trans_sys sys)
          Numeral.pp_print_numeral k
          (Set.cardinal non_trivial)
          (Set.cardinal trivial)
          (List.length non_trivial')
          trivial_blah ;
    ) ;

    (* Destroying LSD. *)
    Lsd.delete lsd ;
    (* Unmemorizing LSD instance. *)
    lsd_ref := None ;

    (* Checking if we should terminate before looping. *)
    Event.check_termination () ;

    (* Looping. *)
    system_iterator
      top_sys ( (sys, graph, non_trivial, trivial) :: memory ) k graphs

  | [] ->
    (* Done for all systems for this k, incrementing. *)
    let k = Numeral.succ k in
    Event.log L_info
      "%s Looking for invariants at %a." pref Numeral.pp_print_numeral k ;
    List.rev memory |> system_iterator top_sys [] k


  (** Invariant generation entry point. *)
  let main sys =

    (* Initial [k]. *)
    let k = if Flags.Invgen.two_state () then Numeral.one else Numeral.zero in

    (* Generating the candidate terms and building the graphs. Result is a list
    of quadruples: system, graph, non-trivial invariants, trivial
    invariants. *)
    Value.mine sys |> List.map (
      fun (sys, set) ->
        let set = Set.add Term.t_true set in
        sys, mk_graph Term.t_false set, Set.empty, Set.empty
    )
    |> system_iterator sys [] k

end




(* |===| Actual invariant generators. *)


module Bool: In = struct
  (* Evaluates a term to a boolean. *)
  let eval_bool sys model term =
    Eval.eval_term (TransSys.uf_defs sys) model term
    |> Eval.bool_of_value

  let name = "Bool"
  type t = bool
  let fmt = Format.pp_print_bool
  let eq lhs rhs = lhs = rhs
  let cmp lhs rhs = rhs || not lhs
  let mk_cmp lhs rhs = Term.mk_implies [ lhs ; rhs ]
  let eval = eval_bool
  let mine sys =
    InvGenCandTermGen.generate_candidate_terms
      (Flags.Invgen.two_state ()) sys sys
    |> fst
end

(** Boolean invariant generation. *)
module BoolInvGen = Make(Bool)


module Integer: In = struct
  (* Evaluates a term to a numeral. *)
  let eval_int sys model term =
    Eval.eval_term (TransSys.uf_defs sys) model term
    |> Eval.num_of_value

  let name = "Int"
  type t = Numeral.t
  let fmt = Numeral.pp_print_numeral
  let eq = Numeral.equal
  let cmp = Numeral.leq
  let mk_cmp lhs rhs = Term.mk_leq [ lhs ; rhs ]
  let eval = eval_int
  let mine sys =
    failwith "integer candidate term mining is unimplemented"
end

(** Integer invariant generation. *)
module IntInvGen = Make(Integer)


module Real: In = struct
  (* Evaluates a term to a decimal. *)
  let eval_real sys model term =
    Eval.eval_term (TransSys.uf_defs sys) model term
    |> Eval.dec_of_value

  let name = "Real"
  type t = Decimal.t
  let fmt = Decimal.pp_print_decimal
  let eq = Decimal.equal
  let cmp = Decimal.leq
  let mk_cmp lhs rhs = Term.mk_leq [ lhs ; rhs ]
  let eval = eval_real
  let mine sys =
    failwith "real candidate term mining is unimplemented"
end

(** Real invariant generation. *)
module RealInvGen = Make(Real)





let main _ _ = BoolInvGen.main
let exit _ = BoolInvGen.exit ()




(* 
   Local Variables:
   compile-command: "make -C .. -k"
   tuareg-interactive-program: "./kind2.top -I ./_build -I ./_build/SExpr"
   indent-tabs-mode: nil
   End: 
*)