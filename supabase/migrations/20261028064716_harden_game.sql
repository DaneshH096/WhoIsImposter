create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create or replace function private.is_room_member(p_room uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.game_players
    where room_id = p_room and player_id = auth.uid()
  )
$$;
revoke all on function private.is_room_member(uuid) from public, anon;
grant execute on function private.is_room_member(uuid) to authenticated;

drop policy if exists "room members can receive public room changes" on public.game_rooms;
create policy "room members can receive public room changes"
on public.game_rooms for select to authenticated
using (private.is_room_member(id));

drop function if exists public.is_room_member(uuid);

create index if not exists game_clues_room_player_idx on public.game_clues(room_id, player_id);
create index if not exists game_roles_room_player_idx on public.game_roles(room_id, player_id);
create index if not exists game_votes_room_voter_idx on public.game_votes(room_id, voter_id);
create index if not exists game_votes_room_target_idx on public.game_votes(room_id, target_id);
