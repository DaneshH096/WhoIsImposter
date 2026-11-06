-- Open shared rules before each round, allow voluntary exit with host transfer,
-- and reject clues that reveal the submitting player's secret word.
alter table public.game_rooms add column if not exists rules_open boolean not null default false;

create or replace function public._room_view(p_room uuid,p_player uuid) returns jsonb
language plpgsql security definer set search_path=public,extensions as $$
declare r game_rooms; view_state jsonb; myrole jsonb;
begin
 select * into r from game_rooms where id=p_room;
 select jsonb_build_object(
  'code',r.code,'phase',r.phase,'round',r.round,'deadline',r.deadline,'server_now',now(),'rules_open',r.rules_open,
  'players',coalesce((select jsonb_agg(jsonb_build_object('id',p.player_id,'nickname',p.nickname,'score',p.score,'is_host',(p.player_id=r.host_id),'online',(p.last_seen>=now()-interval '20 seconds'),'removed',(p.removed_at is not null)) order by p.joined_at,p.player_id) from game_players p where p.room_id=p_room and (p.removed_at is null or r.phase in ('results','finished'))),'[]'::jsonb),
  'clues',case when r.phase in ('discussion','voting','results','finished') or (r.phase='clue' and not exists(select 1 from game_clues c join game_players gp using(room_id,player_id) where c.room_id=p_room and c.round=r.round and gp.removed_at is null)) then coalesce((select jsonb_agg(jsonb_build_object('player_id',c.player_id,'nickname',p.nickname,'clue',c.clue) order by c.created_at) from game_clues c join game_players p using(room_id,player_id) where c.room_id=p_room and c.round=r.round and p.removed_at is null),'[]'::jsonb) else '[]'::jsonb end,
  'voted_count',(select count(*) from game_votes v join game_players p on p.room_id=v.room_id and p.player_id=v.voter_id where v.room_id=p_room and v.round=r.round and p.removed_at is null)) into view_state;
 if r.phase in ('results','finished') then view_state:=view_state||jsonb_build_object('result',(select payload from game_round_results where room_id=p_room and round=r.round)); end if;
 select jsonb_build_object('role',role,'word',case when role='impostor' then impostor_word else word end) into myrole from game_roles where room_id=p_room and round=r.round and player_id=p_player;
 return jsonb_build_object('state',view_state,'role',myrole);
end $$;

create or replace function public.game_action(p_action text,p_uid uuid,p_code text default null,p_nickname text default null,p_clue text default null,p_target uuid default null,p_guess text default null)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare r game_rooms; existing_player game_players; newcode text; imp uuid; next_host uuid; rate_hits integer; active_count integer; words text[]:=array['PIZZA','UMBRELLA','GUITAR','PENGUIN','COFFEE','VOLCANO','POPCORN','DINOSAUR','LIBRARY','UNICORN','SANDWICH','ROBOT']; pairs text[]:=array['TACO','RAINCOAT','BANJO','PUFFIN','TEA','GEYSER','NACHOS','DRAGON','MUSEUM','DRAGON','BURGER','ALIEN']; chosen integer; target_is_impostor boolean; secret_word text; normalized_clue text;
begin
 insert into game_rate_limits(player_id,minute_bucket,hits) values(p_uid,date_trunc('minute',now()),1)
 on conflict(player_id,minute_bucket) do update set hits=game_rate_limits.hits+1 returning hits into rate_hits;
 if rate_hits>60 then raise exception 'Too many requests. Please wait a minute and try again.'; end if;
 if p_action='create' then
  if p_nickname is null or char_length(trim(p_nickname)) not between 2 and 20 then raise exception 'Nickname must be 2–20 characters.'; end if;
  for i in 1..8 loop newcode:=translate(substr(upper(encode(gen_random_bytes(5),'hex')),1,6),'018','ABZ');
   begin insert into game_rooms(code,host_id) values(newcode,p_uid) returning * into r; exit; exception when unique_violation then if i=8 then raise exception 'Could not make a room code. Please try again.'; end if; end;
  end loop;
  insert into game_players(room_id,player_id,nickname) values(r.id,p_uid,trim(p_nickname)); return _room_view(r.id,p_uid);
 elsif p_action='join' then
  select * into r from game_rooms where code=upper(p_code) for update;
  if not found then raise exception 'That room code was not found. It may have expired.'; end if;
  select * into existing_player from game_players where room_id=r.id and player_id=p_uid for update;
  if found then
   if existing_player.removed_at is not null then raise exception 'You were removed by the host and cannot rejoin this room.'; end if;
   update game_players set last_seen=now() where room_id=r.id and player_id=p_uid;
   update game_rooms set last_active_at=now() where id=r.id;
   return _room_view(r.id,p_uid);
  end if;
  if r.phase<>'lobby' then raise exception 'This game is already in progress and cannot accept new players.'; end if;
  if (select count(*) from game_players where room_id=r.id and removed_at is null)>=8 then raise exception 'This room is full (8 players max).'; end if;
  if p_nickname is null or char_length(trim(p_nickname)) not between 2 and 20 then raise exception 'Nickname must be 2–20 characters.'; end if;
  insert into game_players(room_id,player_id,nickname) values(r.id,p_uid,trim(p_nickname));
  update game_rooms set last_active_at=now() where id=r.id;
  return _room_view(r.id,p_uid);
 end if;
 select rr.* into r from game_rooms rr where rr.code=upper(p_code) and exists(select 1 from game_players gp where gp.room_id=rr.id and gp.player_id=p_uid) for update of rr;
 if not found then
  if exists(select 1 from game_players gp join game_rooms rr on rr.id=gp.room_id where rr.code=upper(p_code) and gp.player_id=p_uid and gp.removed_at is not null) then raise exception 'You were removed by the host from this room.'; end if;
  raise exception 'You are not a member of this room. Rejoin with the room code.';
 end if;
 select * into existing_player from game_players where room_id=r.id and player_id=p_uid for update;
 if existing_player.removed_at is not null then raise exception 'You were removed by the host from this room.'; end if;
 update game_players set last_seen=now() where room_id=r.id and player_id=p_uid;
 if p_action<>'state' then update game_rooms set last_active_at=now() where id=r.id; end if;
 if r.deadline is not null and r.deadline<=now() then
  if r.phase='reveal' then update game_rooms set phase='clue',deadline=now()+interval '60 seconds' where id=r.id;
  elsif r.phase='clue' then update game_rooms set phase='discussion',deadline=now()+interval '60 seconds' where id=r.id;
  elsif r.phase='discussion' then update game_rooms set phase='voting',deadline=now()+interval '30 seconds' where id=r.id;
  elsif r.phase='voting' then perform _settle_round(r.id);
  elsif r.phase='results' then update game_rooms set phase=case when round>=3 then 'finished'::game_phase else 'lobby'::game_phase end,deadline=null,rules_open=false where id=r.id; end if;
  select * into r from game_rooms where id=r.id;
 end if;
 if p_action='state' then return _room_view(r.id,p_uid); end if;

 if p_action='start_round' then
  if r.host_id<>p_uid or r.phase<>'lobby' then raise exception 'Only the current host can open round rules from the lobby.'; end if;
  select count(*) into active_count from game_players where room_id=r.id and removed_at is null;
  if active_count<2 then raise exception 'You need at least 2 active players to start.'; end if;
  if r.round>=3 then raise exception 'This match is already complete.'; end if;
  update game_rooms set rules_open=true,last_active_at=now() where id=r.id;
 elsif p_action='begin_round' then
  if r.host_id<>p_uid or r.phase<>'lobby' or not r.rules_open then raise exception 'Only the current host can start the round after reviewing the rules.'; end if;
  select count(*) into active_count from game_players where room_id=r.id and removed_at is null;
  if active_count<2 then raise exception 'You need at least 2 active players to start.'; end if;
  if r.round>=3 then raise exception 'This match is already complete.'; end if;
  chosen:=(get_byte(gen_random_bytes(1),0)%array_length(words,1))+1;
  select player_id into imp from game_players where room_id=r.id and removed_at is null order by encode(gen_random_bytes(16),'hex') limit 1;
  insert into game_roles(room_id,round,player_id,role,word,impostor_word) select r.id,r.round+1,player_id,case when player_id=imp then 'impostor' else 'detective' end,words[chosen],pairs[chosen] from game_players where room_id=r.id and removed_at is null;
  update game_rooms set phase='reveal',round=round+1,deadline=now()+interval '15 seconds',rules_open=false,last_active_at=now() where id=r.id;
 elsif p_action='clue' then
  if r.phase<>'clue' or r.deadline<=now() then raise exception 'Clue time has ended.'; end if;
  if p_clue is null or char_length(trim(p_clue)) not between 1 and 40 then raise exception 'A clue must be 1–40 characters.'; end if;
  select case when role='impostor' then impostor_word else word end into secret_word from game_roles where room_id=r.id and round=r.round and player_id=p_uid;
  if secret_word is null then raise exception 'Your secret word is unavailable for this round.'; end if;
  normalized_clue:=regexp_replace(lower(trim(p_clue)),'[^[:alnum:]]+',' ','g');
  if normalized_clue ~ ('(^| )'||regexp_replace(lower(secret_word),'[^[:alnum:]]+',' ','g')||'( |$)') then raise exception 'Your clue cannot mention your secret word. Hint around it instead.'; end if;
  begin insert into game_clues(room_id,round,player_id,clue) values(r.id,r.round,p_uid,trim(p_clue)); exception when unique_violation then raise exception 'You already submitted a clue this round.'; end;
  select count(*) into active_count from game_players where room_id=r.id and removed_at is null;
  if (select count(*) from game_clues c join game_players p using(room_id,player_id) where c.room_id=r.id and c.round=r.round and p.removed_at is null)=active_count then update game_rooms set phase='discussion',deadline=now()+interval '60 seconds' where id=r.id; end if;
 elsif p_action='vote' then
  if r.phase<>'voting' or r.deadline<=now() then raise exception 'Voting has ended.'; end if;
  if p_target=p_uid then raise exception 'You cannot vote for yourself.'; end if;
  if not exists(select 1 from game_players where room_id=r.id and player_id=p_target and removed_at is null) then raise exception 'That player is not active in this room.'; end if;
  if nullif(trim(p_guess),'') is not null and not exists(select 1 from game_roles where room_id=r.id and round=r.round and player_id=p_uid and role='impostor') then raise exception 'Only the impostor can guess the detectives’ word.'; end if;
  begin insert into game_votes(room_id,round,voter_id,target_id,guess) values(r.id,r.round,p_uid,p_target,nullif(trim(p_guess),'')); exception when unique_violation then raise exception 'You already voted this round.'; end;
  select count(*) into active_count from game_players where room_id=r.id and removed_at is null;
  if (select count(*) from game_votes v join game_players p on p.room_id=v.room_id and p.player_id=v.voter_id where v.room_id=r.id and v.round=r.round and p.removed_at is null)=active_count then perform _settle_round(r.id); end if;
 elsif p_action='kick' then
  if r.host_id<>p_uid then raise exception 'Only the current host can remove players.'; end if;
  if p_target is null or p_target=p_uid then raise exception 'The host cannot remove themselves.'; end if;
  select exists(select 1 from game_roles where room_id=r.id and round=r.round and player_id=p_target and role='impostor') into target_is_impostor;
  update game_players set removed_at=now() where room_id=r.id and player_id=p_target and removed_at is null;
  if not found then raise exception 'That player is no longer active in this room.'; end if;
  delete from game_votes where room_id=r.id and round=r.round and voter_id=p_target;
  select count(*) into active_count from game_players where room_id=r.id and removed_at is null;
  if r.phase='lobby' and r.rules_open and active_count<2 then update game_rooms set rules_open=false where id=r.id; end if;
  if r.phase in ('reveal','clue','discussion','voting') and (target_is_impostor or active_count<2) then
   update game_rooms set phase='voting',deadline=now(),last_active_at=now() where id=r.id;
   perform _settle_round(r.id);
  else
   update game_rooms set last_active_at=now() where id=r.id;
   if r.phase='clue' then
    if active_count<2 then update game_rooms set phase='voting',deadline=now() where id=r.id; perform _settle_round(r.id);
    elsif (select count(*) from game_clues c join game_players p using(room_id,player_id) where c.room_id=r.id and c.round=r.round and p.removed_at is null)=active_count then update game_rooms set phase='discussion',deadline=now()+interval '60 seconds' where id=r.id; end if;
   elsif r.phase='voting' and active_count>0 and (select count(*) from game_votes v join game_players p on p.room_id=v.room_id and p.player_id=v.voter_id where v.room_id=r.id and v.round=r.round and p.removed_at is null)=active_count then perform _settle_round(r.id);
   end if;
  end if;
 elsif p_action='leave' then
  select exists(select 1 from game_roles where room_id=r.id and round=r.round and player_id=p_uid and role='impostor') into target_is_impostor;
  update game_players set removed_at=now() where room_id=r.id and player_id=p_uid and removed_at is null;
  if not found then raise exception 'You already left this room.'; end if;
  delete from game_votes where room_id=r.id and round=r.round and voter_id=p_uid;
  select count(*) into active_count from game_players where room_id=r.id and removed_at is null;
  if r.host_id=p_uid then
   select player_id into next_host from game_players where room_id=r.id and removed_at is null order by joined_at,player_id limit 1;
   if next_host is null then delete from game_rooms where id=r.id; return jsonb_build_object('left',true,'room_closed',true); end if;
   update game_rooms set host_id=next_host,last_active_at=now() where id=r.id;
  else update game_rooms set last_active_at=now() where id=r.id; end if;
  if active_count=0 then delete from game_rooms where id=r.id; return jsonb_build_object('left',true,'room_closed',true); end if;
  if r.phase='lobby' and r.rules_open and active_count<2 then update game_rooms set rules_open=false where id=r.id; end if;
  if r.phase in ('reveal','clue','discussion','voting') and (target_is_impostor or active_count<2) then
   update game_rooms set phase='voting',deadline=now(),last_active_at=now() where id=r.id;
   perform _settle_round(r.id);
  else
   if r.phase='clue' then
    if active_count<2 then update game_rooms set phase='voting',deadline=now() where id=r.id; perform _settle_round(r.id);
    elsif (select count(*) from game_clues c join game_players p using(room_id,player_id) where c.room_id=r.id and c.round=r.round and p.removed_at is null)=active_count then update game_rooms set phase='discussion',deadline=now()+interval '60 seconds' where id=r.id; end if;
   elsif r.phase='voting' and active_count>0 and (select count(*) from game_votes v join game_players p on p.room_id=v.room_id and p.player_id=v.voter_id where v.room_id=r.id and v.round=r.round and p.removed_at is null)=active_count then perform _settle_round(r.id);
   end if;
  end if;
  return jsonb_build_object('left',true,'room_closed',false);
 else raise exception 'Unknown game action.'; end if;
 select * into r from game_rooms where id=r.id;
 return _room_view(r.id,p_uid);
end $$;

