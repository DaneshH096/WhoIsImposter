create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_cron;

create type public.game_phase as enum ('lobby','reveal','clue','discussion','voting','results','finished');
create table public.game_rooms (
 id uuid primary key default gen_random_uuid(),
 code text not null unique check (code ~ '^[A-Z2-9]{6}$'),
 phase public.game_phase not null default 'lobby',
 round smallint not null default 0 check (round between 0 and 3),
 deadline timestamptz,
 host_id uuid not null,
 created_at timestamptz not null default now(),
 last_active_at timestamptz not null default now()
);
create table public.game_players (
 room_id uuid not null references public.game_rooms(id) on delete cascade,
 player_id uuid not null,
 nickname text not null check (char_length(nickname) between 2 and 20),
 score integer not null default 0 check(score >= 0),
 joined_at timestamptz not null default now(),
 last_seen timestamptz not null default now(),
 primary key(room_id,player_id), unique(room_id,nickname)
);
create table public.game_roles (
 room_id uuid not null references public.game_rooms(id) on delete cascade,
 round smallint not null,
 player_id uuid not null,
 role text not null check(role in ('detective','impostor')),
 word text not null,
 impostor_word text not null,
 primary key(room_id,round,player_id),
 foreign key(room_id,player_id) references public.game_players(room_id,player_id) on delete cascade
);
create table public.game_clues (
 room_id uuid not null references public.game_rooms(id) on delete cascade,
 round smallint not null,
 player_id uuid not null,
 clue text not null check(char_length(clue) between 1 and 40),
 created_at timestamptz not null default now(),
 primary key(room_id,round,player_id),
 foreign key(room_id,player_id) references public.game_players(room_id,player_id) on delete cascade
);
create table public.game_votes (
 room_id uuid not null references public.game_rooms(id) on delete cascade,
 round smallint not null,
 voter_id uuid not null,
 target_id uuid not null,
 guess text check(guess is null or char_length(guess) <= 30),
 created_at timestamptz not null default now(),
 primary key(room_id,round,voter_id),
 check(voter_id <> target_id),
 foreign key(room_id,voter_id) references public.game_players(room_id,player_id) on delete cascade,
 foreign key(room_id,target_id) references public.game_players(room_id,player_id) on delete cascade
);
create table public.game_round_results (
 room_id uuid not null references public.game_rooms(id) on delete cascade,
 round smallint not null,
 payload jsonb not null,
 settled_at timestamptz not null default now(),
 primary key(room_id,round)
);
create table public.game_rate_limits (
 player_id uuid not null,
 minute_bucket timestamptz not null,
 hits integer not null default 0,
 primary key(player_id,minute_bucket)
);
alter table public.game_rate_limits enable row level security;

alter table public.game_rooms enable row level security;
alter table public.game_players enable row level security;
alter table public.game_roles enable row level security;
alter table public.game_clues enable row level security;
alter table public.game_votes enable row level security;
alter table public.game_round_results enable row level security;
create or replace function public.is_room_member(p_room uuid) returns boolean language sql stable security definer set search_path=public as $$ select exists(select 1 from game_players where room_id=p_room and player_id=auth.uid()) $$;
revoke all on function public.is_room_member(uuid) from public,anon;
grant execute on function public.is_room_member(uuid) to authenticated;
create policy "room members can receive public room changes" on public.game_rooms for select to authenticated using (public.is_room_member(id));
revoke all on public.game_rooms,public.game_players,public.game_roles,public.game_clues,public.game_votes,public.game_round_results,public.game_rate_limits from anon,authenticated;
grant select on public.game_rooms to authenticated;
alter publication supabase_realtime add table public.game_rooms;

create or replace function public._room_view(p_room uuid,p_player uuid) returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
declare r game_rooms; view_state jsonb; myrole jsonb;
begin
 select * into r from game_rooms where id=p_room;
 select jsonb_build_object('code',r.code,'phase',r.phase,'round',r.round,'deadline',r.deadline,
  'players',coalesce((select jsonb_agg(jsonb_build_object('id',p.player_id,'nickname',p.nickname,'score',p.score,'is_host',(p.player_id=r.host_id)) order by p.joined_at) from game_players p where p.room_id=r.id),'[]'::jsonb),
  'clues',case when r.phase in ('discussion','voting','results','finished') or (r.phase='clue' and not exists(select 1 from game_clues c where c.room_id=r.id and c.round=r.round)) then coalesce((select jsonb_agg(jsonb_build_object('player_id',c.player_id,'nickname',p.nickname,'clue',c.clue) order by c.created_at) from game_clues c join game_players p using(room_id,player_id) where c.room_id=r.id and c.round=r.round),'[]'::jsonb) else '[]'::jsonb end,
  'voted_count',(select count(*) from game_votes v where v.room_id=r.id and v.round=r.round)) into view_state;
 if r.phase='results' or r.phase='finished' then view_state:=view_state||jsonb_build_object('result',(select payload from game_round_results where room_id=r.id and round=r.round)); end if;
 select jsonb_build_object('role',role,'word',case when role='impostor' then impostor_word else word end) into myrole from game_roles where room_id=r.id and round=r.round and player_id=p_player;
 return jsonb_build_object('state',view_state,'role',myrole);
end $$;

create or replace function public._settle_round(p_room uuid) returns void language plpgsql security definer set search_path=public,extensions as $$
declare r game_rooms; imp uuid; word text; impword text; accused uuid; max_votes integer; ties integer; correct_guess boolean; result jsonb; player record;
begin
 select * into r from game_rooms where id=p_room for update;
 if r.phase <> 'voting' or exists(select 1 from game_round_results where room_id=r.id and round=r.round) then return; end if;
 select player_id,gr.word,gr.impostor_word into imp,word,impword from game_roles gr where room_id=r.id and round=r.round and role='impostor';
 select target_id,count(*)::int into accused,max_votes from game_votes where room_id=r.id and round=r.round group by target_id order by count(*) desc limit 1;
 select count(*) into ties from (select target_id from game_votes where room_id=r.id and round=r.round group by target_id having count(*)=max_votes) z;
 if ties<>1 then accused:=null; end if;
 select exists(select 1 from game_votes where room_id=r.id and round=r.round and voter_id=imp and lower(trim(guess))=lower(word)) into correct_guess;
 for player in select * from game_players where room_id=r.id loop
  if player.player_id=imp then update game_players set score=score + case when accused is distinct from imp then 2 else 0 end + case when correct_guess then 1 else 0 end where room_id=r.id and player_id=imp;
  elsif exists(select 1 from game_votes where room_id=r.id and round=r.round and voter_id=player.player_id and target_id=imp) then update game_players set score=score+2 where room_id=r.id and player_id=player.player_id; end if;
 end loop;
 result:=jsonb_build_object('accused_id',accused,'impostor_id',imp,'word',word,'impostor_word',impword,'guess_correct',correct_guess,
  'scores',(select jsonb_object_agg(player_id,score) from game_players where room_id=r.id));
 insert into game_round_results(room_id,round,payload) values(r.id,r.round,result) on conflict do nothing;
 update game_rooms set phase='results',deadline=now()+interval '15 seconds',last_active_at=now() where id=r.id;
end $$;

create or replace function public.game_action(p_action text,p_uid uuid,p_code text default null,p_nickname text default null,p_clue text default null,p_target uuid default null,p_guess text default null)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare r game_rooms; newcode text; imp uuid; rate_hits integer; words text[]:=array['PIZZA','UMBRELLA','GUITAR','PENGUIN','COFFEE','VOLCANO','POPCORN','DINOSAUR','LIBRARY','UNICORN','SANDWICH','ROBOT']; pairs text[]:=array['TACO','RAINCOAT','BANJO','PUFFIN','TEA','GEYSER','NACHOS','DRAGON','MUSEUM','DRAGON','BURGER','ALIEN']; chosen integer;
begin
 insert into game_rate_limits(player_id,minute_bucket,hits) values(p_uid,date_trunc('minute',now()),1)
 on conflict(player_id,minute_bucket) do update set hits=game_rate_limits.hits+1 returning hits into rate_hits;
 if rate_hits>60 then raise exception 'Too many requests. Please wait a minute and try again.'; end if;
 if p_action='create' then
  if p_nickname is null or char_length(trim(p_nickname)) not between 2 and 20 then raise exception 'Nickname must be 2–20 characters'; end if;
  for i in 1..8 loop newcode:=translate(substr(upper(encode(gen_random_bytes(5),'hex')),1,6),'018','ABZ');
   begin insert into game_rooms(code,host_id) values(newcode,p_uid) returning * into r; exit; exception when unique_violation then if i=8 then raise exception 'Could not make a room code. Please try again.'; end if; end;
  end loop;
  insert into game_players(room_id,player_id,nickname) values(r.id,p_uid,trim(p_nickname)); return _room_view(r.id,p_uid);
 elsif p_action='join' then
  select * into r from game_rooms where code=upper(p_code) for update;
  if not found then raise exception 'That room code was not found.'; end if;
  if r.phase <> 'lobby' then raise exception 'This game is already in progress.'; end if;
  if (select count(*) from game_players where room_id=r.id)>=8 then raise exception 'This room is full (8 players max).'; end if;
  if p_nickname is null or char_length(trim(p_nickname)) not between 2 and 20 then raise exception 'Nickname must be 2–20 characters'; end if;
  insert into game_players(room_id,player_id,nickname) values(r.id,p_uid,trim(p_nickname)) on conflict(room_id,player_id) do update set last_seen=now();
  return _room_view(r.id,p_uid);
 end if;
 select rr.* into r from game_rooms rr where rr.code=upper(p_code) and exists(select 1 from game_players gp where gp.room_id=rr.id and gp.player_id=p_uid) for update of rr;
 if not found then raise exception 'You are not a member of this room. Rejoin with the room code.'; end if;
 update game_players set last_seen=now() where room_id=r.id and player_id=p_uid;
 if r.host_id<>p_uid and exists(select 1 from game_players where room_id=r.id and player_id=r.host_id and last_seen<now()-interval '30 seconds') then
  update game_rooms set host_id=(select player_id from game_players where room_id=r.id and last_seen>=now()-interval '30 seconds' order by joined_at limit 1) where id=r.id;
  select * into r from game_rooms where id=r.id;
 end if;
 update game_rooms set last_active_at=now() where id=r.id;
 if r.deadline is not null and r.deadline<=now() then
  if r.phase='reveal' then update game_rooms set phase='clue',deadline=now()+interval '60 seconds' where id=r.id;
  elsif r.phase='clue' then update game_rooms set phase='discussion',deadline=now()+interval '60 seconds' where id=r.id;
  elsif r.phase='discussion' then update game_rooms set phase='voting',deadline=now()+interval '30 seconds' where id=r.id;
  elsif r.phase='voting' then perform _settle_round(r.id);
  elsif r.phase='results' then update game_rooms set phase=case when round>=3 then 'finished'::game_phase else 'lobby'::game_phase end,deadline=null where id=r.id; end if;
  select * into r from game_rooms where id=r.id;
 end if;
 if p_action='state' then return _room_view(r.id,p_uid); end if;
 if p_action='start_round' then
  if r.host_id<>p_uid or r.phase<>'lobby' then raise exception 'Only the host can start a round from the lobby.'; end if;
  if (select count(*) from game_players where room_id=r.id)<4 then raise exception 'You need at least 4 players to start.'; end if;
  if r.round>=3 then raise exception 'This match is already complete.'; end if;
  chosen:=(get_byte(gen_random_bytes(1),0)%array_length(words,1))+1;
  select player_id into imp from game_players where room_id=r.id order by encode(gen_random_bytes(16),'hex') limit 1;
  insert into game_roles(room_id,round,player_id,role,word,impostor_word) select r.id,r.round+1,player_id,case when player_id=imp then 'impostor' else 'detective' end,words[chosen],pairs[chosen] from game_players where room_id=r.id;
  update game_rooms set phase='reveal',round=round+1,deadline=now()+interval '15 seconds',last_active_at=now() where id=r.id;
 elsif p_action='clue' then
  if r.phase<>'clue' or r.deadline<=now() then raise exception 'Clue time has ended.'; end if;
  if p_clue is null or char_length(trim(p_clue)) not between 1 and 40 then raise exception 'A clue must be 1–40 characters.'; end if;
  begin insert into game_clues(room_id,round,player_id,clue) values(r.id,r.round,p_uid,trim(p_clue)); exception when unique_violation then raise exception 'You already submitted a clue this round.'; end;
  if (select count(*) from game_clues where room_id=r.id and round=r.round)=(select count(*) from game_players where room_id=r.id) then update game_rooms set phase='discussion',deadline=now()+interval '60 seconds' where id=r.id; end if;
 elsif p_action='vote' then
  if r.phase<>'voting' or r.deadline<=now() then raise exception 'Voting has ended.'; end if;
  if p_target=p_uid then raise exception 'You cannot vote for yourself.'; end if;
  if not exists(select 1 from game_players where room_id=r.id and player_id=p_target) then raise exception 'That player is not in this room.'; end if;
  if nullif(trim(p_guess),'') is not null and not exists(select 1 from game_roles where room_id=r.id and round=r.round and player_id=p_uid and role='impostor') then raise exception 'Only the impostor can guess the detectives’ word.'; end if;
  begin insert into game_votes(room_id,round,voter_id,target_id,guess) values(r.id,r.round,p_uid,p_target,nullif(trim(p_guess),'')); exception when unique_violation then raise exception 'You already voted this round.'; end;
  if (select count(*) from game_votes where room_id=r.id and round=r.round)=(select count(*) from game_players where room_id=r.id) then perform _settle_round(r.id); end if;
 else raise exception 'Unknown game action.'; end if;
 select * into r from game_rooms where id=r.id;
 return _room_view(r.id,p_uid);
end $$;
revoke all on function public.game_action(text,uuid,text,text,text,uuid,text) from public,anon,authenticated;
grant execute on function public.game_action(text,uuid,text,text,text,uuid,text) to service_role;
revoke all on function public._room_view(uuid,uuid),public._settle_round(uuid) from public,anon,authenticated;

create or replace function public.advance_expired_rooms() returns void language plpgsql security definer set search_path=public,extensions as $$
declare r record;
begin
 for r in select id,phase from game_rooms where deadline<=now() and phase<>'lobby' and phase<>'finished' loop
  if r.phase='voting' then perform _settle_round(r.id);
  elsif r.phase='reveal' then update game_rooms set phase='clue',deadline=now()+interval '60 seconds' where id=r.id and phase='reveal' and deadline<=now();
  elsif r.phase='clue' then update game_rooms set phase='discussion',deadline=now()+interval '60 seconds' where id=r.id and phase='clue' and deadline<=now();
  elsif r.phase='discussion' then update game_rooms set phase='voting',deadline=now()+interval '30 seconds' where id=r.id and phase='discussion' and deadline<=now();
  elsif r.phase='results' then update game_rooms set phase=case when round>=3 then 'finished'::game_phase else 'lobby'::game_phase end,deadline=null where id=r.id and phase='results' and deadline<=now(); end if;
 end loop;
 update game_rooms room set host_id=(select player_id from game_players where room_id=room.id and last_seen>=now()-interval '30 seconds' order by joined_at limit 1)
  where exists(select 1 from game_players hp where hp.room_id=room.id and hp.player_id=room.host_id and hp.last_seen<now()-interval '30 seconds')
  and exists(select 1 from game_players np where np.room_id=room.id and np.last_seen>=now()-interval '30 seconds');
 delete from game_rooms where last_active_at < now()-interval '24 hours';
 delete from game_rate_limits where minute_bucket<now()-interval '2 hours';
end $$;
revoke all on function public.advance_expired_rooms() from public,anon,authenticated;
select cron.schedule('advance-impostor-phases','1 second','select public.advance_expired_rooms()') where not exists(select 1 from cron.job where jobname='advance-impostor-phases');
