-- Photo storage (F3.5): public read, signed-in users upload into a folder named after their user id.
insert into storage.buckets (id, name, public)
values ('photos', 'photos', true)
on conflict (id) do nothing;

create policy "photos are public" on storage.objects for select
  using (bucket_id = 'photos');

create policy "upload own photos" on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
