alter table public.customers
add column if not exists marketing_consent boolean not null default false;

create or replace function public.issue_vouchers(
  p_raffle_id uuid default null,
  p_customer jsonb default '{}'::jsonb,
  p_quantity integer default 1
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_seller public.sellers;
  v_raffle public.raffles;
  v_customer_id uuid;
  v_sale_id uuid;
  v_numbers integer[];
  v_number integer;
  v_voucher_id uuid;
  v_created_at timestamptz;
  v_previous_hash text;
  v_signature text;
  v_record_hash text;
  v_token text;
  v_result jsonb := '[]'::jsonb;
begin
  select * into v_seller
  from public.sellers
  where user_id = auth.uid()
    and active = true
  limit 1;

  if v_seller.id is null then
    raise exception 'Vendedor sem acesso ativo.';
  end if;

  if p_quantity < 1 or p_quantity > 100 then
    raise exception 'Quantidade deve estar entre 1 e 100.';
  end if;

  select * into v_raffle
  from public.raffles
  where id = coalesce(p_raffle_id, (select id from public.raffles where active = true order by created_at asc limit 1))
    and active = true
  limit 1;

  if v_raffle.id is null then
    raise exception 'Rifa ativa nao encontrada.';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_raffle.id::text));

  if (select count(*) from public.vouchers where raffle_id = v_raffle.id) + p_quantity > v_raffle.total_numbers then
    raise exception 'Nao existem numeros suficientes disponiveis.';
  end if;

  insert into public.customers (name, phone, email, cpf, marketing_consent)
  values (
    trim(p_customer->>'name'),
    trim(p_customer->>'phone'),
    trim(p_customer->>'email'),
    trim(p_customer->>'cpf'),
    coalesce((p_customer->>'marketing_consent')::boolean, false)
  )
  returning id into v_customer_id;

  insert into public.sales (raffle_id, seller_id, customer_id, quantity, unit_price, total_amount)
  values (v_raffle.id, v_seller.id, v_customer_id, p_quantity, v_raffle.ticket_price, v_raffle.ticket_price * p_quantity)
  returning id into v_sale_id;

  select array_agg(n)
  into v_numbers
  from (
    select n
    from generate_series(1, v_raffle.total_numbers) as available(n)
    where not exists (
      select 1
      from public.vouchers v
      where v.raffle_id = v_raffle.id
        and v.ticket_number = n
    )
    order by random()
    limit p_quantity
  ) available_numbers;

  foreach v_number in array v_numbers loop
    v_voucher_id := gen_random_uuid();
    v_created_at := now();
    select coalesce(record_hash, 'GENESIS')
    into v_previous_hash
    from public.vouchers
    where raffle_id = v_raffle.id
    order by created_at desc
    limit 1;

    v_previous_hash := coalesce(v_previous_hash, 'GENESIS');
    v_signature := public.sign_voucher(
      v_raffle.secret_key,
      v_voucher_id,
      v_raffle.id,
      v_sale_id,
      v_seller.id,
      v_customer_id,
      v_number,
      v_created_at,
      v_previous_hash
    );
    v_record_hash := public.hash_voucher_record(
      v_voucher_id,
      v_raffle.id,
      v_sale_id,
      v_seller.id,
      v_customer_id,
      v_number,
      v_created_at,
      v_previous_hash,
      v_signature
    );
    v_token := public.build_voucher_token(v_voucher_id, v_number, v_signature);

    insert into public.vouchers (
      id,
      raffle_id,
      sale_id,
      seller_id,
      customer_id,
      ticket_number,
      token,
      signature,
      previous_hash,
      record_hash,
      created_at
    )
    values (
      v_voucher_id,
      v_raffle.id,
      v_sale_id,
      v_seller.id,
      v_customer_id,
      v_number,
      v_token,
      v_signature,
      v_previous_hash,
      v_record_hash,
      v_created_at
    );

    v_result := v_result || jsonb_build_array(
      jsonb_build_object(
        'id', v_voucher_id,
        'ticket_number', v_number,
        'token', v_token,
        'created_at', v_created_at,
        'customer_name', p_customer->>'name',
        'customer_phone', p_customer->>'phone',
        'customer_email', p_customer->>'email',
        'customer_cpf', p_customer->>'cpf',
        'seller_name', v_seller.name
      )
    );
  end loop;

  return v_result;
end;
$$;

create or replace function public.get_admin_dashboard(p_raffle_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_raffle public.raffles;
  v_issued integer;
  v_revenue numeric(10, 2);
  v_customer_count integer;
  v_sellers jsonb;
  v_contacts jsonb;
  v_recent_sales jsonb;
begin
  if not public.is_admin() then
    raise exception 'Acesso restrito ao administrador.';
  end if;

  select * into v_raffle
  from public.raffles
  where id = coalesce(p_raffle_id, (select id from public.raffles where active = true order by created_at asc limit 1))
  limit 1;

  if v_raffle.id is null then
    raise exception 'Rifa nao encontrada.';
  end if;

  select count(*) into v_issued from public.vouchers where raffle_id = v_raffle.id;
  select coalesce(sum(total_amount), 0) into v_revenue from public.sales where raffle_id = v_raffle.id;
  select count(distinct customer_id) into v_customer_count from public.sales where raffle_id = v_raffle.id;

  select coalesce(jsonb_agg(row_data order by (row_data->>'position')::integer), '[]'::jsonb)
  into v_sellers
  from (
    select jsonb_build_object(
      'position', row_number() over (order by coalesce(vs.tickets_sold, 0) desc, coalesce(ss.revenue, 0) desc, s.name asc),
      'seller_id', s.id,
      'seller_name', s.name,
      'sales_count', coalesce(ss.sales_count, 0),
      'tickets_sold', coalesce(vs.tickets_sold, 0),
      'revenue', coalesce(ss.revenue, 0)
    ) as row_data
    from public.sellers s
    left join (
      select seller_id, count(*) as tickets_sold
      from public.vouchers
      where raffle_id = v_raffle.id
      group by seller_id
    ) vs on vs.seller_id = s.id
    left join (
      select seller_id, count(*) as sales_count, sum(total_amount) as revenue
      from public.sales
      where raffle_id = v_raffle.id
      group by seller_id
    ) ss on ss.seller_id = s.id
    where s.active = true
  ) ranked;

  select coalesce(jsonb_agg(row_data order by row_data->>'name'), '[]'::jsonb)
  into v_contacts
  from (
    select jsonb_build_object(
      'name', c.name,
      'email', c.email,
      'phone', c.phone,
      'cpf', c.cpf,
      'purchases', count(sa.id)
    ) as row_data
    from public.customers c
    join public.sales sa on sa.customer_id = c.id and sa.raffle_id = v_raffle.id
    where c.marketing_consent = true
    group by c.id, c.name, c.email, c.phone, c.cpf
  ) contacts;

  select coalesce(jsonb_agg(row_data order by row_data->>'created_at' desc), '[]'::jsonb)
  into v_recent_sales
  from (
    select jsonb_build_object(
      'id', sa.id,
      'created_at', sa.created_at,
      'seller_name', s.name,
      'customer_name', c.name,
      'customer_email', c.email,
      'customer_phone', c.phone,
      'quantity', sa.quantity,
      'total_amount', sa.total_amount
    ) as row_data
    from public.sales sa
    join public.sellers s on s.id = sa.seller_id
    join public.customers c on c.id = sa.customer_id
    where sa.raffle_id = v_raffle.id
    order by sa.created_at desc
    limit 100
  ) sales;

  return jsonb_build_object(
    'raffle_id', v_raffle.id,
    'raffle_name', v_raffle.name,
    'total_numbers', v_raffle.total_numbers,
    'ticket_price', v_raffle.ticket_price,
    'issued_count', v_issued,
    'available_count', v_raffle.total_numbers - v_issued,
    'revenue_total', v_revenue,
    'customer_count', v_customer_count,
    'sellers', v_sellers,
    'contacts', v_contacts,
    'recent_sales', v_recent_sales
  );
end;
$$;

grant execute on function public.get_admin_dashboard(uuid) to authenticated;
grant execute on function public.issue_vouchers(uuid, jsonb, integer) to authenticated;
