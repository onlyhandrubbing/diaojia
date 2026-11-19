-- 掉價中 schema for Supabase (run once in SQL editor)
-- Public table holds what everyone may see; the hidden floor price and contacts live in item_private,
-- reachable only through the security-definer functions below.

create extension if not exists pgcrypto;

create table if not exists items(
  id uuid primary key default gen_random_uuid(),
  seller uuid not null default auth.uid(),
  title text not null check (char_length(title) between 2 and 40),
  story text not null default '' check (char_length(story) <= 300),
  cond text not null default '良好',
  new_price int check (new_price is null or new_price between 1 and 1000000),
  start_price int not null check (start_price between 10 and 1000000),
  step int not null check (step >= 1),
  interval_min int not null check (interval_min in (10,30,60)),
  start_at timestamptz not null,
  end_at timestamptz not null,
  photos text[] not null default '{}',
  area text not null default '',
  ship text not null default '賣貨便',
  status text not null default 'live' check (status in ('live','sold','removed')),
  sold_price int, sold_at timestamptz, buyer uuid,
  reports int not null default 0,
  created_at timestamptz not null default now()
);
create table if not exists item_private(
  item_id uuid primary key references items(id) on delete cascade,
  floor_price int not null,
  seller_contact text not null check (char_length(seller_contact) between 2 and 120),
  buyer_name text, buyer_contact text
);
alter table items enable row level security;
alter table item_private enable row level security;
drop policy if exists items_read on items;
create policy items_read on items for select using (status <> 'removed' or seller = auth.uid());
-- no direct insert/update/delete: everything goes through functions

create or replace function _price(i items, fl int) returns int language sql stable as $$
  select greatest(fl, i.start_price - i.step * greatest(0, floor(extract(epoch from (now() - i.start_at)) / 60 / i.interval_min))::int)
$$;

create or replace function prices() returns table(id uuid, price int, at_floor boolean)
language sql security definer set search_path = public stable as $$
  select i.id, _price(i, p.floor_price), _price(i, p.floor_price) <= p.floor_price
  from items i join item_private p on p.item_id = i.id where i.status = 'live'
$$;

create or replace function create_item(
  title text, story text, cond text, new_price int, start_price int, floor_price int,
  interval_min int, hours int, start_at timestamptz, photos text[], area text, ship text, seller_contact text
) returns uuid language plpgsql security definer set search_path = public as $$
declare nid uuid; steps int; st int;
begin
  if auth.uid() is null then raise exception 'login'; end if;
  if (select count(*) from items where seller = auth.uid() and status = 'live') >= 5 then raise exception 'too_many'; end if;
  if floor_price < 1 or floor_price >= start_price then raise exception 'floor'; end if;
  if hours not in (3,6,12,24,48) then raise exception 'hours'; end if;
  if start_at < now() - interval '5 minutes' or start_at > now() + interval '14 days' then raise exception 'start'; end if;
  steps := greatest(1, (hours * 60) / interval_min);
  st := greatest(1, ceil((start_price - floor_price)::numeric / steps)::int);
  insert into items(title, story, cond, new_price, start_price, step, interval_min, start_at, end_at, photos, area, ship)
  values (title, coalesce(story,''), coalesce(cond,'良好'), new_price, start_price, st, interval_min, start_at,
          start_at + make_interval(hours => hours), coalesce(photos,'{}'), coalesce(area,''), coalesce(ship,'賣貨便'))
  returning id into nid;
  insert into item_private(item_id, floor_price, seller_contact) values (nid, floor_price, seller_contact);
  return nid;
end $$;

create or replace function claim(item uuid, name text, contact text)
returns table(price int, seller_contact text, ship text)
language plpgsql security definer set search_path = public as $$
declare i items; p item_private; pr int;
begin
  if auth.uid() is null then raise exception 'login'; end if;
  if char_length(coalesce(contact,'')) < 2 then raise exception 'contact'; end if;
  if (select count(*) from items where buyer = auth.uid() and sold_at > now() - interval '24 hours') >= 3 then raise exception 'limit'; end if;
  select * into i from items where id = item for update;
  if not found or i.status <> 'live' then raise exception 'gone'; end if;
  if i.seller = auth.uid() then raise exception 'own'; end if;
  if now() < i.start_at then raise exception 'early'; end if;
  select * into p from item_private where item_id = item;
  pr := _price(i, p.floor_price);
  update items set status = 'sold', sold_price = pr, sold_at = now(), buyer = auth.uid() where id = item;
  update item_private set buyer_name = left(name, 30), buyer_contact = left(contact, 120) where item_id = item;
  return query select pr, p.seller_contact, i.ship;
end $$;

create or replace function my_items() returns table(
  id uuid, title text, status text, start_price int, floor_price int, sold_price int, sold_at timestamptz,
  role text, other_name text, other_contact text, photos text[])
language sql security definer set search_path = public stable as $$
  select i.id, i.title, i.status, i.start_price, case when i.seller = auth.uid() then p.floor_price end, i.sold_price, i.sold_at,
    case when i.seller = auth.uid() then 'sell' else 'buy' end,
    case when i.seller = auth.uid() then p.buyer_name else null end,
    case when i.seller = auth.uid() then p.buyer_contact else p.seller_contact end, i.photos
  from items i join item_private p on p.item_id = i.id
  where i.seller = auth.uid() or i.buyer = auth.uid()
  order by i.created_at desc
$$;

create or replace function relist(item uuid) returns void language plpgsql security definer set search_path = public as $$
declare dur interval;
begin
  select end_at - start_at into dur from items where id = item and seller = auth.uid() and status = 'sold';
  if dur is null then raise exception 'no'; end if;
  update items set status = 'live', buyer = null, sold_price = null, sold_at = null, start_at = now(), end_at = now() + dur where id = item;
  update item_private set buyer_name = null, buyer_contact = null where item_id = item;
end $$;

create or replace function remove_item(item uuid) returns void language sql security definer set search_path = public as $$
  update items set status = 'removed' where id = item and seller = auth.uid()
$$;

create or replace function report(item uuid) returns void language sql security definer set search_path = public as $$
  update items set reports = reports + 1, status = case when reports + 1 >= 3 then 'removed' else status end where id = item
$$;

grant execute on function prices, create_item, claim, my_items, relist, remove_item, report to anon, authenticated;

-- photos bucket: public read, signed-in (incl. anonymous) upload, 1 MB max, images only
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('photos','photos', true, 1048576, array['image/jpeg','image/webp','image/png'])
on conflict (id) do nothing;
drop policy if exists photos_up on storage.objects;
create policy photos_up on storage.objects for insert to authenticated with check (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);

alter publication supabase_realtime add table items;
