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
  let lobbyPollTimer = null;

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

  // Pseudo de l'AUTRE joueur de cette lobby (celui qui n'est pas nous),
  // pour l'afficher a cote de sa main une fois la partie lancee -- null en
  // cas d'echec (lobby pas encore active, reseau...), jamais bloquant :
  // l'appelant doit simplement ne rien afficher dans ce cas plutot que de
  // planter la mise en relation.
  async function getOpponentPseudo(lobbyId){
    const sb = await getClient();
    const { data: { user } } = await sb.auth.getUser();
    if(!user) return null;
    const { data: lobby, error: lobbyErr } = await sb
      .from('lobbies').select('joueur1, joueur2').eq('id', lobbyId).maybeSingle();
    if(lobbyErr || !lobby) { console.warn('[DaniszOnline] getOpponentPseudo lobby fetch failed', lobbyErr); return null; }
    const opponentId = lobby.joueur1 === user.id ? lobby.joueur2 : lobby.joueur1;
    if(!opponentId) return null;
    const { data: profile, error: profileErr } = await sb
      .from('profiles').select('pseudo').eq('id', opponentId).maybeSingle();
    if(profileErr || !profile) { console.warn('[DaniszOnline] getOpponentPseudo profile fetch failed', profileErr); return null; }
    return profile.pseudo;
  }

  // Rapporte le resultat d'une partie 1v1 en ligne terminee -- Elo calcule
  // et applique cote serveur (voir report_online_match() dans
  // schema_online.sql), jamais par le client. p_i_won est du point de vue
  // de L'APPELANT (auth.uid()) : pas besoin de connaitre l'uuid Supabase de
  // l'adversaire, la fonction le retrouve via la lobby. Seul l'HOTE doit
  // appeler ceci (voir maybeReportMatchResult dans index.html) -- jamais
  // l'invite, sinon le meme resultat serait compte deux fois.
  // { ok:true, eloDelta, myEloAfter } ou { error:'unknown' }.
  async function reportMatchResult(lobbyId, iWon, tours){
    const sb = await getClient();
    const { data, error } = await sb.rpc('report_online_match', {
      p_lobby_id: lobbyId, p_i_won: iWon, p_tours: tours
    });
    if(error){ console.warn('[DaniszOnline] report_online_match failed', error); return { error: 'unknown' }; }
    const row = data[0];
    return {
      ok: true,
      eloDelta: iWon ? row.elo_delta : -row.elo_delta,
      myEloAfter: iWon ? row.winner_elo_after : row.loser_elo_after
    };
  }

  // Ecoute UNE lobby precise (celle qu'on vient de creer) : cb(row) est
  // appele des qu'un adversaire la rejoint (UPDATE -> status='active').
  // Utilise par le joueur en ATTENTE seulement (celui qui a matched=false
  // ou qui vient de create_invite_lobby) -- l'autre le sait deja tout de
  // suite via la reponse de join_random_queue/join_invite_lobby.
  //
  // Deux filets de securite, constate en usage reel (queue aleatoire ou
  // les deux joueurs cliquent "chercher" a quelques secondes d'ecart --
  // avec un code d'invitation, le delai humain pour le transmettre/taper
  // masquait le probleme) :
  //   1. On attend que l'abonnement Realtime soit VRAIMENT actif (SUBSCRIBED)
  //      avant de considerer qu'on ecoute -- sinon un adversaire qui rejoint
  //      dans cette toute petite fenetre (souscription encore en cours) voit
  //      son UPDATE tout simplement jamais livre, Realtime ne rejoue pas les
  //      evenements manques pour un abonnement qui n'etait pas encore pret.
  //   2. Sondage de secours (toutes les 2.5s) en plus du canal Realtime :
  //      si jamais Realtime rate quand meme la notification (coupure reseau,
  //      onglet mis en arriere-plan sur mobile...), on la detecte quand meme
  //      au prochain sondage plutot que de rester bloque indefiniment.
  async function watchLobby(lobbyId, cb){
    const sb = await getClient();
    await stopWatching();
    let fired = false;
    const fireOnce = row => { if(fired) return; fired = true; cb(row); };
    lobbyWatchChannel = sb.channel('lobby-watch-' + lobbyId)
      .on('postgres_changes',
        { event: 'UPDATE', schema: 'public', table: 'lobbies', filter: 'id=eq.' + lobbyId },
        payload => fireOnce(payload.new));
    await new Promise(resolve=>{
      lobbyWatchChannel.subscribe(status=>{ if(status==='SUBSCRIBED') resolve(); });
    });
    lobbyPollTimer = setInterval(async ()=>{
      if(fired){ clearInterval(lobbyPollTimer); lobbyPollTimer = null; return; }
      const { data } = await sb.from('lobbies').select('*').eq('id', lobbyId).maybeSingle();
      if(data && data.status === 'active') fireOnce(data);
    }, 2500);
    return lobbyWatchChannel;
  }

  async function stopWatching(){
    if(lobbyPollTimer){ clearInterval(lobbyPollTimer); lobbyPollTimer = null; }
    if(lobbyWatchChannel){
      const sb = await getClient();
      sb.removeChannel(lobbyWatchChannel);
      lobbyWatchChannel = null;
    }
  }

  /* =========================================================
     Compteur "X en ligne / Y en file d'attente" affiche sur l'ecran de
     matchmaking. Deux sources bien distinctes :
     - "en ligne" : Presence Realtime, un canal partage que chaque client
       sur cet ecran rejoint (track()) -- aucune table, purement ephemere,
       le nombre de membres du canal EST le nombre de joueurs presents.
     - "en file d'attente" : la table lobbies elle-meme, via un compte
       agrege cote serveur (voir get_queue_count() dans schema_online.sql)
       puisque RLS empeche un client de voir les lobbies des autres --
       pas de flux temps reel possible pour ce nombre-la (RLS filtre aussi
       les evenements postgres_changes), donc sondage ponctuel plutot que
       souscription.
     ========================================================= */
  let presenceChannel = null;

  // cb(count) est appele a chaque changement de presence (quelqu'un
  // arrive/repart de l'ecran de matchmaking). Idempotent : un appel
  // repete relance proprement (utile si l'ecran est revisite).
  async function joinPresence(cb){
    const sb = await getClient();
    await leavePresence();
    const key = (window.crypto && crypto.randomUUID) ? crypto.randomUUID() : ('p' + Math.random().toString(36).slice(2));
    presenceChannel = sb.channel('online-lobby-presence', { config: { presence: { key } } });
    presenceChannel.on('presence', { event: 'sync' }, () => {
      const state = presenceChannel.presenceState();
      cb(Object.keys(state).length);
    });
    await new Promise(resolve=>{
      presenceChannel.subscribe(async status=>{
        if(status==='SUBSCRIBED'){
          await presenceChannel.track({ at: Date.now() });
          resolve();
        }
      });
    });
  }

  async function leavePresence(){
    if(presenceChannel){
      const sb = await getClient();
      sb.removeChannel(presenceChannel);
      presenceChannel = null;
    }
  }

  // Nombre de joueurs actuellement en file d'attente aleatoire publique
  // (hors lobbies a code d'invitation). 0 en cas d'erreur reseau, plutot
  // que de casser l'affichage pour un simple compteur secondaire.
  async function getQueueCount(){
    const sb = await getClient();
    const { data, error } = await sb.rpc('get_queue_count');
    if(error){ console.warn('[DaniszOnline] get_queue_count failed', error); return 0; }
    return data || 0;
  }

  /* =========================================================
     PHASE 2 : synchronisation de partie (une fois la lobby active).
     Modele HOTE-AUTORITAIRE : joueur1 (l'hote) fait tourner le vrai
     moteur de regles (le meme que solo vs IA -- l'adversaire distant est
     traite exactement comme "l'IA", sauf que son coup vient du reseau au
     lieu d'etre calcule localement). joueur2 (l'invite) n'envoie que des
     PROPOSITIONS de coup et attend le resultat officiel de l'hote pour
     animer -- il ne fait jamais tourner playGroup/forceTakePile lui-meme,
     pour ne jamais risquer de diverger de l'etat de l'hote.

     Canal Realtime "broadcast" (pas postgres_changes, trop lent pour ca)
     nomme par lobbyId : seuls les 2 joueurs de cette lobby connaissent cet
     UUID, donc pas de canal partage/devinable entre parties differentes.
     broadcast.self:false : on ne recoit jamais nos propres messages.
     ========================================================= */
  let gameChannel = null;

  // handlers = { onMove(move), onState(payload), onReady() }
  //   onMove  : recu cote HOTE seulement -- l'invite propose un coup.
  //   onState : recu cote INVITE seulement -- l'hote diffuse le resultat
  //             officiel (nouvel etat + le "res" a animer).
  //   onReady : recu cote HOTE seulement -- l'invite signale qu'il ecoute
  //             (l'hote peut alors distribuer les cartes et diffuser l'etat
  //             initial en toute securite, sans risquer que l'invite l'ait
  //             manque en n'etant pas encore abonne au canal).
  async function joinGameChannel(lobbyId, handlers){
    const sb = await getClient();
    await leaveGameChannel();
    gameChannel = sb.channel('game-' + lobbyId, { config: { broadcast: { self: false } } })
      .on('broadcast', { event: 'move' }, ({ payload }) => { if(handlers.onMove) handlers.onMove(payload); })
      .on('broadcast', { event: 'state' }, ({ payload }) => { if(handlers.onState) handlers.onState(payload); })
      .on('broadcast', { event: 'ready' }, () => { if(handlers.onReady) handlers.onReady(); });
    await new Promise(resolve=>{ gameChannel.subscribe(status=>{ if(status==='SUBSCRIBED') resolve(); }); });
    return gameChannel;
  }

  // Signale qu'on ecoute -- seul l'invite doit appeler ceci (voir onReady
  // cote hote ci-dessus).
  function announceReady(){
    if(gameChannel) gameChannel.send({ type:'broadcast', event:'ready', payload:{} });
  }

  // Invite -> hote : "je voudrais faire ce coup". move = {kind, cardIds|cardId}.
  function sendMove(move){
    if(gameChannel) gameChannel.send({ type:'broadcast', event:'move', payload: move });
  }

  // Hote -> invite : resultat officiel (nouvel etat + res a animer).
  function sendState(payload){
    if(gameChannel) gameChannel.send({ type:'broadcast', event:'state', payload });
  }

  async function leaveGameChannel(){
    if(gameChannel){
      const sb = await getClient();
      sb.removeChannel(gameChannel);
      gameChannel = null;
    }
  }

  window.DaniszOnline = {
    joinRandomQueue, leaveQueue, createInviteLobby, joinInviteLobby, watchLobby, stopWatching, getOpponentPseudo, reportMatchResult,
    joinPresence, leavePresence, getQueueCount,
    joinGameChannel, announceReady, sendMove, sendState, leaveGameChannel
  };
})();
