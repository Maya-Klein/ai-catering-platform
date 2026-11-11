-- Split customer contact details and event details out of orders (docs/DATABASE_SCHEMA.md):
--   customers  1 ──< events  1 ──1 orders
--   orders.customer_id and orders.event_id replace the contact_* and event_* columns.
-- customers.auth_user_id links a customer to a signed-in Supabase Auth user (nullable: OPEN #1 is not
-- decided, so guest checkout through orders.access_token_hash keeps working).
-- Existing orders are migrated: each one gets its own customer and event row.

-- ============================================================================
-- New tables
-- ============================================================================

create table public.customers (
  id            text primary key default gen_random_uuid()::text,
  auth_user_id  uuid unique references auth.users(id) on delete set null,  -- null = guest
  full_name     text,                     -- may be empty while the order is a draft
  phone         text,
  email         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table public.events (
  id                 text primary key default gen_random_uuid()::text,
  customer_id        text    not null references public.customers(id) on delete cascade,
  event_type_id      integer not null references public.event_types(id),
  event_date         date    not null,
  adults             integer not null check (adults >= 1),
  children           integer not null default 0 check (children >= 0),
  vegetarian_guests  integer not null default 0 check (vegetarian_guests >= 0),
  vegan_guests       integer not null default 0 check (vegan_guests >= 0),
  restricted_guests  integer not null default 0 check (restricted_guests >= 0),
  dietary_notes      text,                -- free text for the owner; never parsed into safety claims
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (id, customer_id)                -- target of the composite FK from orders
);
create index idx_events_customer   on public.events (customer_id);
create index idx_events_event_type on public.events (event_type_id);
create index idx_events_event_date on public.events (event_date);

-- ============================================================================
-- Move existing order data into the new tables
-- ============================================================================

alter table public.orders add column customer_id text, add column event_id text;

do $$
declare
  o   record;
  cid text;
  eid text;
begin
  for o in select * from public.orders loop
    insert into public.customers (full_name, phone, created_at)
    values (o.contact_name, o.contact_phone, o.created_at)
    returning id into cid;

    insert into public.events (customer_id, event_type_id, event_date, adults, children,
                               vegetarian_guests, vegan_guests, restricted_guests, dietary_notes, created_at)
    values (cid, o.event_type_id, o.event_date, o.adults, o.children,
            o.vegetarian_guests, o.vegan_guests, o.restricted_guests, o.dietary_notes, o.created_at)
    returning id into eid;

    update public.orders set customer_id = cid, event_id = eid where id = o.id;
  end loop;
end $$;

-- ============================================================================
-- Rewire orders
-- ============================================================================

-- The old "submitted order is complete" check mentions contact_name/contact_phone. Dropping those columns
-- would silently drop the whole check, so drop it explicitly and re-add it without the contact columns.
do $$
declare c record;
begin
  for c in
    select conname from pg_constraint
    where conrelid = 'public.orders'::regclass and contype = 'c'
      and pg_get_constraintdef(oid) like '%contact_name%'
  loop
    execute format('alter table public.orders drop constraint %I', c.conname);
  end loop;
end $$;

alter table public.orders
  drop column contact_name,
  drop column contact_phone,
  drop column event_type_id,
  drop column event_date,
  drop column adults,
  drop column children,
  drop column vegetarian_guests,
  drop column vegan_guests,
  drop column restricted_guests,
  drop column dietary_notes;

alter table public.orders
  alter column customer_id set not null,
  alter column event_id    set not null,
  add constraint orders_customer_fk foreign key (customer_id) references public.customers(id),
  add constraint orders_event_unique unique (event_id),   -- one order per event
  -- The event must belong to the same customer as the order.
  add constraint orders_event_fk foreign key (event_id, customer_id)
    references public.events(id, customer_id),
  add constraint orders_submitted_complete check (
    status = 'draft'
    or (submitted_at is not null and subtotal is not null and delivery_fee is not null and total is not null)
  );
create index idx_orders_customer on public.orders (customer_id);

-- A submitted order needs the customer's name and phone. This spans two tables, so it is a trigger.
create or replace function public.check_order_contact()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status <> 'draft' and not exists (
    select 1 from public.customers c
    where c.id = new.customer_id and c.full_name is not null and c.phone is not null
  ) then
    raise exception 'order % cannot leave draft: customer name and phone are required', new.id
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
revoke execute on function public.check_order_contact() from public, anon, authenticated;

create trigger orders_contact_required
  before insert or update of status, customer_id on public.orders
  for each row execute function public.check_order_contact();

-- ============================================================================
-- Row Level Security
-- ============================================================================

-- Helpers in a schema the Data API does not expose. SECURITY DEFINER lets them read customers/orders
-- without going through those tables' own policies (avoids recursion).
create schema if not exists private;
grant usage on schema private to authenticated;

create or replace function private.current_customer_id()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select id from public.customers where auth_user_id = (select auth.uid());
$$;

create or replace function private.owns_order(p_order_id text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.orders
    where id = p_order_id and customer_id = (select private.current_customer_id())
  );
$$;

revoke execute on function private.current_customer_id(), private.owns_order(text) from public, anon;
grant  execute on function private.current_customer_id(), private.owns_order(text) to authenticated;

alter table public.customers enable row level security;
alter table public.events    enable row level security;

grant select on public.customers, public.events to authenticated;

-- Read only. All writes go through the backend (secret key, bypasses RLS) - ADR 0003.
create policy "admin read" on public.customers for select to authenticated
  using ((select public.is_admin()));
create policy "admin read" on public.events for select to authenticated
  using ((select public.is_admin()));

-- A signed-in customer reads only their own rows.
create policy "customer read own" on public.customers for select to authenticated
  using (auth_user_id = (select auth.uid()));
create policy "customer read own" on public.events for select to authenticated
  using (customer_id = (select private.current_customer_id()));
create policy "customer read own" on public.orders for select to authenticated
  using (customer_id = (select private.current_customer_id()));
create policy "customer read own" on public.order_items for select to authenticated
  using ((select private.owns_order(order_id)));
create policy "customer read own" on public.order_status_events for select to authenticated
  using ((select private.owns_order(order_id)));
create policy "customer read own" on public.ai_proposals for select to authenticated
  using ((select private.owns_order(order_id)));
-- Internal tool payloads stay hidden from customers.
create policy "customer read own" on public.ai_messages for select to authenticated
  using (role in ('user', 'assistant') and (select private.owns_order(order_id)));
