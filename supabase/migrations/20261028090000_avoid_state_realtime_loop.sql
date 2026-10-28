-- Avoid turning read-only state polls into Realtime broadcast loops.

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
 if p_action <> 'state' then update game_rooms set last_active_at=now() where id=r.id; end if;
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

