alter table public.raffles
add column if not exists image_url text,
add column if not exists prize_description text,
add column if not exists draw_date date,
add column if not exists privacy_text text default 'Autorizo o uso dos meus dados para contato sobre esta rifa e campanhas relacionadas.';

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

alter table public.audit_logs enable row level security;

drop policy if exists "admins can read audit logs" on public.audit_logs;
create policy "admins can read audit logs"
on public.audit_logs
for select
to authenticated
using (public.is_admin());

grant select on public.audit_logs to authenticated;

create or replace function public.list_raffles()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
begin
  select coalesce(jsonb_agg(row_data order by row_data->>'created_at' desc), '[]'::jsonb)
  into v_result
  from (
    select jsonb_build_object(
      'id', r.id,
      'name', r.name,
      'image_url', r.image_url,
      'prize_description', r.prize_description,
      'draw_date', r.draw_date,
      'total_numbers', r.total_numbers,
      'ticket_price', r.ticket_price,
      'active', r.active,
      'created_at', r.created_at,
      'issued_count', count(v.id) filter (where v.status <> 'cancelled'),
      'reserved_count', count(v.id)
    ) as row_data
    from public.raffles r
    left join public.vouchers v on v.raffle_id = r.id
    where r.active = true
    group by r.id
  ) raffles;

  return v_result;
end;
$$;

create or replace function public.create_raffle(
  p_name text,
  p_image_url text default null,
  p_prize_description text default null,
  p_total_numbers integer default 100000,
  p_ticket_price numeric default 5,
  p_draw_date date default null
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

  if p_total_numbers < 1 then
    raise exception 'Quantidade de numeros invalida.';
  end if;

  select * into v_seller from public.sellers where user_id = auth.uid() and active = true limit 1;

  insert into public.raffles (
    name,
    image_url,
    prize_description,
    total_numbers,
    ticket_price,
    draw_date,
    active
  )
  values (
    nullif(trim(p_name), ''),
    nullif(trim(coalesce(p_image_url, '')), ''),
    nullif(trim(coalesce(p_prize_description, '')), ''),
    p_total_numbers,
    p_ticket_price,
    p_draw_date,
    true
  )
  returning * into v_raffle;

  insert into public.audit_logs (raffle_id, seller_id, action, entity_type, entity_id, details)
  values (v_raffle.id, v_seller.id, 'create_raffle', 'raffle', v_raffle.id, to_jsonb(v_raffle) - 'secret_key');

  return to_jsonb(v_raffle) - 'secret_key';
end;
$$;

create or replace function public.update_raffle_settings(
  p_raffle_id uuid default null,
  p_name text default null,
  p_image_url text default null,
  p_prize_description text default null,
  p_draw_date date default null,
  p_ticket_price numeric default null,
  p_total_numbers integer default null,
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
  v_reserved integer;
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

  select count(*) into v_reserved from public.vouchers where raffle_id = v_raffle.id;
  if p_total_numbers is not null and p_total_numbers < v_reserved then
    raise exception 'Quantidade total nao pode ser menor que os numeros ja emitidos/reservados.';
  end if;

  update public.raffles
  set
    name = coalesce(nullif(trim(p_name), ''), name),
    image_url = nullif(trim(coalesce(p_image_url, '')), ''),
    prize_description = nullif(trim(coalesce(p_prize_description, '')), ''),
    draw_date = p_draw_date,
    ticket_price = coalesce(p_ticket_price, ticket_price),
    total_numbers = coalesce(p_total_numbers, total_numbers),
    privacy_text = coalesce(nullif(trim(p_privacy_text), ''), privacy_text)
  where id = v_raffle.id
  returning * into v_raffle;

  insert into public.audit_logs (raffle_id, seller_id, action, entity_type, entity_id, details)
  values (v_raffle.id, v_seller.id, 'update_settings', 'raffle', v_raffle.id, to_jsonb(v_raffle) - 'secret_key');

  return to_jsonb(v_raffle) - 'secret_key';
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
    'raffle', to_jsonb(v_raffle) - 'secret_key',
    'total_numbers', v_raffle.total_numbers,
    'ticket_price', v_raffle.ticket_price,
    'issued_count', v_issued,
    'reserved_count', v_reserved,
    'revenue_total', v_revenue,
    'ranking', v_ranking
  );
end;
$$;

grant execute on function public.list_raffles() to authenticated;
grant execute on function public.create_raffle(text, text, text, integer, numeric, date) to authenticated;
grant execute on function public.update_raffle_settings(uuid, text, text, text, date, numeric, integer, text) to authenticated;
grant execute on function public.get_raffle_dashboard(uuid) to authenticated;
