alter table public.raffles
add column if not exists prize_description text,
add column if not exists draw_date date,
add column if not exists privacy_text text default 'Autorizo o uso dos meus dados para contato sobre esta rifa e campanhas relacionadas.';

alter table public.sales
add column if not exists status text not null default 'active',
add column if not exists cancelled_at timestamptz,
add column if not exists cancelled_by uuid references public.sellers(id),
add column if not exists cancel_reason text;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'sales_status_check'
  ) then
    alter table public.sales
    add constraint sales_status_check check (status in ('active', 'cancelled'));
  end if;
end $$;

create table if not exists public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  raffle_id uuid references public.raffles(id),
  seller_id uuid references public.sellers(id),
  action text not null,
  entity_type text not null,
  entity_id uuid,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_audit_logs_raffle_created on public.audit_logs (raffle_id, created_at desc);
alter table public.audit_logs enable row level security;

drop policy if exists "admins can read audit logs" on public.audit_logs;
create policy "admins can read audit logs"
on public.audit_logs
for select
to authenticated
using (public.is_admin());

grant select on public.audit_logs to authenticated;

create or replace function public.update_raffle_settings(
  p_raffle_id uuid default null,
  p_name text default null,
  p_prize_description text default null,
  p_draw_date date default null,
  p_ticket_price numeric default null,
  p_privacy_text text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_seller public.sellers;
  v_raffle public.raffles;
begin
  if not public.is_admin() then
    raise exception 'Acesso restrito ao administrador.';
  end if;

  select * into v_seller from public.sellers where user_id = auth.uid() and active = true limit 1;

  select * into v_raffle
  from public.raffles
  where id = coalesce(p_raffle_id, (select id from public.raffles where active = true order by created_at asc limit 1))
  limit 1;

  if v_raffle.id is null then
    raise exception 'Rifa nao encontrada.';
  end if;

  update public.raffles
  set
    name = coalesce(nullif(trim(p_name), ''), name),
    prize_description = nullif(trim(coalesce(p_prize_description, '')), ''),
    draw_date = p_draw_date,
    ticket_price = coalesce(p_ticket_price, ticket_price),
    privacy_text = coalesce(nullif(trim(p_privacy_text), ''), privacy_text)
  where id = v_raffle.id
  returning * into v_raffle;

  insert into public.audit_logs (raffle_id, seller_id, action, entity_type, entity_id, details)
  values (v_raffle.id, v_seller.id, 'update_settings', 'raffle', v_raffle.id, to_jsonb(v_raffle));

  return to_jsonb(v_raffle);
end;
$$;

create or replace function public.cancel_sale(p_sale_id uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_seller public.sellers;
  v_sale public.sales;
begin
  if not public.is_admin() then
    raise exception 'Acesso restrito ao administrador.';
  end if;

  select * into v_seller from public.sellers where user_id = auth.uid() and active = true limit 1;
  select * into v_sale from public.sales where id = p_sale_id limit 1;

  if v_sale.id is null then
    raise exception 'Venda nao encontrada.';
  end if;

  if v_sale.status = 'cancelled' then
    return jsonb_build_object('ok', true, 'message', 'Venda ja estava cancelada.');
  end if;

  update public.sales
  set status = 'cancelled',
      cancelled_at = now(),
      cancelled_by = v_seller.id,
      cancel_reason = nullif(trim(coalesce(p_reason, '')), '')
  where id = p_sale_id;

  update public.vouchers
  set status = 'cancelled'
  where sale_id = p_sale_id;

  insert into public.audit_logs (raffle_id, seller_id, action, entity_type, entity_id, details)
  values (
    v_sale.raffle_id,
    v_seller.id,
    'cancel_sale',
    'sale',
    v_sale.id,
    jsonb_build_object('reason', p_reason, 'sale_id', v_sale.id)
  );

  return jsonb_build_object('ok', true, 'message', 'Venda cancelada.');
end;
$$;

create or replace function public.set_customer_marketing_consent(p_customer_id uuid, p_consent boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_seller public.sellers;
begin
  if not public.is_admin() then
    raise exception 'Acesso restrito ao administrador.';
  end if;

  select * into v_seller from public.sellers where user_id = auth.uid() and active = true limit 1;

  update public.customers
  set marketing_consent = p_consent
  where id = p_customer_id;

  insert into public.audit_logs (seller_id, action, entity_type, entity_id, details)
  values (
    v_seller.id,
    'set_marketing_consent',
    'customer',
    p_customer_id,
    jsonb_build_object('marketing_consent', p_consent)
  );

  return jsonb_build_object('ok', true);
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
  v_reserved integer;
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

  select count(*) into v_issued from public.vouchers where raffle_id = v_raffle.id and status <> 'cancelled';
  select count(*) into v_reserved from public.vouchers where raffle_id = v_raffle.id;
  select coalesce(sum(total_amount), 0) into v_revenue from public.sales where raffle_id = v_raffle.id and status <> 'cancelled';

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
      where raffle_id = v_raffle.id and status <> 'cancelled'
      group by seller_id
    ) vs on vs.seller_id = s.id
    left join (
      select seller_id, sum(total_amount) as revenue
      from public.sales
      where raffle_id = v_raffle.id and status <> 'cancelled'
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
    'reserved_count', v_reserved,
    'revenue_total', v_revenue,
    'ranking', v_ranking
  );
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
  v_reserved integer;
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

  select count(*) into v_issued from public.vouchers where raffle_id = v_raffle.id and status <> 'cancelled';
  select count(*) into v_reserved from public.vouchers where raffle_id = v_raffle.id;
  select coalesce(sum(total_amount), 0) into v_revenue from public.sales where raffle_id = v_raffle.id and status <> 'cancelled';
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
      where raffle_id = v_raffle.id and status <> 'cancelled'
      group by seller_id
    ) vs on vs.seller_id = s.id
    left join (
      select seller_id, count(*) as sales_count, sum(total_amount) as revenue
      from public.sales
      where raffle_id = v_raffle.id and status <> 'cancelled'
      group by seller_id
    ) ss on ss.seller_id = s.id
    where s.active = true
  ) ranked;

  select coalesce(jsonb_agg(row_data order by row_data->>'name'), '[]'::jsonb)
  into v_contacts
  from (
    select jsonb_build_object(
      'customer_id', c.id,
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
      'customer_cpf', c.cpf,
      'quantity', sa.quantity,
      'total_amount', sa.total_amount,
      'status', sa.status
    ) as row_data
    from public.sales sa
    join public.sellers s on s.id = sa.seller_id
    join public.customers c on c.id = sa.customer_id
    where sa.raffle_id = v_raffle.id
    order by sa.created_at desc
    limit 250
  ) sales;

  return jsonb_build_object(
    'raffle_id', v_raffle.id,
    'raffle', to_jsonb(v_raffle) - 'secret_key',
    'total_numbers', v_raffle.total_numbers,
    'ticket_price', v_raffle.ticket_price,
    'issued_count', v_issued,
    'reserved_count', v_reserved,
    'available_count', v_raffle.total_numbers - v_reserved,
    'revenue_total', v_revenue,
    'customer_count', v_customer_count,
    'sellers', v_sellers,
    'contacts', v_contacts,
    'recent_sales', v_recent_sales
  );
end;
$$;

create or replace function public.get_backup_snapshot(p_raffle_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_raffle public.raffles;
begin
  if not public.is_admin() then
    raise exception 'Acesso restrito ao administrador.';
  end if;

  select * into v_raffle
  from public.raffles
  where id = coalesce(p_raffle_id, (select id from public.raffles where active = true order by created_at asc limit 1))
  limit 1;

  return jsonb_build_object(
    'generated_at', now(),
    'raffle', to_jsonb(v_raffle) - 'secret_key',
    'sellers', (select coalesce(jsonb_agg(to_jsonb(s) - 'user_id'), '[]'::jsonb) from public.sellers s),
    'customers', (select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) from public.customers c),
    'sales', (select coalesce(jsonb_agg(to_jsonb(sa)), '[]'::jsonb) from public.sales sa where sa.raffle_id = v_raffle.id),
    'vouchers', (select coalesce(jsonb_agg(to_jsonb(v) - 'signature'), '[]'::jsonb) from public.vouchers v where v.raffle_id = v_raffle.id),
    'validations', (select coalesce(jsonb_agg(to_jsonb(val)), '[]'::jsonb) from public.validations val),
    'audit_logs', (select coalesce(jsonb_agg(to_jsonb(log)), '[]'::jsonb) from public.audit_logs log where log.raffle_id = v_raffle.id)
  );
end;
$$;

grant execute on function public.update_raffle_settings(uuid, text, text, date, numeric, text) to authenticated;
grant execute on function public.cancel_sale(uuid, text) to authenticated;
grant execute on function public.set_customer_marketing_consent(uuid, boolean) to authenticated;
grant execute on function public.get_backup_snapshot(uuid) to authenticated;
grant execute on function public.get_raffle_dashboard(uuid) to authenticated;
grant execute on function public.get_admin_dashboard(uuid) to authenticated;
