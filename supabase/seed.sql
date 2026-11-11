-- Demo data for yumm.ai. Safe to inspect; not run automatically on the hosted project.
insert into public.event_types (name, sort_order) values ('יום הולדת',1),('חתונה',2),('אירוע חברה',3),('בר/בת מצווה',4) on conflict do nothing;
insert into public.delivery_zones (city, fee) values ('תל אביב',4000),('רמת גן',3500),('חיפה',8000) on conflict do nothing;
insert into public.time_slots (fulfillment, start_time, end_time) values
  ('pickup','10:00','12:00'),('pickup','16:00','18:00'),('delivery','12:00','14:00'),('delivery','17:00','19:00') on conflict do nothing;
insert into public.dish_categories (slug, name, sort_order) values ('salads','סלטים',1),('mains','עיקריות',2),('desserts','קינוחים',3) on conflict do nothing;
insert into public.allergens (name) values ('גלוטן'),('אגוזים'),('חלב'),('שומשום') on conflict do nothing;

insert into public.dishes (id, category_id, name, description, pricing_unit, unit_price, kashrut, is_vegetarian, is_vegan)
select v.id, c.id, v.name, v.descr, v.unit, v.price, v.kashrut, v.veg, v.vegan
from (values
  ('demo-salad-1','salads','סלט ירקות קצוץ','עגבניה, מלפפון ובצל סגול','tray',12000,'pareve',true,true),
  ('demo-main-1','mains','חזה עוף בתנור','עם עשבי תיבול ולימון','tray',32000,'meat',false,false),
  ('demo-main-2','mains','לזניה ירקות','גבינות ורוטב עגבניות','tray',28000,'dairy',true,false),
  ('demo-dessert-1','desserts','עוגת שוקולד','פרווה, 12 מנות','item',9000,'pareve',true,true)
) as v(id, cat, name, descr, unit, price, kashrut, veg, vegan)
join public.dish_categories c on c.slug = v.cat
on conflict do nothing;

-- Guest customer (no auth_user_id) with one event and one order.
insert into public.customers (id, full_name, phone) values ('demo-customer-1','דנה כהן','050-1234567')
on conflict do nothing;

insert into public.events (id, customer_id, event_type_id, event_date, adults, children)
select 'demo-event-1','demo-customer-1', e.id, current_date + 7, 20, 5
from public.event_types e where e.name = 'יום הולדת'
on conflict do nothing;

insert into public.orders (id, access_token_hash, customer_id, event_id, status,
  fulfillment, slot_id, slot_start, slot_end, subtotal, delivery_fee, total, submitted_at)
select 'demo-order-1','demo-token-hash-1','demo-customer-1','demo-event-1','pending_approval',
  'pickup', s.id, s.start_time, s.end_time, 74000, 0, 74000, now()
from public.time_slots s
where s.fulfillment = 'pickup' and s.start_time = '16:00'
on conflict do nothing;

insert into public.order_items (order_id, dish_id, quantity, snapshot_name, snapshot_pricing_unit, snapshot_unit_price, snapshot_line_total) values
  ('demo-order-1','demo-salad-1',2,'סלט ירקות קצוץ','tray',12000,24000),
  ('demo-order-1','demo-main-1',1,'חזה עוף בתנור','tray',32000,32000),
  ('demo-order-1','demo-dessert-1',2,'עוגת שוקולד','item',9000,18000)
on conflict do nothing;
insert into public.order_status_events (order_id, from_status, to_status, actor) values
  ('demo-order-1', null, 'draft', 'customer'), ('demo-order-1','draft','pending_approval','customer');
