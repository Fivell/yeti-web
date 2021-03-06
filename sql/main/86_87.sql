begin;
insert into sys.version(number,comment) values(87,'Exclusive route');


ALTER TABLE class4.dialpeers RENAME COLUMN stop_hunting to exclusive_route;
ALTER TABLE data_import.import_dialpeers RENAME COLUMN stop_hunting to exclusive_route;

CREATE OR REPLACE FUNCTION switch10.route(
  i_node_id integer,
  i_pop_id integer,
  i_remote_ip inet,
  i_remote_port integer,
  i_local_ip inet,
  i_local_port integer,
  i_from_dsp character varying,
  i_from_name character varying,
  i_from_domain character varying,
  i_from_port integer,
  i_to_name character varying,
  i_to_domain character varying,
  i_to_port integer,
  i_contact_name character varying,
  i_contact_domain character varying,
  i_contact_port integer,
  i_uri_name character varying,
  i_uri_domain character varying,
  i_x_yeti_auth character varying,
  i_diversion character varying,
  i_x_orig_ip inet,
  i_x_orig_port integer)
  RETURNS SETOF switch10.callprofile50_ty AS
$BODY$
DECLARE
  v_ret switch10.callprofile50_ty;
  i integer;
  v_ip inet;
  v_remote_ip inet;
  v_remote_port INTEGER;
  v_customer_auth class4.customers_auth%rowtype;
  v_destination class4.destinations%rowtype;
  v_dialpeer record;
  v_rateplan class4.rateplans%rowtype;
  v_dst_gw class4.gateways%rowtype;
  v_orig_gw class4.gateways%rowtype;
  v_rp class4.routing_plans%rowtype;
  v_customer_allowtime real;
  v_vendor_allowtime real;
  v_sorting_id integer;
  v_customer_acc integer;
  v_route_found boolean:=false;
  v_c_acc billing.accounts%rowtype;
  v_v_acc billing.accounts%rowtype;
  v_network sys.network_prefixes%rowtype;
  routedata record;
  /*dbg{*/
  v_start timestamp;
  v_end timestamp;
  /*}dbg*/
  v_rate NUMERIC;
  v_now timestamp;
  v_x_yeti_auth varchar;
  --  v_uri_domain varchar;
  v_rate_limit float:='Infinity';
  v_test_vendor_id integer;
  v_random float;
  v_max_call_length integer;
  v_routing_key varchar;
  v_lnp_key varchar;
  v_drop_call_if_lnp_fail boolean;
  v_lnp_rule class4.routing_plan_lnp_rules%rowtype;
BEGIN
  /*dbg{*/
  v_start:=now();
  v_end:=clock_timestamp();
  RAISE NOTICE '% ms -> Execution start',EXTRACT(MILLISECOND from v_end-v_start);
  /*}dbg*/

  perform id from sys.load_balancers where signalling_ip=host(i_remote_ip)::varchar;
  IF FOUND and i_x_orig_ip IS not NULL AND i_x_orig_port IS not NULL THEN
    v_remote_ip:=i_x_orig_ip;
    v_remote_port:=i_x_orig_port;
    /*dbg{*/RAISE NOTICE '% ms -> Got originator address "%:%" from x-headers',EXTRACT(MILLISECOND from v_end-v_start), v_remote_ip,v_remote_port;/*}dbg*/
  else
    v_remote_ip:=i_remote_ip;
    v_remote_port:=i_remote_port;
    /*dbg{*/RAISE NOTICE '% ms -> Got originator address "%:%" from switch leg info',EXTRACT(MILLISECOND from v_end-v_start), v_remote_ip,v_remote_port;/*}dbg*/
  end if;

  v_now:=now();
  v_ret:=switch10.new_profile();
  v_ret.cache_time = 10;

  v_ret.diversion_in:=i_diversion;
  v_ret.diversion_out:=i_diversion; -- FIXME

  v_ret.auth_orig_ip = v_remote_ip;
  v_ret.auth_orig_port = v_remote_port;

  v_ret.src_name_in:=i_from_dsp;
  v_ret.src_name_out:=v_ret.src_name_in;

  v_ret.src_prefix_in:=i_from_name;
  v_ret.dst_prefix_in:=i_uri_name;
  v_ret.dst_prefix_out:=v_ret.dst_prefix_in;
  v_ret.src_prefix_out:=v_ret.src_prefix_in;

  v_ret.ruri_domain=i_uri_domain;
  v_ret.from_domain=i_from_domain;
  v_ret.to_domain=i_to_domain;

  /*dbg{*/
  v_end:=clock_timestamp();
  RAISE NOTICE '% ms -> AUTH. lookup started',EXTRACT(MILLISECOND from v_end-v_start);
  /*}dbg*/
  v_x_yeti_auth:=COALESCE(i_x_yeti_auth,'');
  --  v_uri_domain:=COALESCE(i_uri_domain,'');
  SELECT into v_customer_auth ca.*
  from class4.customers_auth ca
    JOIN public.contractors c ON c.id=ca.customer_id
  WHERE ca.enabled AND
        ca.ip>>=v_remote_ip AND
                prefix_range(ca.dst_prefix)@>prefix_range(v_ret.dst_prefix_in) AND
                prefix_range(ca.src_prefix)@>prefix_range(v_ret.src_prefix_in) AND
                (ca.pop_id=i_pop_id or ca.pop_id is null) and
                COALESCE(ca.x_yeti_auth,'')=v_x_yeti_auth AND
                COALESCE(nullif(ca.uri_domain,'')=i_uri_domain,true) AND
                COALESCE(nullif(ca.to_domain,'')=i_to_domain,true) AND
                COALESCE(nullif(ca.from_domain,'')=i_from_domain,true) AND
                c.enabled and c.customer
  ORDER BY
    masklen(ca.ip) DESC,
    length(prefix_range(ca.dst_prefix)) DESC,
    length(prefix_range(ca.src_prefix)) DESC,
    ca.pop_id is null,
    ca.uri_domain is null,
    ca.to_domain is null,
    ca.from_domain is null
  LIMIT 1;
  IF NOT FOUND THEN
    /*dbg{*/
    v_end:=clock_timestamp();
    RAISE NOTICE '% ms -> AUTH.  disconnection with 110.Cant find customer or customer locked',EXTRACT(MILLISECOND from v_end-v_start);
    /*}dbg*/
    v_ret.disconnect_code_id=110; --Cant find customer or customer locked
    RETURN NEXT v_ret;
    RETURN;
  END IF;

  /*dbg{*/
  v_end:=clock_timestamp();
  RAISE NOTICE '% ms -> AUTH. found: %',EXTRACT(MILLISECOND from v_end-v_start),row_to_json(v_customer_auth, true);
  /*}dbg*/

  -- feel customer data ;-)
  v_ret.dump_level_id:=v_customer_auth.dump_level_id;
  v_ret.customer_auth_id:=v_customer_auth.id;
  v_ret.customer_id:=v_customer_auth.customer_id;
  v_ret.rateplan_id:=v_customer_auth.rateplan_id;
  v_ret.routing_plan_id:=v_customer_auth.routing_plan_id;
  v_ret.customer_acc_id:=v_customer_auth.account_id;
  v_ret.orig_gw_id:=v_customer_auth.gateway_id;

  v_ret.radius_auth_profile_id=v_customer_auth.radius_auth_profile_id;
  v_ret.aleg_radius_acc_profile_id=v_customer_auth.radius_accounting_profile_id;
  v_ret.record_audio=v_customer_auth.enable_audio_recording;

  SELECT INTO STRICT v_c_acc * FROM billing.accounts  WHERE id=v_customer_auth.account_id;
  if v_c_acc.balance<=v_c_acc.min_balance then
    v_ret.disconnect_code_id=8000; --No enought customer balance
    RETURN NEXT v_ret;
    RETURN;
  end if;

  SELECT into v_orig_gw * from class4.gateways WHERE id=v_customer_auth.gateway_id;
  v_ret.resources:='';
  if v_c_acc.origination_capacity is not null then
    v_ret.resources:=v_ret.resources||'1:'||v_c_acc.id::varchar||':'||v_c_acc.origination_capacity::varchar||':1;';
  end if;
  if v_customer_auth.capacity is not null then
    v_ret.resources:=v_ret.resources||'3:'||v_customer_auth.id::varchar||':'||v_customer_auth.capacity::varchar||':1;';
  end if;
  if v_orig_gw.origination_capacity is not null then
    v_ret.resources:=v_ret.resources||'4:'||v_orig_gw.id::varchar||':'||v_orig_gw.origination_capacity::varchar||':1;';
  end if;


  /*
      number rewriting _Before_ routing
  */
  /*dbg{*/
  v_end:=clock_timestamp();
  RAISE NOTICE '% ms -> AUTH. Before rewrite src_prefix: % , dst_prefix: %',EXTRACT(MILLISECOND from v_end-v_start),v_ret.src_prefix_out,v_ret.dst_prefix_out;
  /*}dbg*/
  v_ret.dst_prefix_out=yeti_ext.regexp_replace_rand(v_ret.dst_prefix_out,v_customer_auth.dst_rewrite_rule,v_customer_auth.dst_rewrite_result);
  v_ret.src_prefix_out=yeti_ext.regexp_replace_rand(v_ret.src_prefix_out,v_customer_auth.src_rewrite_rule,v_customer_auth.src_rewrite_result);
  v_ret.src_name_out=yeti_ext.regexp_replace_rand(v_ret.src_name_out,v_customer_auth.src_name_rewrite_rule,v_customer_auth.src_name_rewrite_result);

  --  if v_ret.radius_auth_profile_id is not null then
  v_ret.src_number_radius:=i_from_name;
  v_ret.dst_number_radius:=i_uri_name;
  v_ret.src_number_radius=yeti_ext.regexp_replace_rand(
      v_ret.src_number_radius,
      v_customer_auth.src_number_radius_rewrite_rule,
      v_customer_auth.src_number_radius_rewrite_result
  );

  v_ret.dst_number_radius=yeti_ext.regexp_replace_rand(
      v_ret.dst_number_radius,
      v_customer_auth.dst_number_radius_rewrite_rule,
      v_customer_auth.dst_number_radius_rewrite_result
  );
  v_ret.customer_auth_name=v_customer_auth."name";
  v_ret.customer_name=(select "name" from public.contractors where id=v_customer_auth.customer_id limit 1);
  --  end if;

  --  setting numbers used for routing & billing
  v_ret.src_prefix_routing=v_ret.src_prefix_out;
  v_ret.dst_prefix_routing=v_ret.dst_prefix_out;
  v_routing_key=v_ret.dst_prefix_out;


  /*dbg{*/
  v_end:=clock_timestamp();
  RAISE NOTICE '% ms -> AUTH. After rewrite src_prefix: % , dst_prefix: %',EXTRACT(MILLISECOND from v_end-v_start),v_ret.src_prefix_out,v_ret.dst_prefix_out;
  /*}dbg*/


  --- Blacklist processing
  if v_customer_auth.dst_blacklist_id is not null then
    perform * from class4.blacklist_items bl
    where bl.blacklist_id=v_customer_auth.dst_blacklist_id and bl.key=v_ret.dst_prefix_out;
    IF FOUND then
      v_ret.disconnect_code_id=8001; --destination blacklisted
      RETURN NEXT v_ret;
      RETURN;
    end if;
  end if;
  if v_customer_auth.src_blacklist_id is not null then
    perform * from class4.blacklist_items bl
    where bl.blacklist_id=v_customer_auth.src_blacklist_id and bl.key=v_ret.src_prefix_out;
    IF FOUND then
      v_ret.disconnect_code_id=8002; --source blacklisted
      RETURN NEXT v_ret;
      RETURN;
    end if;
  end if;

  /*dbg{*/
  v_end:=clock_timestamp();
  RAISE NOTICE '% ms -> Routing plan search start',EXTRACT(MILLISECOND from v_end-v_start);
  /*}dbg*/

  select into v_max_call_length,v_drop_call_if_lnp_fail max_call_duration,drop_call_if_lnp_fail from sys.guiconfig limit 1;

  v_routing_key=v_ret.dst_prefix_routing;
  SELECT INTO v_rp * from class4.routing_plans WHERE id=v_customer_auth.routing_plan_id;
  if v_rp.use_lnp then
    select into v_lnp_rule rules.*
    from class4.routing_plan_lnp_rules rules
    WHERE prefix_range(rules.dst_prefix)@>prefix_range(v_ret.dst_prefix_routing) and rules.routing_plan_id=v_rp.id
    order by length(rules.dst_prefix) limit 1;
    if found then
      v_ret.lnp_database_id=v_lnp_rule.database_id;
      v_lnp_key=v_ret.dst_prefix_routing;
      /*dbg{*/
      v_end:=clock_timestamp();
      RAISE NOTICE '% ms -> LNP. Need LNP lookup, LNP key: %',EXTRACT(MILLISECOND from v_end-v_start),v_lnp_key;
      /*}dbg*/
      v_lnp_key=yeti_ext.regexp_replace_rand(v_lnp_key,v_lnp_rule.req_dst_rewrite_rule,v_lnp_rule.req_dst_rewrite_result);
      /*dbg{*/
      v_end:=clock_timestamp();
      RAISE NOTICE '% ms -> LNP key translation. LNP key: %',EXTRACT(MILLISECOND from v_end-v_start),v_lnp_key;
      /*}dbg*/
      -- try cache
      select into v_ret.lrn lrn from class4.lnp_cache where dst=v_lnp_key AND database_id=v_lnp_rule.database_id and expires_at>v_now;
      if found then
        /*dbg{*/
        v_end:=clock_timestamp();
        RAISE NOTICE '% ms -> LNP. Data found in cache, lrn: %',EXTRACT(MILLISECOND from v_end-v_start),v_ret.lrn;
        /*}dbg*/
        -- TRANSLATING response from cache
        v_ret.lrn=yeti_ext.regexp_replace_rand(v_ret.lrn,v_lnp_rule.lrn_rewrite_rule,v_lnp_rule.lrn_rewrite_result);
        /*dbg{*/
        v_end:=clock_timestamp();
        RAISE NOTICE '% ms -> LNP. Translation. lrn: %',EXTRACT(MILLISECOND from v_end-v_start),v_ret.lrn;
        /*}dbg*/
        v_routing_key=v_ret.lrn;
      else
        v_ret.lrn=switch10.lnp_resolve(v_ret.lnp_database_id,v_lnp_key);
        if v_ret.lrn is null then -- fail
          /*dbg{*/
          v_end:=clock_timestamp();
          RAISE NOTICE '% ms -> LNP. Query failed',EXTRACT(MILLISECOND from v_end-v_start);
          /*}dbg*/
          if v_drop_call_if_lnp_fail then
            /*dbg{*/
            v_end:=clock_timestamp();
            RAISE NOTICE '% ms -> LNP. Dropping call',EXTRACT(MILLISECOND from v_end-v_start);
            /*}dbg*/
            v_ret.disconnect_code_id=8003; --No response from LNP DB
            RETURN NEXT v_ret;
            RETURN;
          end if;
        else
          /*dbg{*/
          v_end:=clock_timestamp();
          RAISE NOTICE '% ms -> LNP. Success, lrn: %',EXTRACT(MILLISECOND from v_end-v_start),v_ret.lrn;
          /*}dbg*/
          -- TRANSLATING response from LNP DB
          v_ret.lrn=yeti_ext.regexp_replace_rand(v_ret.lrn,v_lnp_rule.lrn_rewrite_rule,v_lnp_rule.lrn_rewrite_result);
          /*dbg{*/
          v_end:=clock_timestamp();
          RAISE NOTICE '% ms -> LNP. Translation. lrn: %',EXTRACT(MILLISECOND from v_end-v_start),v_ret.lrn;
          /*}dbg*/
          v_routing_key=v_ret.lrn;
        end if;
      end if;
    end if;
  end if;


  /*dbg{*/
  v_end:=clock_timestamp();
  RAISE NOTICE '% ms -> DST. search start. Routing key: %',EXTRACT(MILLISECOND from v_end-v_start), v_routing_key;
  /*}dbg*/
  v_network:=switch10.detect_network(v_ret.dst_prefix_routing);
  v_ret.dst_network_id=v_network.network_id;
  v_ret.dst_country_id=v_network.country_id;

  SELECT into v_destination d.*/*,switch.tracelog(d.*)*/ from class4.destinations d
  WHERE
    prefix_range(prefix)@>prefix_range(v_routing_key)
    AND rateplan_id=v_customer_auth.rateplan_id
    AND enabled
    AND valid_from <= v_now
    AND valid_till >= v_now
  ORDER BY length(prefix_range(prefix)) DESC limit 1;
  IF NOT FOUND THEN
    /*dbg{*/
    v_end:=clock_timestamp();
    RAISE NOTICE '% ms -> DST.  Destination not found',EXTRACT(MILLISECOND from v_end-v_start);
    /*}dbg*/
    v_ret.disconnect_code_id=111; --Cant find destination prefix
    RETURN NEXT v_ret;
    RETURN;
  END IF;
  /*dbg{*/
  v_end:=clock_timestamp();
  RAISE NOTICE '% ms -> DST. found: %',EXTRACT(MILLISECOND from v_end-v_start),row_to_json(v_destination, true);
  /*}dbg*/

  v_ret.destination_id:=v_destination.id;
  v_ret.destination_prefix=v_destination.prefix;
  v_ret.destination_initial_interval:=v_destination.initial_interval;
  v_ret.destination_fee:=v_destination.connect_fee::varchar;
  v_ret.destination_next_interval:=v_destination.next_interval;
  v_ret.destination_rate_policy_id:=v_destination.rate_policy_id;
  IF v_destination.reject_calls THEN
    v_ret.disconnect_code_id=112; --Rejected by destination
    RETURN NEXT v_ret;
    RETURN;
  END IF;
  select into v_rateplan * from class4.rateplans where id=v_customer_auth.rateplan_id;
  if COALESCE(v_destination.profit_control_mode_id,v_rateplan.profit_control_mode_id)=2 then -- per call
    v_rate_limit=v_destination.next_rate::float;
  end if;


  /*
              FIND dialpeers logic. Queries must use prefix index for best performance
  */
  /*dbg{*/
  v_end:=clock_timestamp();
  RAISE NOTICE '% ms -> DP. search start. Routing key: %. Rate limit: %',EXTRACT(MILLISECOND from v_end-v_start), v_routing_key, v_rate_limit;
  /*}dbg*/
  CASE v_rp.sorting_id
    WHEN'1' THEN -- LCR,Prio, ACD&ASR control
    FOR routedata IN (
      WITH step1 AS(
          SELECT
            (t_dp.*)::class4.dialpeers as s1_dialpeer,
            (t_vendor_account.*)::billing.accounts as s1_vendor_account,
            t_dp.next_rate as dp_next_rate,
            t_dp.lcr_rate_multiplier AS dp_lcr_rate_multiplier,
            t_dp.priority AS dp_priority,
            t_dp.locked as dp_locked,
            t_dp.enabled as dp_enabled,
            rank() OVER (
              PARTITION BY t_dp.vendor_id
              ORDER BY length(t_dp.prefix) desc
            ) as r,
            rank() OVER (
              ORDER BY t_dp.exclusive_route desc -- force top rank for exclusive route
            ) as exclusive_rank
          FROM class4.dialpeers t_dp
            JOIN billing.accounts t_vendor_account ON t_dp.account_id = t_vendor_account.id
            JOIN class4.routing_plan_groups t_rpg ON t_dp.routing_group_id=t_rpg.routing_group_id
          WHERE
            prefix_range(t_dp.prefix)@>prefix_range(v_routing_key)
            AND t_rpg.routing_plan_id=v_customer_auth.routing_plan_id
            and t_dp.valid_from<=v_now
            and t_dp.valid_till>=v_now
            AND t_vendor_account.balance<t_vendor_account.max_balance
      )
      SELECT s1_dialpeer as s2_dialpeer,
             s1_vendor_account as s2_vendor_account
      from step1
      WHERE
        r=1
        and exclusive_rank=1
        AND dp_next_rate<v_rate_limit
        AND dp_enabled
        and not dp_locked --ACD&ASR control for DP
      ORDER BY dp_next_rate*dp_lcr_rate_multiplier, dp_priority DESC limit 10
    ) LOOP
      RETURN QUERY
      /*rel{*/SELECT * from process_dp_release(v_ret,v_destination,routedata.s2_dialpeer,v_c_acc,v_orig_gw,routedata.s2_vendor_account,i_pop_id,v_customer_auth.send_billing_information,v_max_call_length);/*}rel*/
      /*dbg{*/SELECT * from process_dp_debug(v_ret,v_destination,routedata.s2_dialpeer,v_c_acc,v_orig_gw,routedata.s2_vendor_account,i_pop_id,v_customer_auth.send_billing_information,v_max_call_length);/*}dbg*/
    end LOOP;
    WHEN '2' THEN --LCR, no prio, No ACD&ASR control
    FOR routedata IN (
      WITH step1 AS( -- filtering
          SELECT
            (t_dp.*)::class4.dialpeers as s1_dialpeer,
            --  (t_vendor_gateway.*)::class4.gateways as s1_vendor_gateway,
            (t_vendor_account.*)::billing.accounts as s1_vendor_account,
            rank() OVER (
              PARTITION BY t_dp.vendor_id
              ORDER BY length(t_dp.prefix) desc
            ) as r,
            rank() OVER (
              ORDER BY t_dp.exclusive_route desc -- force top rank for exclusive route
            ) as exclusive_rank,
            t_dp.next_rate*t_dp.lcr_rate_multiplier as dp_metric,
            t_dp.next_rate as dp_next_rate,
            t_dp.enabled as dp_enabled
          FROM class4.dialpeers t_dp
            JOIN billing.accounts t_vendor_account ON t_dp.account_id=t_vendor_account.id
            JOIN class4.routing_plan_groups t_rpg ON t_dp.routing_group_id=t_rpg.routing_group_id
          WHERE
            prefix_range(t_dp.prefix)@>prefix_range(v_routing_key)
            AND t_rpg.routing_plan_id=v_customer_auth.routing_plan_id
            and t_dp.valid_from<=v_now
            and t_dp.valid_till>=v_now
            AND t_vendor_account.balance<t_vendor_account.max_balance
      )
      SELECT s1_dialpeer as s2_dialpeer,
             s1_vendor_account as s2_vendor_account
      FROM step1
      WHERE
        r=1
        and exclusive_rank=1
        AND dp_enabled
        and dp_next_rate<v_rate_limit
      ORDER BY dp_metric limit 10
    ) LOOP
      RETURN QUERY
      /*rel{*/SELECT * from process_dp_release(v_ret,v_destination,routedata.s2_dialpeer,v_c_acc,v_orig_gw,routedata.s2_vendor_account,i_pop_id,v_customer_auth.send_billing_information,v_max_call_length);/*}rel*/
      /*dbg{*/SELECT * from process_dp_debug(v_ret,v_destination,routedata.s2_dialpeer,v_c_acc,v_orig_gw,routedata.s2_vendor_account,i_pop_id,v_customer_auth.send_billing_information,v_max_call_length);/*}dbg*/
    END LOOP;
    WHEN '3' THEN --Prio, LCR, ACD&ASR control
    FOR routedata in(
      WITH step1 AS( -- filtering
          SELECT
            (t_dp.*)::class4.dialpeers as s1_dialpeer,
            (t_vendor_account.*)::billing.accounts as s1_vendor_account,
            rank() OVER (
              PARTITION BY t_dp.vendor_id
              ORDER BY length(t_dp.prefix) desc
            ) as r,
            rank() OVER (
              ORDER BY t_dp.exclusive_route desc -- force top rank for exclusive route
            ) as exclusive_rank,
            t_dp.priority as dp_metric_priority,
            t_dp.next_rate*t_dp.lcr_rate_multiplier as dp_metric,
            t_dp.next_rate as dp_next_rate,
            t_dp.locked as dp_locked,
            t_dp.enabled as dp_enabled
          FROM class4.dialpeers t_dp
            JOIN billing.accounts t_vendor_account ON t_dp.account_id=t_vendor_account.id
            JOIN class4.routing_plan_groups t_rpg ON t_dp.routing_group_id=t_rpg.routing_group_id
          WHERE
            prefix_range(t_dp.prefix)@>prefix_range(v_routing_key)
            AND t_rpg.routing_plan_id=v_customer_auth.routing_plan_id
            and t_dp.valid_from<=v_now
            and t_dp.valid_till>=v_now
            AND t_vendor_account.balance<t_vendor_account.max_balance
      )
      SELECT s1_dialpeer as s2_dialpeer,
             s1_vendor_account as s2_vendor_account
      FROM step1
      WHERE
        r=1
        and exclusive_rank=1
        and dp_next_rate<v_rate_limit
        and dp_enabled
        and not dp_locked
      ORDER BY dp_metric_priority DESC, dp_metric limit 10
    )LOOP
      RETURN QUERY
      /*rel{*/SELECT * from process_dp_release(v_ret,v_destination,routedata.s2_dialpeer,v_c_acc,v_orig_gw,routedata.s2_vendor_account,i_pop_id,v_customer_auth.send_billing_information,v_max_call_length);/*}rel*/
      /*dbg{*/SELECT * from process_dp_debug(v_ret,v_destination,routedata.s2_dialpeer,v_c_acc,v_orig_gw,routedata.s2_vendor_account,i_pop_id,v_customer_auth.send_billing_information,v_max_call_length);/*}dbg*/
    END LOOP;
    WHEN'4' THEN -- LCRD, Prio, ACD&ACR control
    FOR routedata IN (
      WITH step1 AS(
          SELECT
            (t_dp.*)::class4.dialpeers as s1_dialpeer,
            (t_vendor_account.*)::billing.accounts as s1_vendor_account,
            rank() OVER (
              PARTITION BY t_dp.vendor_id
              ORDER BY length(t_dp.prefix) desc
            ) as r,
            rank() OVER (
              ORDER BY t_dp.exclusive_route desc -- force top rank for exclusive route
            ) as exclusive_rank,
            ((t_dp.next_rate - first_value(t_dp.next_rate) OVER(ORDER BY t_dp.next_rate ASC)) > v_rp.rate_delta_max)::INTEGER *(t_dp.next_rate + t_dp.priority) - t_dp.priority AS r2,
            t_dp.next_rate as dp_next_rate,
            t_dp.locked as dp_locked,
            t_dp.enabled as dp_enabled
          FROM class4.dialpeers t_dp
            JOIN billing.accounts t_vendor_account ON t_dp.account_id = t_vendor_account.id
            JOIN class4.routing_plan_groups t_rpg ON t_dp.routing_group_id=t_rpg.routing_group_id
          WHERE
            prefix_range(t_dp.prefix)@>prefix_range(v_routing_key)
            AND t_rpg.routing_plan_id=v_customer_auth.routing_plan_id
            and t_dp.valid_from<=v_now
            and t_dp.valid_till>=v_now
            AND t_vendor_account.balance<t_vendor_account.max_balance
      )
      SELECT s1_dialpeer as s2_dialpeer,
             s1_vendor_account as s2_vendor_account
      from step1
      WHERE
        r=1
        and exclusive_rank=1
        and dp_next_rate < v_rate_limit
        and dp_enabled
        and not dp_locked --ACD&ASR control for DP
      ORDER BY r2 ASC limit 10
    ) LOOP
      RETURN QUERY
      /*rel{*/SELECT * from process_dp_release(v_ret,v_destination,routedata.s2_dialpeer,v_c_acc,v_orig_gw,routedata.s2_vendor_account,i_pop_id,v_customer_auth.send_billing_information,v_max_call_length);/*}rel*/
      /*dbg{*/SELECT * from process_dp_debug(v_ret,v_destination,routedata.s2_dialpeer,v_c_acc,v_orig_gw,routedata.s2_vendor_account,i_pop_id,v_customer_auth.send_billing_information,v_max_call_length);/*}dbg*/
    end LOOP;
    WHEN'5' THEN -- Route test
    v_test_vendor_id=regexp_replace(v_routing_key,'(.*)\*(.*)','\1')::integer;
    v_routing_key=regexp_replace(v_routing_key,'(.*)\*(.*)','\2');
    v_ret.dst_prefix_out=v_routing_key;
    -- cheat( Prefix changed by regexp, we need recalculate destination)
    v_network:=switch10.detect_network(v_routing_key);
    v_ret.dst_network_id=v_network.network_id;
    v_ret.dst_country_id=v_network.country_id;
    FOR routedata IN (
      WITH step1 AS( -- filtering
          SELECT
            (t_dp.*)::class4.dialpeers as s1_dialpeer,
            (t_vendor_account.*)::billing.accounts as s1_vendor_account,
            rank() OVER (
              PARTITION BY t_dp.vendor_id
              ORDER BY length(t_dp.prefix) desc
            ) as r,
            rank() OVER (
              ORDER BY t_dp.exclusive_route desc -- force top rank for exclusive route
            ) as exclusive_rank,
            t_dp.priority as dp_metric_priority,
            t_dp.next_rate*t_dp.lcr_rate_multiplier as dp_metric,
            t_dp.next_rate as dp_next_rate,
            t_dp.enabled as dp_enabled
          FROM class4.dialpeers t_dp
            JOIN billing.accounts t_vendor_account ON t_dp.account_id=t_vendor_account.id
            JOIN class4.routing_plan_groups t_rpg ON t_dp.routing_group_id=t_rpg.routing_group_id
          WHERE
            prefix_range(t_dp.prefix)@>prefix_range(v_routing_key)
            AND t_rpg.routing_plan_id=v_customer_auth.routing_plan_id
            and t_dp.valid_from<=v_now
            and t_dp.valid_till>=v_now
            AND t_vendor_account.balance<t_vendor_account.max_balance
            and t_dp.vendor_id=v_test_vendor_id
      )
      SELECT s1_dialpeer as s2_dialpeer,
             s1_vendor_account as s2_vendor_account
      FROM step1
      WHERE
        r=1
        and exclusive_rank=1
        and dp_enabled
        and dp_next_rate<v_rate_limit
      ORDER BY dp_metric_priority DESC, dp_metric limit 10
    )LOOP
      RETURN QUERY
      /*rel{*/SELECT * from process_dp_release(v_ret,v_destination,routedata.s2_dialpeer,v_c_acc,v_orig_gw,routedata.s2_vendor_account,i_pop_id,v_customer_auth.send_billing_information,v_max_call_length);/*}rel*/
      /*dbg{*/SELECT * from process_dp_debug(v_ret,v_destination,routedata.s2_dialpeer,v_c_acc,v_orig_gw,routedata.s2_vendor_account,i_pop_id,v_customer_auth.send_billing_information,v_max_call_length);/*}dbg*/
    END LOOP;
    WHEN'6' THEN -- QD.Static,LCR,ACD&ACR control
    v_random:=random();
    FOR routedata in(
      WITH step1 AS( -- filtering
          SELECT
            (t_dp.*)::class4.dialpeers as s1_dialpeer,
            (t_vendor_account.*)::billing.accounts as s1_vendor_account,
            rank() OVER (
              PARTITION BY t_dp.vendor_id
              ORDER BY length(t_dp.prefix) desc
            ) as r,
            rank() OVER (
              ORDER BY t_dp.exclusive_route desc -- force top rank for exclusive route
            ) as exclusive_rank,
            rank() OVER (PARTITION BY t_dp.vendor_id ORDER BY length(coalesce(rpsr.prefix,'')) desc) as r2,
            t_dp.priority as dp_metric_priority,
            t_dp.next_rate*t_dp.lcr_rate_multiplier as dp_metric,
            t_dp.next_rate as dp_next_rate,
            t_dp.locked as dp_locked,
            t_dp.enabled as dp_enabled,
            t_dp.force_hit_rate as dp_force_hit_rate,
            rpsr.priority as rpsr_priority
          FROM class4.dialpeers t_dp
            JOIN billing.accounts t_vendor_account ON t_dp.account_id=t_vendor_account.id
            JOIN class4.routing_plan_groups t_rpg ON t_dp.routing_group_id=t_rpg.routing_group_id
            left join class4.routing_plan_static_routes rpsr
              ON rpsr.routing_plan_id=v_customer_auth.routing_plan_id
                 and rpsr.vendor_id=t_dp.vendor_id
                 AND prefix_range(rpsr.prefix)@>prefix_range(v_routing_key)
          WHERE
            prefix_range(t_dp.prefix)@>prefix_range(v_routing_key)
            AND t_rpg.routing_plan_id=v_customer_auth.routing_plan_id
            and t_dp.valid_from<=v_now
            and t_dp.valid_till>=v_now
            AND t_vendor_account.balance<t_vendor_account.max_balance
      )
      SELECT s1_dialpeer as s2_dialpeer,
             s1_vendor_account as s2_vendor_account
      FROM step1
      WHERE
        r=1
        and exclusive_rank=1
        and r2=1
        and dp_next_rate<v_rate_limit
        and dp_enabled
        and not dp_locked
      ORDER BY coalesce(v_random<=dp_force_hit_rate,false) desc, coalesce(rpsr_priority,0) DESC, dp_metric limit 10
    )LOOP
      RETURN QUERY
      /*rel{*/SELECT * from process_dp_release(v_ret,v_destination,routedata.s2_dialpeer,v_c_acc,v_orig_gw,routedata.s2_vendor_account,i_pop_id,v_customer_auth.send_billing_information,v_max_call_length);/*}rel*/
      /*dbg{*/SELECT * from process_dp_debug(v_ret,v_destination,routedata.s2_dialpeer,v_c_acc,v_orig_gw,routedata.s2_vendor_account,i_pop_id,v_customer_auth.send_billing_information,v_max_call_length);/*}dbg*/
    END LOOP;
    WHEN'7' THEN -- QD.Static, No ACD&ACR control
    v_random:=random();
    FOR routedata in(
      WITH step1 AS( -- filtering
          SELECT
            (t_dp.*)::class4.dialpeers as s1_dialpeer,
            (t_vendor_account.*)::billing.accounts as s1_vendor_account,
            rank() OVER (
              PARTITION BY t_dp.vendor_id
              ORDER BY length(t_dp.prefix) desc
            ) as r,
            rank() OVER (
              ORDER BY t_dp.exclusive_routet desc -- force top rank for exclusive route
            ) as exclusive_rank,
            rank() OVER (PARTITION BY t_dp.vendor_id ORDER BY length(coalesce(rpsr.prefix,'')) desc) as r2,
            t_dp.priority as dp_metric_priority,
            t_dp.next_rate*t_dp.lcr_rate_multiplier as dp_metric,
            t_dp.next_rate as dp_next_rate,
            t_dp.enabled as dp_enabled,
            t_dp.force_hit_rate as dp_force_hit_rate,
            rpsr.priority as rpsr_priority
          FROM class4.dialpeers t_dp
            JOIN billing.accounts t_vendor_account ON t_dp.account_id=t_vendor_account.id
            JOIN class4.routing_plan_groups t_rpg ON t_dp.routing_group_id=t_rpg.routing_group_id
            join class4.routing_plan_static_routes rpsr
              ON rpsr.routing_plan_id=v_customer_auth.routing_plan_id
                 and rpsr.vendor_id=t_dp.vendor_id
                 AND prefix_range(rpsr.prefix)@>prefix_range(v_routing_key)
          WHERE
            prefix_range(t_dp.prefix)@>prefix_range(v_routing_key)
            AND t_rpg.routing_plan_id=v_customer_auth.routing_plan_id
            and t_dp.valid_from<=v_now
            and t_dp.valid_till>=v_now
            AND t_vendor_account.balance<t_vendor_account.max_balance
      )
      SELECT s1_dialpeer as s2_dialpeer,
             s1_vendor_account as s2_vendor_account
      FROM step1
      WHERE
        r=1
        and exclusive_rank=1
        and r2=1
        and dp_next_rate<v_rate_limit
        and dp_enabled
      ORDER BY coalesce(v_random<=dp_force_hit_rate,false) desc, rpsr_priority DESC, dp_metric limit 10
    )LOOP
      RETURN QUERY
      /*rel{*/SELECT * from process_dp_release(v_ret,v_destination,routedata.s2_dialpeer,v_c_acc,v_orig_gw,routedata.s2_vendor_account,i_pop_id,v_customer_auth.send_billing_information,v_max_call_length);/*}rel*/
      /*dbg{*/SELECT * from process_dp_debug(v_ret,v_destination,routedata.s2_dialpeer,v_c_acc,v_orig_gw,routedata.s2_vendor_account,i_pop_id,v_customer_auth.send_billing_information,v_max_call_length);/*}dbg*/
    END LOOP;

  ELSE
    RAISE NOTICE 'BUG: unknown sorting_id';
  END CASE;
  /*dbg{*/
  v_end:=clock_timestamp();
  RAISE NOTICE '% ms -> Dialpeer search done',EXTRACT(MILLISECOND from v_end-v_start);
  /*}dbg*/
  v_ret.disconnect_code_id=113; --No routes
  RETURN NEXT v_ret;
  /*dbg{*/
  v_end:=clock_timestamp();
  RAISE NOTICE '% ms -> DONE.',EXTRACT(MILLISECOND from v_end-v_start);
  /*}dbg*/
  RETURN;
END;
$BODY$
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
COST 100
ROWS 10;


CREATE OR REPLACE FUNCTION switch10.process_dp(
  i_profile switch10.callprofile50_ty,
  i_destination class4.destinations,
  i_dp class4.dialpeers,
  i_customer_acc billing.accounts,
  i_customer_gw class4.gateways,
  i_vendor_acc billing.accounts,
  i_pop_id integer,
  i_send_billing_information boolean,
  i_max_call_length integer)
  RETURNS SETOF switch10.callprofile50_ty AS
$BODY$
DECLARE
  /*dbg{*/
  v_start timestamp;
  v_end timestamp;
  /*}dbg*/
  v_gw class4.gateways%rowtype;
BEGIN
  /*dbg{*/
  v_start:=now();
  --RAISE NOTICE 'process_dp in: %',i_profile;5
  v_end:=clock_timestamp();
  RAISE NOTICE '% ms -> process-DP. Found dialpeer: %',EXTRACT(MILLISECOND from v_end-v_start),row_to_json(i_dp,true);
  /*}dbg*/

  --RAISE NOTICE 'process_dp dst: %',i_destination;
  if i_dp.gateway_id is null then
    PERFORM id from class4.gateway_groups where id=i_dp.gateway_group_id and prefer_same_pop;
    IF FOUND THEN
      /*rel{*/
      FOr v_gw in  select * from class4.gateways cg where cg.gateway_group_id=i_dp.gateway_group_id and cg.enabled ORDER BY cg.pop_id=i_pop_id desc,cg.priority desc LOOP
        return query select * from process_gw_release(i_profile, i_destination, i_dp, i_customer_acc,
                                                      i_customer_gw, i_vendor_acc , v_gw, i_send_billing_information,i_max_call_length);
      end loop;
      /*}rel*/
      /*dbg{*/
      FOr v_gw in  select * from class4.gateways cg where cg.gateway_group_id=i_dp.gateway_group_id and cg.enabled ORDER BY cg.pop_id=i_pop_id desc,cg.priority desc LOOP
        return query select * from process_gw_debug(i_profile, i_destination, i_dp, i_customer_acc,
                                                    i_customer_gw, i_vendor_acc , v_gw, i_send_billing_information,i_max_call_length);
      end loop;
      /*}dbg*/
    else
      /*rel{*/
      FOr v_gw in  select * from class4.gateways cg where cg.gateway_group_id=i_dp.gateway_group_id and cg.enabled ORDER BY cg.priority desc LOOP
        return query select * from process_gw_release(i_profile, i_destination, i_dp, i_customer_acc,
                                                      i_customer_gw, i_vendor_acc , v_gw, i_send_billing_information,i_max_call_length);
      end loop;
      /*}rel*/
      /*dbg{*/
      FOr v_gw in  select * from class4.gateways cg where cg.gateway_group_id=i_dp.gateway_group_id and cg.enabled ORDER BY cg.priority desc LOOP
        return query select * from process_gw_debug(i_profile, i_destination, i_dp, i_customer_acc,
                                                    i_customer_gw, i_vendor_acc , v_gw, i_send_billing_information,i_max_call_length);
      end loop;
      /*}dbg*/
    end if;
  else
    select into v_gw * from class4.gateways cg where cg.id=i_dp.gateway_id and cg.enabled;
    if FOUND THEN
      /*rel{*/
      return query select * from
        process_gw_release(i_profile, i_destination, i_dp, i_customer_acc,i_customer_gw, i_vendor_acc, v_gw, i_send_billing_information,i_max_call_length);
      /*}rel*/
      /*dbg{*/
      return query select * from
        process_gw_debug(i_profile, i_destination, i_dp, i_customer_acc,i_customer_gw, i_vendor_acc, v_gw, i_send_billing_information,i_max_call_length);
      /*}dbg*/
    else
      return;
    end if;
  end if;
END;
$BODY$
LANGUAGE plpgsql STABLE SECURITY DEFINER
COST 10000
ROWS 1000;


CREATE OR REPLACE FUNCTION switch10.process_gw(
  i_profile switch10.callprofile50_ty,
  i_destination class4.destinations,
  i_dp class4.dialpeers,
  i_customer_acc billing.accounts,
  i_customer_gw class4.gateways,
  i_vendor_acc billing.accounts,
  i_vendor_gw class4.gateways,
  i_send_billing_information boolean,
  i_max_call_length integer)
  RETURNS switch10.callprofile50_ty AS
$BODY$
DECLARE
  i integer;
  v_customer_allowtime real;
  v_vendor_allowtime real;
  v_route_found boolean:=false;
  /*dbg{*/
  v_start timestamp;
  v_end timestamp;
  /*}dbg*/
BEGIN
  /*dbg{*/
  v_start:=now();
  --RAISE NOTICE 'process_dp in: %',i_profile;
  v_end:=clock_timestamp();
  RAISE NOTICE '% ms -> DP. Found dialpeer: %',EXTRACT(MILLISECOND from v_end-v_start),row_to_json(i_dp,true);
  /*}dbg*/

  --RAISE NOTICE 'process_dp dst: %',i_destination;

  i_profile.destination_id:=i_destination.id;
  --    i_profile.destination_initial_interval:=i_destination.initial_interval;
  i_profile.destination_fee:=i_destination.connect_fee::varchar;
  --i_profile.destination_next_interval:=i_destination.next_interval;
  i_profile.destination_rate_policy_id:=i_destination.rate_policy_id;

  --vendor account capacity limit;
  if i_vendor_acc.termination_capacity is not null then
    i_profile.resources:=i_profile.resources||'2:'||i_dp.account_id::varchar||':'||i_vendor_acc.termination_capacity::varchar||':1;';
  end if;

  -- dialpeer account capacity limit;
  if i_dp.capacity is not null then
    i_profile.resources:=i_profile.resources||'6:'||i_dp.id::varchar||':'||i_dp.capacity::varchar||':1;';
  end if;

  /* */
  i_profile.dialpeer_id=i_dp.id;
  i_profile.dialpeer_prefix=i_dp.prefix;
  i_profile.dialpeer_next_rate=i_dp.next_rate::varchar;
  i_profile.dialpeer_initial_rate=i_dp.initial_rate::varchar;
  i_profile.dialpeer_initial_interval=i_dp.initial_interval;
  i_profile.dialpeer_next_interval=i_dp.next_interval;
  i_profile.dialpeer_fee=i_dp.connect_fee::varchar;
  i_profile.vendor_id=i_dp.vendor_id;
  i_profile.vendor_acc_id=i_dp.account_id;
  i_profile.term_gw_id=i_vendor_gw.id;

  i_profile.orig_gw_name=i_customer_gw."name";
  i_profile.orig_gw_external_id=i_customer_gw.external_id;

  i_profile.term_gw_name=i_vendor_gw."name";
  i_profile.term_gw_external_id=i_vendor_gw.external_id;

  i_profile.customer_account_name=i_customer_acc."name";

  i_profile.routing_group_id:=i_dp.routing_group_id;

  if i_send_billing_information then
    i_profile.aleg_append_headers_reply=E'X-VND-INIT-INT:'||i_profile.dialpeer_initial_interval||E'\r\nX-VND-NEXT-INT:'||i_profile.dialpeer_next_interval||E'\r\nX-VND-INIT-RATE:'||i_profile.dialpeer_initial_rate||E'\r\nX-VND-NEXT-RATE:'||i_profile.dialpeer_next_rate||E'\r\nX-VND-CF:'||i_profile.dialpeer_fee;
  end if;

  if i_destination.use_dp_intervals THEN
    i_profile.destination_initial_interval:=i_dp.initial_interval;
    i_profile.destination_next_interval:=i_dp.next_interval;
  ELSE
    i_profile.destination_initial_interval:=i_destination.initial_interval;
    i_profile.destination_next_interval:=i_destination.next_interval;
  end if;

  CASE i_profile.destination_rate_policy_id
    WHEN 1 THEN -- fixed
    i_profile.destination_next_rate:=i_destination.next_rate::varchar;
    i_profile.destination_initial_rate:=i_destination.initial_rate::varchar;
    WHEN 2 THEN -- based on dialpeer
    i_profile.destination_next_rate:=(COALESCE(i_destination.dp_margin_fixed,0)+i_dp.next_rate*(1+COALESCE(i_destination.dp_margin_percent,0)))::varchar;
    i_profile.destination_initial_rate:=(COALESCE(i_destination.dp_margin_fixed,0)+i_dp.initial_rate*(1+COALESCE(i_destination.dp_margin_percent,0)))::varchar;
    WHEN 3 THEN -- min
    IF i_dp.next_rate >= i_destination.next_rate THEN
      i_profile.destination_next_rate:=i_destination.next_rate::varchar; -- FIXED least
      i_profile.destination_initial_rate:=i_destination.initial_rate::varchar;
    ELSE
      i_profile.destination_next_rate:=(COALESCE(i_destination.dp_margin_fixed,0)+i_dp.next_rate*(1+COALESCE(i_destination.dp_margin_percent,0)))::varchar; -- DYNAMIC
      i_profile.destination_initial_rate:=(COALESCE(i_destination.dp_margin_fixed,0)+i_dp.initial_rate*(1+COALESCE(i_destination.dp_margin_percent,0)))::varchar;
    END IF;
    WHEN 4 THEN -- max
    IF i_dp.next_rate < i_destination.next_rate THEN
      i_profile.destination_next_rate:=i_destination.next_rate::varchar; --FIXED
      i_profile.destination_initial_rate:=i_destination.initial_rate::varchar;
    ELSE
      i_profile.destination_next_rate:=(COALESCE(i_destination.dp_margin_fixed,0)+i_dp.next_rate*(1+COALESCE(i_destination.dp_margin_percent,0)))::varchar; -- DYNAMIC
      i_profile.destination_initial_rate:=(COALESCE(i_destination.dp_margin_fixed,0)+i_dp.initial_rate*(1+COALESCE(i_destination.dp_margin_percent,0)))::varchar;
    END IF;
  ELSE
  --
  end case;



  /* time limiting START */
  --SELECT INTO STRICT v_c_acc * FROM billing.accounts  WHERE id=v_customer_auth.account_id;
  --SELECT INTO STRICT v_v_acc * FROM billing.accounts  WHERE id=v_dialpeer.account_id;

  IF (i_customer_acc.balance-i_customer_acc.min_balance)-i_destination.connect_fee <0 THEN
    v_customer_allowtime:=0;
    i_profile.disconnect_code_id=8000; --Not enough customer balance
    RETURN i_profile;
  ELSIF (i_customer_acc.balance-i_customer_acc.min_balance)-i_destination.connect_fee-i_destination.initial_rate/60*i_destination.initial_interval<0 THEN
    v_customer_allowtime:=i_destination.initial_interval;
    i_profile.disconnect_code_id=8000; --Not enough customer balance
    RETURN i_profile;
  ELSIF i_destination.next_rate!=0 AND i_destination.next_interval!=0 THEN
    v_customer_allowtime:=i_destination.initial_interval+
                          LEAST(FLOOR(((i_customer_acc.balance-i_customer_acc.min_balance)-i_destination.connect_fee-i_destination.initial_rate/60*i_destination.initial_interval)/
                                      (i_destination.next_rate/60*i_destination.next_interval)),24e6)::integer*i_destination.next_interval;
  ELSE
    v_customer_allowtime:=i_max_call_length;
  end IF;

  IF (i_vendor_acc.max_balance-i_vendor_acc.balance)-i_dp.connect_fee <0 THEN
    v_vendor_allowtime:=0;
    return null;
  ELSIF (i_vendor_acc.max_balance-i_vendor_acc.balance)-i_dp.connect_fee-i_dp.initial_rate/60*i_dp.initial_interval<0 THEN
    return null;
  ELSIF i_dp.next_rate!=0 AND i_dp.next_interval!=0 THEN
    v_vendor_allowtime:=i_dp.initial_interval+
                        LEAST(FLOOR(((i_vendor_acc.max_balance-i_vendor_acc.balance)-i_dp.connect_fee-i_dp.initial_rate/60*i_dp.initial_interval)/
                                    (i_dp.next_rate/60*i_dp.next_interval)),24e6)::integer*i_dp.next_interval;
  ELSE
    v_vendor_allowtime:=i_max_call_length;
  end IF;

  i_profile.time_limit=LEAST(v_vendor_allowtime,v_customer_allowtime,i_max_call_length)::integer;
  /* time limiting END */


  /* number rewriting _After_ routing */
  /*dbg{*/
  v_end:=clock_timestamp();
  RAISE NOTICE '% ms -> DP. Before rewrite src_prefix: % , dst_prefix: %',EXTRACT(MILLISECOND from v_end-v_start),i_profile.src_prefix_out,i_profile.dst_prefix_out;
  /*}dbg*/
  i_profile.dst_prefix_out=yeti_ext.regexp_replace_rand(i_profile.dst_prefix_out,i_dp.dst_rewrite_rule,i_dp.dst_rewrite_result);
  i_profile.src_prefix_out=yeti_ext.regexp_replace_rand(i_profile.src_prefix_out,i_dp.src_rewrite_rule,i_dp.src_rewrite_result);
  i_profile.src_name_out=yeti_ext.regexp_replace_rand(i_profile.src_name_out,i_dp.src_name_rewrite_rule,i_dp.src_name_rewrite_result);

  /*dbg{*/
  v_end:=clock_timestamp();
  RAISE NOTICE '% ms -> DP. After rewrite src_prefix: % , dst_prefix: %',EXTRACT(MILLISECOND from v_end-v_start),i_profile.src_prefix_out,i_profile.dst_prefix_out;
  /*}dbg*/

  /*
      get termination gw data
  */
  --SELECT into v_dst_gw * from class4.gateways WHERE id=v_dialpeer.gateway_id;
  --SELECT into v_orig_gw * from class4.gateways WHERE id=v_customer_auth.gateway_id;
  --vendor gw
  if i_vendor_gw.termination_capacity is not null then
    i_profile.resources:=i_profile.resources||'5:'||i_vendor_gw.id::varchar||':'||i_vendor_gw.termination_capacity::varchar||':1;';
  end if;

  /*
      number rewriting _After_ routing _IN_ termination GW
  */
  /*dbg{*/
  v_end:=clock_timestamp();
  RAISE NOTICE '% ms -> GW. Before rewrite src_prefix: % , dst_prefix: %',EXTRACT(MILLISECOND from v_end-v_start),i_profile.src_prefix_out,i_profile.dst_prefix_out;
  /*}dbg*/
  i_profile.dst_prefix_out=yeti_ext.regexp_replace_rand(i_profile.dst_prefix_out,i_vendor_gw.dst_rewrite_rule,i_vendor_gw.dst_rewrite_result);
  i_profile.src_prefix_out=yeti_ext.regexp_replace_rand(i_profile.src_prefix_out,i_vendor_gw.src_rewrite_rule,i_vendor_gw.src_rewrite_result);
  i_profile.src_name_out=yeti_ext.regexp_replace_rand(i_profile.src_name_out,i_vendor_gw.src_name_rewrite_rule,i_vendor_gw.src_name_rewrite_result);

  /*dbg{*/
  v_end:=clock_timestamp();
  RAISE NOTICE '% ms -> GW. After rewrite src_prefix: % , dst_prefix: %',EXTRACT(MILLISECOND from v_end-v_start),i_profile.src_prefix_out,i_profile.dst_prefix_out;
  /*}dbg*/

  i_profile.anonymize_sdp:=i_vendor_gw.anonymize_sdp OR i_customer_gw.anonymize_sdp;

  --i_profile.append_headers:='User-Agent: YETI SBC\r\n';
  i_profile.append_headers_req:=i_vendor_gw.term_append_headers_req;
  i_profile.aleg_append_headers_req=i_customer_gw.orig_append_headers_req;

  i_profile.enable_auth:=i_vendor_gw.auth_enabled;
  i_profile.auth_pwd:=i_vendor_gw.auth_password;
  i_profile.auth_user:=i_vendor_gw.auth_user;
  i_profile.enable_aleg_auth:=false;
  i_profile.auth_aleg_pwd:='';
  i_profile.auth_aleg_user:='';

  i_profile.next_hop_1st_req=i_vendor_gw.auth_enabled; -- use low delay dns srv if auth enabled
  i_profile.next_hop:=i_vendor_gw.term_next_hop;
  i_profile.aleg_next_hop:=i_customer_gw.orig_next_hop;
  --    i_profile.next_hop_for_replies:=v_dst_gw.term_next_hop_for_replies;

  i_profile.dlg_nat_handling=i_customer_gw.dialog_nat_handling;
  i_profile.transparent_dlg_id=i_customer_gw.transparent_dialog_id;

  i_profile.call_id:=''; -- Generation by sems

  --i_profile."from":='$f';
  --i_profile."from":='<sip:'||i_profile.src_prefix_out||'@46.19.209.45>';
  i_profile."from":=COALESCE(i_profile.src_name_out||' ','')||'<sip:'||i_profile.src_prefix_out||'@$Oi>';

  i_profile."to":='<sip:'||i_profile.dst_prefix_out||'@'||i_vendor_gw.host::varchar||COALESCE(':'||i_vendor_gw.port||'>','>');

  if i_vendor_gw.send_lnp_information and i_profile.lrn is not null then
    if i_profile.lrn=i_profile.dst_prefix_routing then -- number not ported, but request was successf we musr add ;npdi=yes;
      i_profile.ruri:='sip:'||i_profile.dst_prefix_out||';npdi=yes@'||i_vendor_gw.host::varchar||COALESCE(':'||i_vendor_gw.port,'');
      i_profile.lrn=nullif(i_profile.dst_prefix_routing,i_profile.lrn); -- clear lnr field if number not ported;
    else -- if number ported
      i_profile.ruri:='sip:'||i_profile.dst_prefix_out||';rn='||i_profile.lrn||';npdi=yes@'||i_vendor_gw.host::varchar||COALESCE(':'||i_vendor_gw.port,'');
    end if;
  else
    i_profile.ruri:='sip:'||i_profile.dst_prefix_out||'@'||i_vendor_gw.host::varchar||COALESCE(':'||i_vendor_gw.port,''); -- no fucking porting
  end if;

  i_profile.ruri_host:=i_vendor_gw.host::varchar||COALESCE(':'||i_vendor_gw.port,'');

  IF (i_vendor_gw.term_use_outbound_proxy ) THEN
    i_profile.outbound_proxy:='sip:'||i_vendor_gw.term_outbound_proxy;
    i_profile.force_outbound_proxy:=i_vendor_gw.term_force_outbound_proxy;
  ELSE
    i_profile.outbound_proxy:=NULL;
    i_profile.force_outbound_proxy:=false;
  END IF;

  IF (i_customer_gw.orig_use_outbound_proxy ) THEN
    i_profile.aleg_force_outbound_proxy:=i_customer_gw.orig_force_outbound_proxy;
    i_profile.aleg_outbound_proxy='sip:'||i_customer_gw.orig_outbound_proxy;
  else
    i_profile.aleg_force_outbound_proxy:=FALSE;
    i_profile.aleg_outbound_proxy=NULL;
  end if;

  i_profile.aleg_policy_id=i_customer_gw.orig_disconnect_policy_id;
  i_profile.bleg_policy_id=i_vendor_gw.term_disconnect_policy_id;

  i_profile.transit_headers_a2b:=i_customer_gw.transit_headers_from_origination||';'||i_vendor_gw.transit_headers_from_origination;
  i_profile.transit_headers_b2a:=i_vendor_gw.transit_headers_from_termination||';'||i_customer_gw.transit_headers_from_termination;


  i_profile.message_filter_type_id:=1;
  i_profile.message_filter_list:='';

  i_profile.sdp_filter_type_id:=0;
  i_profile.sdp_filter_list:='';

  i_profile.sdp_alines_filter_type_id:=i_vendor_gw.sdp_alines_filter_type_id;
  i_profile.sdp_alines_filter_list:=i_vendor_gw.sdp_alines_filter_list;

  i_profile.enable_session_timer=i_vendor_gw.sst_enabled;
  i_profile.session_expires =i_vendor_gw.sst_session_expires;
  i_profile.minimum_timer:=i_vendor_gw.sst_minimum_timer;
  i_profile.maximum_timer:=i_vendor_gw.sst_maximum_timer;
  i_profile.session_refresh_method_id:=i_vendor_gw.session_refresh_method_id;
  i_profile.accept_501_reply:=i_vendor_gw.sst_accept501;

  i_profile.enable_aleg_session_timer=i_customer_gw.sst_enabled;
  i_profile.aleg_session_expires:=i_customer_gw.sst_session_expires;
  i_profile.aleg_minimum_timer:=i_customer_gw.sst_minimum_timer;
  i_profile.aleg_maximum_timer:=i_customer_gw.sst_maximum_timer;
  i_profile.aleg_session_refresh_method_id:=i_customer_gw.session_refresh_method_id;
  i_profile.aleg_accept_501_reply:=i_customer_gw.sst_accept501;

  i_profile.reply_translations:='';
  i_profile.disconnect_code_id:=NULL;
  i_profile.enable_rtprelay:=i_vendor_gw.proxy_media OR i_customer_gw.proxy_media;
  i_profile.rtprelay_transparent_seqno:=i_vendor_gw.transparent_seqno OR i_customer_gw.transparent_seqno;
  i_profile.rtprelay_transparent_ssrc:=i_vendor_gw.transparent_ssrc OR i_customer_gw.transparent_ssrc;

  i_profile.rtprelay_interface:='';
  i_profile.aleg_rtprelay_interface:='';

  i_profile.outbound_interface:='';
  i_profile.aleg_outbound_interface:='';

  i_profile.rtprelay_msgflags_symmetric_rtp:=false;
  i_profile.bleg_force_symmetric_rtp:=i_vendor_gw.force_symmetric_rtp;
  i_profile.bleg_symmetric_rtp_nonstop=i_vendor_gw.symmetric_rtp_nonstop;
  i_profile.bleg_symmetric_rtp_ignore_rtcp=i_vendor_gw.symmetric_rtp_ignore_rtcp;

  i_profile.aleg_force_symmetric_rtp:=i_customer_gw.force_symmetric_rtp;
  i_profile.aleg_symmetric_rtp_nonstop=i_customer_gw.symmetric_rtp_nonstop;
  i_profile.aleg_symmetric_rtp_ignore_rtcp=i_customer_gw.symmetric_rtp_ignore_rtcp;

  i_profile.bleg_rtp_ping=i_vendor_gw.rtp_ping;
  i_profile.aleg_rtp_ping=i_customer_gw.rtp_ping;

  i_profile.bleg_relay_options = i_vendor_gw.relay_options;
  i_profile.aleg_relay_options = i_customer_gw.relay_options;


  i_profile.filter_noaudio_streams = i_vendor_gw.filter_noaudio_streams OR i_customer_gw.filter_noaudio_streams;
  i_profile.force_one_way_early_media = i_vendor_gw.force_one_way_early_media OR i_customer_gw.force_one_way_early_media;
  i_profile.aleg_relay_reinvite = i_vendor_gw.relay_reinvite;
  i_profile.bleg_relay_reinvite = i_customer_gw.relay_reinvite;

  i_profile.aleg_relay_hold = i_vendor_gw.relay_hold;
  i_profile.bleg_relay_hold = i_customer_gw.relay_hold;

  i_profile.aleg_relay_prack = i_vendor_gw.relay_prack;
  i_profile.bleg_relay_prack = i_customer_gw.relay_prack;


  i_profile.rtp_relay_timestamp_aligning=i_vendor_gw.rtp_relay_timestamp_aligning OR i_customer_gw.rtp_relay_timestamp_aligning;
  i_profile.allow_1xx_wo2tag=i_vendor_gw.allow_1xx_without_to_tag OR i_customer_gw.allow_1xx_without_to_tag;

  i_profile.aleg_sdp_c_location_id=i_customer_gw.sdp_c_location_id;
  i_profile.bleg_sdp_c_location_id=i_vendor_gw.sdp_c_location_id;
  i_profile.trusted_hdrs_gw=false;



  i_profile.dtmf_transcoding:='never';-- always, lowfi_codec, never
  i_profile.lowfi_codecs:='';


  i_profile.enable_reg_caching=false;
  i_profile.min_reg_expires:='100500';
  i_profile.max_ua_expires:='100500';

  i_profile.aleg_codecs_group_id:=i_customer_gw.codec_group_id;
  i_profile.bleg_codecs_group_id:=i_vendor_gw.codec_group_id;
  i_profile.aleg_single_codec_in_200ok:=i_customer_gw.single_codec_in_200ok;
  i_profile.bleg_single_codec_in_200ok:=i_vendor_gw.single_codec_in_200ok;
  i_profile.ringing_timeout=i_vendor_gw.ringing_timeout;
  i_profile.dead_rtp_time=GREATEST(i_vendor_gw.rtp_timeout,i_customer_gw.rtp_timeout);
  i_profile.invite_timeout=i_vendor_gw.sip_timer_b;
  i_profile.srv_failover_timeout=i_vendor_gw.dns_srv_failover_timer;
  i_profile.rtp_force_relay_cn=i_vendor_gw.rtp_force_relay_cn OR i_customer_gw.rtp_force_relay_cn;
  i_profile.patch_ruri_next_hop=i_vendor_gw.resolve_ruri;

  i_profile.aleg_sensor_id=i_customer_gw.sensor_id;
  i_profile.aleg_sensor_level_id=i_customer_gw.sensor_level_id;
  i_profile.bleg_sensor_id=i_vendor_gw.sensor_id;
  i_profile.bleg_sensor_level_id=i_vendor_gw.sensor_level_id;

  i_profile.aleg_dtmf_send_mode_id=i_customer_gw.dtmf_send_mode_id;
  i_profile.aleg_dtmf_recv_modes=i_customer_gw.dtmf_receive_mode_id;
  i_profile.bleg_dtmf_send_mode_id=i_vendor_gw.dtmf_send_mode_id;
  i_profile.bleg_dtmf_recv_modes=i_vendor_gw.dtmf_receive_mode_id;

  i_profile.aleg_relay_update=i_customer_gw.relay_update;
  i_profile.bleg_relay_update=i_vendor_gw.relay_update;
  i_profile.suppress_early_media=i_customer_gw.suppress_early_media OR i_vendor_gw.suppress_early_media;

  i_profile.bleg_radius_acc_profile_id=i_vendor_gw.radius_accounting_profile_id;

  /*dbg{*/
  v_end:=clock_timestamp();
  RAISE NOTICE '% ms -> DP. Finished: % ',EXTRACT(MILLISECOND from v_end-v_start),row_to_json(i_profile,true);
  /*}dbg*/
  RETURN i_profile;
END;
$BODY$
LANGUAGE plpgsql STABLE SECURITY DEFINER
COST 100000;

set search_path to switch10;
select * from preprocess_all();

DROP EXTENSION hstore;

commit;