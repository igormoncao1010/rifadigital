insert into storage.buckets (id, name, public)
values ('raffle-images', 'raffle-images', true)
on conflict (id) do update
set public = true;

drop policy if exists "authenticated can upload raffle images" on storage.objects;
create policy "authenticated can upload raffle images"
on storage.objects
for insert
to authenticated
with check (bucket_id = 'raffle-images');

drop policy if exists "authenticated can update raffle images" on storage.objects;
create policy "authenticated can update raffle images"
on storage.objects
for update
to authenticated
using (bucket_id = 'raffle-images')
with check (bucket_id = 'raffle-images');

drop policy if exists "public can read raffle images" on storage.objects;
create policy "public can read raffle images"
on storage.objects
for select
to public
using (bucket_id = 'raffle-images');
