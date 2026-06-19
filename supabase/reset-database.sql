-- ATENÇÃO: este reset apaga rifas, clientes, vendas, vouchers, validações e logs.
-- Ele mantém usuários e vendedores/admins para você conseguir entrar novamente.

do $$
begin
  if to_regclass('public.audit_logs') is not null then
    execute 'truncate table public.audit_logs restart identity cascade';
  end if;

  if to_regclass('public.validations') is not null then
    execute 'truncate table public.validations restart identity cascade';
  end if;

  if to_regclass('public.vouchers') is not null then
    execute 'truncate table public.vouchers restart identity cascade';
  end if;

  if to_regclass('public.sales') is not null then
    execute 'truncate table public.sales restart identity cascade';
  end if;

  if to_regclass('public.customers') is not null then
    execute 'truncate table public.customers restart identity cascade';
  end if;

  if to_regclass('public.raffles') is not null then
    execute 'truncate table public.raffles restart identity cascade';
  end if;
end $$;

delete from storage.objects
where bucket_id = 'raffle-images';

-- Opcional: se quiser apagar também vendedores/admins do sistema, rode manualmente:
-- truncate table public.sellers restart identity cascade;
