/* =========================================================
   1v1 en ligne — PHASE 1 : matchmaking + lobby uniquement (voir
   supabase/schema_online.sql). Fait se rencontrer deux joueurs (file
   d'attente aleatoire ou code d'invitation) et leur donne un lobbyId
   commun. Ne gere PAS encore la synchronisation des coups de la partie
   elle-meme -- ca viendra une fois cette base testee et solide.

   Script classique (meme convention que js/account.js), reutilise le
   MEME client Supabase (via DaniszAccount.getClient()) plutot que d'en
   creer un second : deux clients independants desynchroniseraient l'etat
   d'auth en memoire (le localStorage est partage, pas l'etat JS).
   ========================================================= */
(function(){
  let supabase = null;
  let lobbyWatchChannel = null;

  async function getClient(){
    if(supabase) return supabase;
    if(!window.DaniszAccount) throw new Error('[DaniszOnline] DaniszAccount (js/account.js) doit etre charge avant js/online.js');
    supabase = await window.DaniszAccount.getClient();
    return supabase;
  }

  // { ok:true, lobbyId, matched:boolean } ou { error:'unknown' }
  // matched=true si on a rejoint quelqu'un qui attendait deja ; false si
  // on est maintenant soi-meme en attente (watchLobby() pour la suite).
  async function joinRandomQueue(){
    const sb = await getClient();
    const { data, error } = await sb.rpc('join_random_queue');
    if(error){ console.warn('[DaniszOnline] join_random_queue failed', error); return { error: 'unknown' }; }
    const row = data[0];
    return { ok: true, lobbyId: row.lobby_id, matched: row.opponent_joined };
  }

  async function leaveQueue(){
    const sb = await getClient();
    const { error } = await sb.rpc('leave_queue');
    if(error) console.warn('[DaniszOnline] leave_queue failed', error);
  }

  // { ok:true, lobbyId, code } ou { error:'unknown' }
  async function createInviteLobby(){
    const sb = await getClient();
    const { data, error } = await sb.rpc('create_invite_lobby');
    if(error){ console.warn('[DaniszOnline] create_invite_lobby failed', error); return { error: 'unknown' }; }
    const row = data[0];
    return { ok: true, lobbyId: row.lobby_id, code: row.code };
  }

  // { ok:true, lobbyId, opponentId } ou { error:'notFound'|'ownLobby'|'unknown' }
  async function joinInviteLobby(code){
    const sb = await getClient();
    const { data, error } = await sb.rpc('join_invite_lobby', { p_code: (code || '').trim() });
    if(error){
      if(error.message === 'lobby_not_found') return { error: 'notFound' };
      if(error.message === 'cannot_join_own_lobby') return { error: 'ownLobby' };
      console.warn('[DaniszOnline] join_invite_lobby failed', error);
      return { error: 'unknown' };
    }
    const row = data[0];
    return { ok: true, lobbyId: row.lobby_id, opponentId: row.joueur1 };
  }

  // Ecoute UNE lobby precise (celle qu'on vient de creer) : cb(row) est
  // appele des qu'un adversaire la rejoint (UPDATE -> status='active').
  // Utilise par le joueur en ATTENTE seulement (celui qui a matched=false
  // ou qui vient de create_invite_lobby) -- l'autre le sait deja tout de
  // suite via la reponse de join_random_queue/join_invite_lobby.
  async function watchLobby(lobbyId, cb){
    const sb = await getClient();
    await stopWatching();
    lobbyWatchChannel = sb
      .channel('lobby-watch-' + lobbyId)
      .on('postgres_changes',
        { event: 'UPDATE', schema: 'public', table: 'lobbies', filter: 'id=eq.' + lobbyId },
        payload => cb(payload.new))
      .subscribe();
    return lobbyWatchChannel;
  }

  async function stopWatching(){
    if(lobbyWatchChannel){
      const sb = await getClient();
      sb.removeChannel(lobbyWatchChannel);
      lobbyWatchChannel = null;
    }
  }

  window.DaniszOnline = { joinRandomQueue, leaveQueue, createInviteLobby, joinInviteLobby, watchLobby, stopWatching };
})();
