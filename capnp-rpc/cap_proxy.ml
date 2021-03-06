module Make(C : S.CORE_TYPES) = struct
  open C
  module Local_struct_promise = Local_struct_promise.Make(C)

  class type embargo_cap = object
    inherit cap
    method disembargo : unit
  end

  type cap_promise_state =
    | Unresolved of (struct_resolver * Request.t * cap RO_array.t) Queue.t
    | Resolved of cap

  class local_cap_promise =
    object (self : #cap)
      inherit ref_counted
      val mutable state = Unresolved (Queue.create ())

      method call msg caps =
        match state with
        | Unresolved q ->
          let result = Local_struct_promise.make () in
          Queue.add (result, msg, caps) q;
          (result :> struct_ref)
        | Resolved cap -> cap#call msg caps

      method resolve cap =
        match state with
        | Unresolved q ->
          state <- Resolved cap;
          let forward (result, msg, caps) =
            let r = cap#call msg caps in
            result#connect r      (* Or should it be connect [r] to [result], for tail-recursion? *)
          in
          Queue.iter forward q
        | Resolved _ -> failwith "Already resolved!"

      method private release = ()

      method shortest =
        match state with
        | Unresolved _ -> (self :> cap)
        | Resolved cap -> cap#shortest

      method pp f =
        match state with
        | Unresolved _ -> Fmt.string f "local-cap-promise -> (unresolved)"
        | Resolved cap -> Fmt.pf f "local-cap-promise -> %t" cap#pp
    end

  let embargo underlying : embargo_cap =
    let cap =
      object
        inherit local_cap_promise as super

        method disembargo =
          super#resolve underlying

        method! pp f =
          match state with
          | Unresolved _ -> Fmt.pf f "embargoed -> %t" underlying#pp
          | Resolved cap -> Fmt.pf f "disembargoed -> %t" cap#pp
      end
    in
    (cap :> embargo_cap)
end
