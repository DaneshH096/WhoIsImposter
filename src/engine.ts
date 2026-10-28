export type Phase = 'lobby' | 'reveal' | 'clue' | 'discussion' | 'voting' | 'results' | 'finished';
export type Player = { id: string; nickname: string; score: number };
export const phaseSeconds = { reveal: 15, clue: 60, discussion: 60, voting: 30, results: 15 } as const;
export function canJoin(phase: Phase, playerCount: number) { return phase === 'lobby' && playerCount < 8; }
export function nextPhase(phase: Phase, round: number): Phase {
  if (phase === 'reveal') return 'clue';
  if (phase === 'clue') return 'discussion';
  if (phase === 'discussion') return 'voting';
  if (phase === 'voting') return 'results';
  if (phase === 'results') return round >= 3 ? 'finished' : 'lobby';
  return phase;
}
export function assignRoles(playerIds: string[], impostorId: string, word: string, relatedWord: string) {
  if (playerIds.length < 4 || playerIds.length > 8 || !playerIds.includes(impostorId)) throw new Error('Invalid room roster');
  return Object.fromEntries(playerIds.map(id => [id, { role: id === impostorId ? 'impostor' : 'detective', word: id === impostorId ? relatedWord : word }]));
}
export function resolveVote(votes: Record<string, string>, impostorId: string, playerIds: string[]) {
  const counts = new Map<string, number>();
  for (const target of Object.values(votes)) if (playerIds.includes(target)) counts.set(target, (counts.get(target) ?? 0) + 1);
  const max = Math.max(0, ...counts.values());
  const winners = [...counts].filter(([, count]) => count === max && max > 0).map(([id]) => id);
  const accusedId = winners.length === 1 ? winners[0] : null;
  return { counts: Object.fromEntries(counts), accusedId, impostorSurvived: accusedId !== impostorId };
}
export function scoreRound(players: Player[], impostorId: string, votes: Record<string,string>, guessCorrect: boolean) {
  const result = resolveVote(votes, impostorId, players.map(p => p.id));
  const scores = Object.fromEntries(players.map(p => [p.id, p.score + (p.id === impostorId ? (result.impostorSurvived ? 2 : 0) + (guessCorrect ? 1 : 0) : (votes[p.id] === impostorId ? 2 : 0))]));
  return { ...result, scores };
}
