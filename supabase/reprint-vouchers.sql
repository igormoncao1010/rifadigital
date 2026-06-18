create or replace function public.search_reprint_vouchers(
  p_raffle_id uuid default null,
  p_query text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_current_seller public.sellers;
  v_raffle public.raffles;
  v_query text;
  v_digits text;
  v_result jsonb;
begin
  select * into v_current_seller
  from public.sellers
  where user_id = auth.uid()
    and active = true
  limit 1;

  if v_current_seller.id is null then
    raise exception 'Vendedor sem acesso ativo.';
  end if;

  select * into v_raffle
  from public.raffles
  where id = coalesce(p_raffle_id, (select id from public.raffles where active = true order by created_at asc limit 1))
  limit 1;

  if v_raffle.id is null then
    raise exception 'Rifa nao encontrada.';
  end if;

  v_query := lower(trim(coalesce(p_query, '')));
  v_digits := regexp_replace(v_query, '\D', '', 'g');

  select coalesce(jsonb_agg(row_data order by row_data->>'created_at' desc), '[]'::jsonb)
  into v_result
  from (
    select jsonb_build_object(
      'id', v.id,
      'ticket_number', v.ticket_number,
      'token', v.token,
      'created_at', v.created_at,
      'status', v.status,
      'customer_name', c.name,
      'customer_phone', c.phone,
      'customer_email', c.email,
      'customer_cpf', c.cpf,
      'seller_name', s.name,
      'sale_id', sa.id,
      'sale_quantity', sa.quantity,
      'sale_total', sa.total_amount
    ) as row_data
    from public.vouchers v
    join public.sales sa on sa.id = v.sale_id
    join public.customers c on c.id = v.customer_id
    join public.sellers s on s.id = v.seller_id
    where v.raffle_id = v_raffle.id
      and (
        public.is_admin()
        or v.seller_id = v_current_seller.id
      )
      and (
        v_query = ''
        or lower(c.name) like '%' || v_query || '%'
        or lower(c.email) like '%' || v_query || '%'
        or regexp_replace(c.phone, '\D', '', 'g') like '%' || v_digits || '%'
        or regexp_replace(c.cpf, '\D', '', 'g') like '%' || v_digits || '%'
        or v.ticket_number::text = v_digits
        or v.id::text = v_query
        or sa.id::text = v_query
      )
    order by v.created_at desc
    limit 250
  ) vouchers;

  return v_result;
end;
$$;

grant execute on function public.search_reprint_vouchers(uuid, text) to authenticated;
