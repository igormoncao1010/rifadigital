-- 1. Primeiro crie o usuario adm@adm.com.br em Authentication > Users.
-- 2. Depois rode este SQL no SQL Editor do Supabase.
-- 3. Ele localiza o usuario pelo email e libera acesso como dono/admin da rifa.

insert into public.sellers (user_id, name, email, phone, role, active)
select
  u.id,
  'Administrador',
  'adm@adm.com.br',
  null,
  'owner',
  true
from auth.users u
where u.email = 'adm@adm.com.br'
on conflict (user_id) do update
set
  name = excluded.name,
  email = excluded.email,
  phone = excluded.phone,
  role = 'owner',
  active = true;
