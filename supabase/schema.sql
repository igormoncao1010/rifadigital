create extension if not exists pgcrypto;

create table if not exists public.raffles (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'Rifa Digital Premiada',
  total_numbers integer not null default 100000 check (total_numbers > 0),
  ticket_price numeric(10, 2) not null default 5.00 check (ticket_price >= 0),
  secret_key text not null default encode(gen_random_bytes(32), 'hex'),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.sellers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  name text not null,
  email text not null unique,
  phone text,
  role text not null default 'seller' check (role in ('owner', 'admin', 'seller')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text not null,
  email text not null,
  cpf text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.sales (
  id uuid primary key default gen_random_uuid(),
  raffle_id uuid not null references public.raffles(id),
  seller_id uuid not null references public.sellers(id),
  customer_id uuid not null references public.customers(id),
  quantity integer not null check (quantity > 0),
  unit_price numeric(10, 2) not null,
  total_amount numeric(10, 2) not null,
  created_at timestamptz not null default now()
);

create table if not exists public.vouchers (
  id uuid primary key default gen_random_uuid(),
  raffle_id uuid not null references public.raffles(id),
  sale_id uuid not null references public.sales(id),
  seller_id uuid not null references public.sellers(id),
  customer_id uuid not null references public.customers(id),
  ticket_number integer not null check (ticket_number > 0),
  status text not null default 'issued' check (status in ('issued', 'validated', 'cancelled')),
  token text not null unique,
  signature text not null,
  previous_hash text not null,
  record_hash text not null unique,
  created_at timestamptz not null default now(),
  unique (raffle_id, ticket_number)
);

create table if not exists public.validations (
  id uuid primary key default gen_random_uuid(),
  voucher_id uuid references public.vouchers(id),
  seller_id uuid references public.sellers(id),
  token text not null,
  result text not null,
  message text not null,
  created_at timestamptz not null default now()
);

create index if not exists idx_sales_raffle_seller on public.sales (raffle_id, seller_id);
create index if not exists idx_sales_customer on public.sales (customer_id);
create index if not exists idx_vouchers_raffle_seller on public.vouchers (raffle_id, seller_id);
create index if not exists idx_vouchers_sale on public.vouchers (sale_id);
create index if not exists idx_vouchers_customer on public.vouchers (customer_id);
create index if not exists idx_validations_seller on public.validations (seller_id, created_at desc);

insert into public.raffles (name, total_numbers, ticket_price)
select 'Rifa Digital Premiada', 100000, 5.00
where not exists (select 1 from public.raffles);

alter table public.raffles enable row level security;
alter table public.sellers enable row level security;
alter table public.customers enable row level security;
alter table public.sales enable row level security;
alter table public.vouchers enable row level security;
alter table public.validations enable row level security;

create or replace view public.voucher_history as
select
  v.id,
  v.ticket_number,
  c.name as customer_name,
  s.name as seller_name,
  v.created_at,
  v.status
from public.vouchers v
join public.customers c on c.id = v.customer_id
join public.sellers s on s.id = v.seller_id;

alter view public.voucher_history set (security_invoker = true);

create or replace function public.current_seller()
returns public.sellers
language sql
stable
security definer
set search_path = public
as $$
  select *
  from public.sellers
  where user_id = auth.uid()
    and active = true
  limit 1;
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.sellers
    where user_id = auth.uid()
      and active = true
      and role in ('owner', 'admin')
  );
$$;

drop policy if exists "authenticated can read active raffle" on public.raffles;
create policy "authenticated can read active raffle"
on public.raffles
for select
to authenticated
using (active = true);

drop policy if exists "authenticated can read sellers" on public.sellers;
create policy "authenticated can read sellers"
on public.sellers
for select
to authenticated
using (true);

drop policy if exists "authenticated can read customers" on public.customers;
create policy "authenticated can read customers"
on public.customers
for select
to authenticated
using (
  public.is_admin()
  or exists (
    select 1
    from public.sales sa
    where sa.customer_id = customers.id
      and sa.seller_id = (public.current_seller()).id
  )
);

drop policy if exists "authenticated can read sales" on public.sales;
create policy "authenticated can read sales"
on public.sales
for select
to authenticated
using (public.is_admin() or seller_id = (public.current_seller()).id);

drop policy if exists "authenticated can read vouchers" on public.vouchers;
create policy "authenticated can read vouchers"
on public.vouchers
for select
to authenticated
using (public.is_admin() or seller_id = (public.current_seller()).id);

drop policy if exists "authenticated can read validations" on public.validations;
create policy "authenticated can read validations"
on public.validations
for select
to authenticated
using (public.is_admin() or seller_id = (public.current_seller()).id);

grant usage on schema public to anon, authenticated;
grant select on public.raffles, public.sellers, public.customers, public.sales, public.vouchers, public.validations to authenticated;
grant select on public.voucher_history to authenticated;

create or replace function public.sign_voucher(
  p_secret text,
  p_voucher_id uuid,
  p_raffle_id uuid,
  p_sale_id uuid,
  p_seller_id uuid,
  p_customer_id uuid,
  p_ticket_number integer,
  p_created_at timestamptz,
  p_previous_hash text
)
returns text
language sql
immutable
as $$
  select encode(
    hmac(
      concat_ws('|', p_voucher_id, p_raffle_id, p_sale_id, p_seller_id, p_customer_id, p_ticket_number, p_created_at, p_previous_hash),
      p_secret,
      'sha256'
    ),
    'hex'
  );
$$;

create or replace function public.hash_voucher_record(
  p_voucher_id uuid,
  p_raffle_id uuid,
  p_sale_id uuid,
  p_seller_id uuid,
  p_customer_id uuid,
  p_ticket_number integer,
  p_created_at timestamptz,
  p_previous_hash text,
  p_signature text
)
returns text
language sql
immutable
as $$
  select encode(
    digest(
      concat_ws('|', p_voucher_id, p_raffle_id, p_sale_id, p_seller_id, p_customer_id, p_ticket_number, p_created_at, p_previous_hash, p_signature),
      'sha256'
    ),
    'hex'
  );
$$;

create or replace function public.build_voucher_token(p_voucher_id uuid, p_ticket_number integer, p_signature text)
returns text
language sql
immutable
as $$
  select replace(
    encode(
      convert_to(
        jsonb_build_object('v', 1, 'id', p_voucher_id, 'n', p_ticket_number, 'sig', p_signature)::text,
        'utf8'
      ),
      'base64'
    ),
    E'\n',
    ''
  );
$$;

revoke all on function public.sign_voucher(text, uuid, uuid, uuid, uuid, uuid, integer, timestamptz, text) from public;
revoke all on function public.hash_voucher_record(uuid, uuid, uuid, uuid, uuid, integer, timestamptz, text, text) from public;
revoke all on function public.build_voucher_token(uuid, integer, text) from public;

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

  insert into public.customers (name, phone, email, cpf)
  values (
    trim(p_customer->>'name'),
    trim(p_customer->>'phone'),
    trim(p_customer->>'email'),
    trim(p_customer->>'cpf')
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

create or replace function public.validate_voucher_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payload jsonb;
  v_voucher public.vouchers;
  v_raffle public.raffles;
  v_customer public.customers;
  v_seller public.sellers;
  v_current_seller public.sellers;
  v_expected_signature text;
  v_expected_hash text;
  v_ok boolean;
  v_message text;
begin
  select * into v_current_seller
  from public.sellers
  where user_id = auth.uid()
    and active = true
  limit 1;

  if v_current_seller.id is null then
    raise exception 'Vendedor sem acesso ativo.';
  end if;

  begin
    v_payload := convert_from(decode(p_token, 'base64'), 'utf8')::jsonb;
  exception when others then
    insert into public.validations (seller_id, token, result, message)
    values (v_current_seller.id, p_token, 'invalid', 'Token ilegivel.');
    return jsonb_build_object('ok', false, 'message', 'Token ilegivel.');
  end;

  select * into v_voucher
  from public.vouchers
  where id = (v_payload->>'id')::uuid
    and ticket_number = (v_payload->>'n')::integer
  limit 1;

  if v_voucher.id is null then
    insert into public.validations (seller_id, token, result, message)
    values (v_current_seller.id, p_token, 'not_found', 'Voucher nao encontrado.');
    return jsonb_build_object('ok', false, 'message', 'Voucher nao encontrado.');
  end if;

  select * into v_raffle from public.raffles where id = v_voucher.raffle_id;
  select * into v_customer from public.customers where id = v_voucher.customer_id;
  select * into v_seller from public.sellers where id = v_voucher.seller_id;

  v_expected_signature := public.sign_voucher(
    v_raffle.secret_key,
    v_voucher.id,
    v_voucher.raffle_id,
    v_voucher.sale_id,
    v_voucher.seller_id,
    v_voucher.customer_id,
    v_voucher.ticket_number,
    v_voucher.created_at,
    v_voucher.previous_hash
  );
  v_expected_hash := public.hash_voucher_record(
    v_voucher.id,
    v_voucher.raffle_id,
    v_voucher.sale_id,
    v_voucher.seller_id,
    v_voucher.customer_id,
    v_voucher.ticket_number,
    v_voucher.created_at,
    v_voucher.previous_hash,
    v_expected_signature
  );

  v_ok := (v_payload->>'sig') = v_expected_signature
    and v_voucher.signature = v_expected_signature
    and v_voucher.record_hash = v_expected_hash;

  v_message := case when v_ok then 'Voucher valido.' else 'Voucher adulterado ou assinatura invalida.' end;

  insert into public.validations (voucher_id, seller_id, token, result, message)
  values (v_voucher.id, v_current_seller.id, p_token, case when v_ok then 'valid' else 'invalid' end, v_message);

  return jsonb_build_object(
    'ok', v_ok,
    'message', v_message,
    'ticket_number', v_voucher.ticket_number,
    'customer_name', v_customer.name,
    'seller_name', v_seller.name,
    'status', v_voucher.status
  );
end;
$$;

create or replace function public.get_raffle_dashboard(p_raffle_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_raffle public.raffles;
  v_issued integer;
  v_revenue numeric(10, 2);
  v_ranking jsonb;
begin
  select * into v_raffle
  from public.raffles
  where id = coalesce(p_raffle_id, (select id from public.raffles where active = true order by created_at asc limit 1))
  limit 1;

  if v_raffle.id is null then
    raise exception 'Rifa nao encontrada.';
  end if;

  select count(*) into v_issued from public.vouchers where raffle_id = v_raffle.id;
  select coalesce(sum(total_amount), 0) into v_revenue from public.sales where raffle_id = v_raffle.id;

  select coalesce(jsonb_agg(row_data order by (row_data->>'position')::integer), '[]'::jsonb)
  into v_ranking
  from (
    select jsonb_build_object(
      'position', row_number() over (order by coalesce(vs.tickets_sold, 0) desc, coalesce(ss.revenue, 0) desc, s.name asc),
      'seller_id', s.id,
      'seller_name', s.name,
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
      select seller_id, sum(total_amount) as revenue
      from public.sales
      where raffle_id = v_raffle.id
      group by seller_id
    ) ss on ss.seller_id = s.id
    where s.active = true
  ) ranked;

  return jsonb_build_object(
    'raffle_id', v_raffle.id,
    'raffle_name', v_raffle.name,
    'total_numbers', v_raffle.total_numbers,
    'ticket_price', v_raffle.ticket_price,
    'issued_count', v_issued,
    'revenue_total', v_revenue,
    'ranking', v_ranking
  );
end;
$$;

grant execute on function public.issue_vouchers(uuid, jsonb, integer) to authenticated;
grant execute on function public.validate_voucher_token(text) to authenticated;
grant execute on function public.get_raffle_dashboard(uuid) to authenticated;
