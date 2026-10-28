import { test, expect } from '@playwright/test';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { readFileSync } from 'node:fs';

function readLocalEnv(){
  try{return Object.fromEntries(readFileSync('.env.local','utf8').split(/\r?\n/).filter(line=>line.includes('=')).map(line=>{const i=line.indexOf('=');return[line.slice(0,i),line.slice(i+1).trim().replace(/^['"]|['"]$/g,'')]})) as Record<string,string>}
  catch{return {} as Record<string,string>}
}
const env={...readLocalEnv(),...process.env};
const live=env.RUN_LIVE_GAME_TESTS==='true'&&!!env.VITE_SUPABASE_URL&&!!env.VITE_SUPABASE_ANON_KEY;
const createPlayer=async(nickname:string)=>{
  const client:SupabaseClient=createClient(env.VITE_SUPABASE_URL,env.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data,error}=await client.auth.signInAnonymously();if(error)throw error;
  return {client,id:data.user.id,nickname};
};
const action=async(player:Awaited<ReturnType<typeof createPlayer>>,name:string,fields:Record<string,unknown>={})=>{
  const {data,error}=await player.client.functions.invoke('game',{body:{action:name,...fields}});
  let message=data?.error as string|undefined;
  if(error&&'context' in error&&error.context instanceof Response){try{message=(await error.context.clone().json() as {error?:string}).error??message}catch{}}
  return {data,error,message};
};
const name=(label:string)=>`${label}${Math.random().toString(36).slice(2,7)}`.slice(0,20);

test('live API enforces host ownership, removal, reconnection and private roles',{skip:!live},async()=>{
  const players=await Promise.all(['Host','GuestA','GuestB','GuestC','GuestD','Late'].map(label=>createPlayer(name(label))));
  const host=players[0];
  const created=await action(host,'create',{nickname:host.nickname});
  expect(created.error??created.message).toBeFalsy();
  const code=created.data.state.code as string;
  expect(created.data.state.players.find((p:{id:string})=>p.id===host.id)?.is_host).toBe(true);
  for(const player of players.slice(1,5)){
    const joined=await action(player,'join',{nickname:player.nickname,code});
    expect(joined.error??joined.message).toBeFalsy();
  }
  const nonHostStart=await action(players[1],'start_round',{code});
  expect(nonHostStart.message).toMatch(/only the current host/i);
  const nonHostKick=await action(players[1],'kick',{code,target_id:players[2].id});
  expect(nonHostKick.message).toMatch(/only the current host/i);
  const selfKick=await action(host,'kick',{code,target_id:host.id});
  expect(selfKick.message).toMatch(/cannot remove themselves/i);
  const removed=await action(host,'kick',{code,target_id:players[4].id});
  expect(removed.error??removed.message).toBeFalsy();
  for(const [player,verb,fields] of [
    [players[4],'state',{}],
    [players[4],'join',{nickname:players[4].nickname}],
    [players[4],'clue',{clue:'sneaky'}],
    [players[4],'vote',{target_id:host.id}],
  ] as const){
    const denied=await action(player,verb,{code,...fields});
    expect(denied.message).toMatch(/removed by the host/i);
  }
  const started=await action(host,'start_round',{code});
  expect(started.error??started.message).toBeFalsy();
  expect(started.data.role?.word).toBeTruthy();
  expect(JSON.stringify(started.data.state)).not.toContain(started.data.role.word);
  expect(started.data.state.players).toHaveLength(4);
  const lateJoin=await action(players[5],'join',{nickname:players[5].nickname,code});
  expect(lateJoin.message).toMatch(/already in progress/i);
});

test('live API serializes joins and caps rooms at eight players',{skip:!live},async()=>{
  const people=await Promise.all(Array.from({length:10},(_,i)=>createPlayer(name(`Capacity${i}`))));
  const host=people[0];
  const created=await action(host,'create',{nickname:host.nickname});
  expect(created.error??created.message).toBeFalsy();
  const code=created.data.state.code as string;
  const attempts=await Promise.all(people.slice(1).map(player=>action(player,'join',{nickname:player.nickname,code})));
  expect(attempts.filter(result=>!result.error&&!result.message)).toHaveLength(7);
  expect(attempts.filter(result=>/full/i.test(result.message??'')).length).toBe(2);
  const state=await action(host,'state',{code});
  expect(state.data.state.players).toHaveLength(8);
});

