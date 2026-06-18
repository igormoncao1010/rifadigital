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
    extensions.hmac(
      convert_to(
        concat_ws('|', p_voucher_id, p_raffle_id, p_sale_id, p_seller_id, p_customer_id, p_ticket_number, p_created_at, p_previous_hash),
        'utf8'
      ),
      convert_to(p_secret, 'utf8'),
      'sha256'::text
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
    extensions.digest(
      concat_ws('|', p_voucher_id, p_raffle_id, p_sale_id, p_seller_id, p_customer_id, p_ticket_number, p_created_at, p_previous_hash, p_signature),
      'sha256'::text
    ),
    'hex'
  );
$$;

revoke all on function public.sign_voucher(text, uuid, uuid, uuid, uuid, uuid, integer, timestamptz, text) from public;
revoke all on function public.hash_voucher_record(uuid, uuid, uuid, uuid, uuid, integer, timestamptz, text, text) from public;
