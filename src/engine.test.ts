import { describe, expect, it } from 'vitest';
import { assignRoles, canJoin, nextPhase, phaseSeconds, resolveVote, scoreRound, type Phase, type Player } from './engine';
const players: Player[] = [{id:'a',nickname:'A',score:0},{id:'b',nickname:'B',score:0},{id:'c',nickname:'C',score:0},{id:'d',nickname:'D',score:0}];
describe('authoritative game rules', () => {
  it('treats a tie as no accusation and impostor survival', () => { expect(resolveVote({a:'b',b:'a',c:'b',d:'a'}, 'd', players.map(p=>p.id))).toMatchObject({accusedId:null,impostorSurvived:true}); });
  it('awards correct votes and impostor survival and guess points', () => { expect(scoreRound(players,'d',{a:'d',b:'d',c:'a',d:'a'},true).scores).toEqual({a:2,b:2,c:0,d:3}); });
  it('does not award survival when the impostor is uniquely accused', () => { expect(scoreRound(players,'d',{a:'d',b:'d',c:'d',d:'a'},false).scores.d).toBe(0); });
  it('enforces the 4–8 player range at room creation and join time', () => { expect(()=>assignRoles(['a','b','c'],'a','X','Y')).toThrow(); expect(canJoin('lobby',7)).toBe(true); expect(canJoin('lobby',8)).toBe(false); expect(canJoin('clue',4)).toBe(false); });
  it('assigns one impostor and isolates the role-specific word', () => { const roles=assignRoles(['a','b','c','d'],'d','PIZZA','TACO'); expect(Object.values(roles).filter(p=>p.role==='impostor')).toHaveLength(1); expect(roles.d).toEqual({role:'impostor',word:'TACO'}); expect(roles.a).toEqual({role:'detective',word:'PIZZA'}); expect(JSON.stringify(roles.d)).not.toContain('PIZZA'); });
  it('uses the configured server phase durations and sequence', () => { expect(phaseSeconds).toEqual({reveal:15,clue:60,discussion:60,voting:30,results:15}); expect((['reveal','clue','discussion','voting','results'] as Phase[]).reduce((_,p)=>nextPhase(p,3),'reveal' as Phase)).toBe('finished'); });
  it('completes all three rounds and ends in final results', () => { let phase:Phase='lobby'; let round=0; for(let i=0;i<3;i++){round++;phase='reveal';for(const p of ['reveal','clue','discussion','voting','results'] as const)phase=nextPhase(p,round); if(phase==='lobby')phase='reveal';} expect(round).toBe(3);expect(phase).toBe('finished'); });
});
