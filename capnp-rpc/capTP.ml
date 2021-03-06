module Log = Debug.Log

module Make (C : S.CORE_TYPES) (N : S.NETWORK_TYPES) = struct
  module Protocol = Protocol.Make(C)(N)

  module Make (P : Protocol.S) = struct
    open C
    module Cap_proxy = Cap_proxy.Make(C)
    module Struct_proxy = Struct_proxy.Make(C)
    module Local_struct_promise = Local_struct_promise.Make(C)

    type t = {
      queue_send : (P.Out.t -> unit);
      p : P.t;
      ours : (cap, P.cap) Hashtbl.t;              (* TODO: use weak table *)
      tags : Logs.Tag.set;
      embargoes : (cap * Protocol.EmbargoId.t, Cap_proxy.embargo_cap) Hashtbl.t;
      bootstrap : cap option;
    }

    let create ?bootstrap ~tags ~queue_send =
      {
        queue_send;
        p = P.create ~tags ();
        ours = Hashtbl.create 10;
        tags;
        embargoes = Hashtbl.create 10;
        bootstrap;
      }

    let tags t = t.tags
    let stats t = P.stats t.p

    let register t x y =
      assert (not (Hashtbl.mem t.ours x));
      Hashtbl.add t.ours x y

    let unwrap t x =
      try Some (Hashtbl.find t.ours x)
      with Not_found -> None

    module Self_proxy = struct
      (* Will [c#dec_ref] if we no longer need [c], but keep the ref count
         the same if we need it to hang around so the remote peer can use it
         later. *)
      let to_cap_desc t (cap : cap) : P.cap =
        let cap = cap#shortest in
        match unwrap t cap with
        | None -> `Local cap
        | Some x ->
          match x with
          | `ReceiverHosted _
          | `ReceiverAnswer _ -> cap#dec_ref; x
          | `None
          | `SenderHosted _
          | `SenderPromise _
          | `ThirdPartyHosted _
          | `Local _ -> x

      type target = (P.question * unit Lazy.t) option  (* question, finish *)

      let rec call t target msg caps =
        let result = make_remote_promise t in
        let con_caps = RO_array.map (to_cap_desc t) caps in
        let question, qid, message_target, descs = P.Send.call t.p (result :> struct_resolver) target con_caps in
        Log.info (fun f -> f ~tags:t.tags "Sending: (%a).call %a (q%a)"
                     P.pp_cap target
                     Request_payload.pp (msg, caps)
                     P.T.QuestionId.pp qid);
        result#set_question question;
        t.queue_send (`Call (qid, message_target, msg, descs));
        (result :> struct_ref)

      (* A cap that sends to a promised answer's cap at other *)
      and make_remote_promise t =
        object (self : #struct_resolver)
          inherit [target] Struct_proxy.t None as super

          method do_pipeline question i msg caps =
            match question with
            | Some (target_q, _) ->
              let target = `ReceiverAnswer (target_q, i) in
              call t target msg caps
            | None -> failwith "Not initialised!"

          method on_resolve q _ =
            match q with
            | Some (_target_q, finish) -> Lazy.force finish
            | None -> failwith "Not initialised!"

          method! pp f =
            Fmt.pf f "remote-promise -> %a" Struct_proxy.pp_state state

          method set_question q =
            let finish = lazy (
              Log.info (fun f -> f ~tags:t.tags "Send finish %t" self#pp);
              let qid = P.Send.finish t.p q in
              t.queue_send (`Finish (qid, false));
            ) in
            self#update_target (Some (q, finish))

          method! cap path =
            let field = super#cap path in
            begin match state with
              | Unresolved u ->
                begin match u.target with
                  | None -> failwith "Not intialised!"
                  | Some (target_q, _) ->
                    register t field (`ReceiverAnswer (target_q, path));        (* TODO: unregister *)
                end
              | _ -> ()
            end;
            field

          method do_finish = function
            | Some (_, finish) -> Lazy.force finish
            | None -> failwith "Not initialised!"
        end

      (* Turn a connection-scoped cap reference received from Other into a general-purpose
         cap for users. If the resulting cap is remote, our wrapper forwards it to Other.
         This will add a ref count to the cap if it already exists, or create a new
         one with [ref_count = 1]. *)
      let from_cap_desc t (desc:P.recv_cap) : cap =
        match desc with
        | `Local c -> c#inc_ref; c
        | `ReceiverHosted import as message_target ->
          P.import_proxy import
            ~inc_ref:(fun c -> c#inc_ref)
            ~create:(fun () ->
                let cap =
                  object (self : #cap)
                    inherit ref_counted

                    method call msg caps = call t message_target msg caps
                    method pp f = Fmt.pf f "far-ref(rc=%d) -> %a" ref_count P.pp_cap message_target
                    method private release =
                      Log.info (fun f -> f ~tags:t.tags "Release %t" self#pp);
                      let id, count = P.Send.release t.p import in
                      t.queue_send (`Release (id, count))

                    method shortest = self
                  end
                in
                register t cap message_target;
                cap
              )
        | `None -> null
        | `ReceiverAnswer _ -> failwith "TODO: from_cap_desc ReceiverAnswer"
        | `ThirdPartyHosted _ -> failwith "TODO: from_cap_desc ThirdPartyHosted"
        | `LocalPromise (p, i) -> p#cap i

      let reply_to_disembargo t target embargo_id =
        let target = P.Send.disembargo_reply t.p target in
        Log.info (fun f -> f ~tags:t.tags "Sending disembargo response to %a" P.Out.pp_desc target);
        t.queue_send (`Disembargo_reply (target, embargo_id))

      let disembargo t request =
        Log.info (fun f -> f ~tags:t.tags "Sending disembargo %a" P.Out.pp_disembargo_request request);
        t.queue_send (`Disembargo_request request);
    end

    let bootstrap t =
      let result = Self_proxy.make_remote_promise t in
      let question, qid = P.Send.bootstrap t.p (result :> struct_resolver) in
      result#set_question question;
      Log.info (fun f -> f ~tags:t.tags "Sending: bootstrap (q%a)" P.T.QuestionId.pp qid);
      t.queue_send (`Bootstrap qid);
      let service = result#cap Path.root in
      result#when_resolved (fun _ -> result#finish);
      service

    let return_results t answer =
      let q, ret =
        let answer_promise = P.answer_promise answer in
        match answer_promise#response with
        | None -> assert false
        | Some (Ok (msg, caps)) ->
          RO_array.iter (fun c -> c#inc_ref) caps;        (* Copy everything stored in [answer]. *)
          let con_caps = RO_array.map (Self_proxy.to_cap_desc t) caps in
          let q, ret = P.Send.return_results t.p answer msg con_caps in
          Log.info (fun f -> f ~tags:t.tags "Returning results: answer q%a -> %a"
                       P.T.AnswerId.pp q
                       Response_payload.pp (msg, caps));
          q, ret
        | Some (Error (`Exception msg)) ->
          let q, ret = P.Send.return_error t.p answer msg in
          Log.info (fun f -> f ~tags:t.tags "Returning error: answer q%a -> %s"
                       P.T.AnswerId.pp q
                       msg);
          q, ret
        | Some (Error `Cancelled) ->
          let q, ret = P.Send.return_cancelled t.p answer in
          Log.info (fun f -> f ~tags:t.tags "Returning cancelled: answer q%a"
                       P.T.AnswerId.pp q);
          q, ret
      in
      t.queue_send (`Return (q, ret))

    let reply_to_call t = function
      | `Bootstrap answer ->
        let promise = P.answer_promise answer in
        begin match t.bootstrap with
          | Some service ->
            service#inc_ref;
            promise#resolve (Ok (Response.bootstrap, RO_array.of_list [service]));
          | None ->
            promise#resolve (Error (`Exception "No bootstrap service available"));
        end;
        return_results t answer
      | `Call (answer, target, msg, caps) ->
        Log.info (fun f -> f ~tags:t.tags "Handling call: (%t).call %a" target#pp Request_payload.pp (msg, caps));
        let resp = target#call msg caps in  (* Takes ownership of [caps]. *)
        target#dec_ref;
        (P.answer_promise answer)#connect resp;
        resp#when_resolved (fun _ -> return_results t answer)

    let handle_msg t = function
      | `Bootstrap qid ->
         let promise = Local_struct_promise.make () in
         let answer = P.Input.bootstrap t.p qid ~answer:promise in
         reply_to_call t (`Bootstrap answer)
      | `Call (qid, message_target, msg, descs) ->
        Log.info (fun f -> f ~tags:t.tags "Received call a%a to %a"
                     P.T.AnswerId.pp qid
                     P.In.pp_desc message_target);
        let promise = Local_struct_promise.make () in
        let answer, target, caps = P.Input.call t.p qid message_target descs ~allowThirdPartyTailCall:false `Caller ~answer:promise in
        let target = Self_proxy.from_cap_desc t target in
        let caps = RO_array.map (Self_proxy.from_cap_desc t) caps in
        reply_to_call t (`Call (answer, target, msg, caps))
      | `Return (q, ret) ->
         begin match ret with
         | `Results (msg, descs) ->
           let result, caps = P.Input.return_results t.p q msg descs ~releaseParamCaps:false in
           let is_cancelled = result#response = Some (Error `Cancelled) in
           let from_cap_desc = function
             | `LocalEmbargo (c, _) when is_cancelled -> c (* Can't be anything pipelined after the cancel *)
             | `LocalEmbargo (c, disembargo_request) ->
               c#inc_ref;
               Log.info (fun f -> f ~tags:t.tags "Embargo %t until %a is delivered"
                            c#pp
                            P.Out.pp_disembargo_request disembargo_request
                        );
               (* We previously pipelined messages to [qid, index], which now turns out to be
                  local service [c]. We need to send a disembargo to clear the pipeline before
                  using [c]. *)
               let embargo = Cap_proxy.embargo c in
               let `Loopback (_target, embargo_id) = disembargo_request in
               Hashtbl.add t.embargoes (c, embargo_id) embargo;
               Self_proxy.disembargo t disembargo_request;
               (embargo :> cap)
             | #P.recv_cap as x -> Self_proxy.from_cap_desc t x
           in
           let caps = RO_array.map from_cap_desc caps in
           Log.info (fun f -> f ~tags:t.tags "Got results: question q%a -> %a"
                        P.T.QuestionId.pp q
                        Response_payload.pp (msg, caps)
                    );
           result#resolve (Ok (msg, caps))
         | `Exception msg ->
           let result = P.Input.return_exception t.p q ~releaseParamCaps:false in
           Log.info (fun f -> f ~tags:t.tags "Got exception: question q%a -> %s"
                        P.T.QuestionId.pp q
                        msg
                    );
           result#resolve (Error (`Exception msg))
         | `Cancelled ->
           let result = P.Input.return_cancelled t.p q ~releaseParamCaps:false in
           Log.info (fun f -> f ~tags:t.tags "Got cancelled: question q%a"
                        P.T.QuestionId.pp q
                    );
           result#resolve (Error `Cancelled)
         | _ -> failwith "TODO: other return"
         end
      | `Finish (qid, releaseResultCaps) ->
        let answer = P.Input.finish t.p qid ~releaseResultCaps in
        Log.info (fun f -> f ~tags:t.tags "Received finish for answer %a -> %t"
                     P.T.AnswerId.pp
                     qid answer#pp);
        answer#finish
      | `Release (id, referenceCount) ->
        P.Input.release t.p id ~referenceCount
      | `Disembargo_request request ->
        begin
          Log.info (fun f -> f ~tags:t.tags "Received disembargo %a" P.In.pp_disembargo_request request);
          match P.Input.disembargo_request t.p request with
          | `ReturnToSender ((answer_promise, path), id) ->
            match answer_promise#response with
            | None -> failwith "Got disembargo for unresolved promise!"
            | Some (Error _) -> failwith "Got disembargo for exception!"
            | Some (Ok payload) ->
              let cap = Response_payload.field payload path in
              match unwrap t cap with
              | Some (`ReceiverHosted _ as target) -> Self_proxy.reply_to_disembargo t target id
              | _ -> failwith "Protocol error: disembargo for invalid target"
        end
      | `Disembargo_reply (target, embargo_id) ->
        let cap = P.Input.disembargo_reply t.p target in
        let embargo = Hashtbl.find t.embargoes (cap, embargo_id) in
        Log.info (fun f -> f ~tags:t.tags "Received disembargo response %a -> %t"
                     P.In.pp_desc target
                     embargo#pp);
        embargo#disembargo
  end
end
