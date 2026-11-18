-- Disposable staging/local database ONLY, outside migrations.
-- Example: PGOPTIONS="-c matching.environment=development" psql -v ON_ERROR_STOP=1 -f server/fixtures/blind_shanghai_dev.sql ...
begin;
do $$ begin
  if coalesce(current_setting('matching.environment',true),'') not in ('development','test') then
    raise exception 'Development environment flag required for fictional venues';
  end if;
end $$;
update matching.blind_venue_policy set demo_enabled=true where singleton;
insert into matching.blind_venues(id,name,address,atmosphere,weekdays,opens,closes,is_public,accessible,safety_reviewed,verified_until,demo)
values
 ('b1000000-0000-4000-8000-000000000001','开发测试 · 虚构咖啡馆','虚构地点，请勿前往','quiet','{1,2,3,4,5,6,7}','08:00','22:00',true,true,true,now()+interval '90 days',true),
 ('b1000000-0000-4000-8000-000000000002','开发测试 · 虚构活动厅','虚构地点，请勿前往','lively','{1,2,3,4,5,6,7}','09:00','21:00',true,true,true,now()+interval '90 days',true)
on conflict(id) do nothing;
insert into matching.blind_reach(venue,area,distance_km) values
 ('b1000000-0000-4000-8000-000000000001','静安',1), ('b1000000-0000-4000-8000-000000000001','徐汇',4),
 ('b1000000-0000-4000-8000-000000000001','黄浦',3), ('b1000000-0000-4000-8000-000000000001','长宁',4),
 ('b1000000-0000-4000-8000-000000000001','浦东',12),
 ('b1000000-0000-4000-8000-000000000002','静安',4), ('b1000000-0000-4000-8000-000000000002','徐汇',5),
 ('b1000000-0000-4000-8000-000000000002','黄浦',1), ('b1000000-0000-4000-8000-000000000002','长宁',8),
 ('b1000000-0000-4000-8000-000000000002','浦东',8)
on conflict(venue,area) do nothing;
commit;
