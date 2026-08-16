/* =========================================================
   Comptes + high scores (Supabase) — voir supabase/schema.sql
   pour le schema/RLS/RPC correspondants cote serveur.

   Script classique (pas de <script type="module">) pour rester dans le
   meme style que le reste du projet (tout en portee globale, pas de build
   step) : le seul usage d'ES modules est l'import() dynamique du client
   Supabase depuis un CDN, ce qui marche aussi bien dans un script classique
   qu'un module.

   Expose window.DaniszAccount, utilise par le script du jeu (index.html)
   pour : creer un compte (email+mdp+pseudo) ou se reconnecter, remonter le
   resultat d'une partie offline vs IA, et lire le classement. Ne bloque
   jamais le mode offline : tant qu'aucun compte n'est cree, tout ici est un
   no-op silencieux.

   La persistance de session (pas de reconnexion a chaque refresh/session)
   est geree par supabase-js lui-meme par defaut (session + refresh token
   stockes dans localStorage, rafraichis automatiquement) : aucun code
   supplementaire necessaire ici pour ca.
   ========================================================= */
(function(){
  const SUPABASE_URL = 'https://ksvebremcgolmnsgrxla.supabase.co';
  const SUPABASE_ANON_KEY = 'sb_publishable_9YCQz5Tklc6fFEVy-fF2fg_aVQHxqb0';

  let supabase = null;
  let ready = false;
  const state = { session: null, profile: null };
  const listeners = [];

  function notify(){
    listeners.forEach(fn=>{ try{ fn(state); }catch(e){ console.error(e); } });
  }

  async function loadProfile(){
    if(!state.session){ state.profile = null; return null; }
    const { data, error } = await supabase
      .from('profiles').select('*').eq('id', state.session.user.id).maybeSingle();
    if(error){ console.warn('[DaniszAccount] profile load failed', error); return null; }
    state.profile = data;
    return data;
  }

  async function init(){
    if(supabase) return;
    const { createClient } = await import('https://esm.sh/@supabase/supabase-js@2');
    supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
    const { data } = await supabase.auth.getSession();
    state.session = data.session;
    if(state.session) await loadProfile();
    ready = true;
    notify();
    supabase.auth.onAuthStateChange(async (_event, session)=>{
      state.session = session;
      await loadProfile();
      notify();
    });
  }

  // { ok:true } ou { error: 'length'|'emailTaken'|'weakPassword'|'invalidEmail'|
  //                          'confirmEmail'|'pseudoTaken'|'unknown' }
  async function signUp(pseudo, email, password){
    pseudo = (pseudo || '').trim();
    if(pseudo.length < 3 || pseudo.length > 20) return { error: 'length' };
    await init();
    const { data, error } = await supabase.auth.signUp({ email, password });
    if(error){
      if(error.code === 'weak_password') return { error: 'weakPassword' };
      if(error.code === 'user_already_exists' || error.code === 'email_exists') return { error: 'emailTaken' };
      if(error.code === 'validation_failed' || error.code === 'email_address_invalid') return { error: 'invalidEmail' };
      console.warn('[DaniszAccount] sign-up failed', error);
      return { error: 'unknown' };
    }
    // Supabase renvoie un succes "vide" (identities:[]) pour une adresse deja
    // enregistree quand la confirmation email est activee, pour ne pas
    // reveler quels emails existent deja -- on le traduit quand meme en
    // erreur lisible plutot que de laisser croire qu'un compte a ete cree.
    if(data.user && Array.isArray(data.user.identities) && data.user.identities.length===0){
      return { error: 'emailTaken' };
    }
    if(!data.session){
      // Confirmation email activee cote dashboard : pas de session tant que
      // le lien du mail n'est pas clique, donc pas encore de auth.uid()
      // pour creer la ligne profiles. Le pseudo sera demande de nouveau a la
      // premiere connexion confirmee.
      return { error: 'confirmEmail' };
    }
    state.session = data.session;
    const { error: profileError } = await supabase.from('profiles').insert({ id: state.session.user.id, pseudo });
    if(profileError){
      if(profileError.code === '23505') return { error: 'pseudoTaken' };
      console.warn('[DaniszAccount] profile creation failed', profileError);
      return { error: 'unknown' };
    }
    await loadProfile();
    notify();
    return { ok: true };
  }

  // { ok:true } ou { error: 'invalidCredentials'|'unknown' }
  async function signIn(email, password){
    await init();
    const { data, error } = await supabase.auth.signInWithPassword({ email, password });
    if(error){
      if(error.code === 'invalid_credentials') return { error: 'invalidCredentials' };
      console.warn('[DaniszAccount] sign-in failed', error);
      return { error: 'unknown' };
    }
    state.session = data.session;
    // Compte cree avant l'ajout du pseudo, ou profil jamais finalise apres
    // une confirmation email : redemande un pseudo plutot que de rester
    // bloque en "connecte" sans profil exploitable.
    const profile = await loadProfile();
    notify();
    if(!profile) return { error: 'needsPseudo' };
    return { ok: true };
  }

  // Utilise apres signIn() si needsPseudo, ou pour finir une inscription
  // apres confirmation email : pas besoin de mdp, la session est deja active.
  async function setPseudo(pseudo){
    pseudo = (pseudo || '').trim();
    if(pseudo.length < 3 || pseudo.length > 20) return { error: 'length' };
    if(!state.session) return { error: 'unknown' };
    const { error } = await supabase.from('profiles').insert({ id: state.session.user.id, pseudo });
    if(error){
      if(error.code === '23505') return { error: 'pseudoTaken' };
      console.warn('[DaniszAccount] profile creation failed', error);
      return { error: 'unknown' };
    }
    await loadProfile();
    notify();
    return { ok: true };
  }

  async function signOut(){
    if(!supabase) return;
    await supabase.auth.signOut();
    state.session = null;
    state.profile = null;
    notify();
  }

  // No-op silencieux si aucun profil (mode invite) : le mode offline ne doit
  // jamais dependre de ca pour fonctionner.
  async function reportAiMatch(mode, won, turns){
    if(!supabase || !state.session || !state.profile) return;
    const { error } = await supabase.rpc('record_ai_match', { p_mode: mode, p_won: won, p_turns: turns });
    if(error){ console.warn('[DaniszAccount] report match failed', error); return; }
    state.profile.parties_jouees += 1;
    if(won) state.profile.victoires += 1;
    // +1 par partie terminee, peu importe mode/victoire -- pas encore
    // affichee nulle part, juste tenue a jour en cache pour rester coherente
    // avec la colonne cote serveur.
    state.profile.currency = (state.profile.currency || 0) + 1;
    notify();
  }

  async function fetchLeaderboard(limit){
    await init();
    const { data, error } = await supabase
      .from('profiles')
      .select('pseudo,victoires,parties_jouees')
      .order('victoires', { ascending: false })
      .order('parties_jouees', { ascending: true })
      .limit(limit || 20);
    if(error){ console.warn('[DaniszAccount] leaderboard fetch failed', error); return []; }
    return data;
  }

  // Classement par nombre de tours pour un mode/difficulte precis (parties
  // gagnees uniquement) : ecran de confirmation avant de lancer une partie.
  // profiles(pseudo) tire parti de la FK matches.joueur1 -> profiles.id,
  // que PostgREST embarque automatiquement -- pas besoin d'une 2e requete.
  // Un seul (le meilleur) score par joueur : sinon un joueur tres actif
  // peut a lui seul occuper tout le top 10, ce qui decourage plutot
  // qu'autre chose quiconque decouvre le mode. On recupere un pool plus
  // large que necessaire (200) puisque dedupliquer reduit le compte, puis
  // on ne garde que la premiere occurrence de chaque joueur -- comme le tri
  // est par tours croissant, la premiere occurrence EST son meilleur score.
  async function fetchModeLeaderboard(mode, limit){
    await init();
    const max = limit || 10;
    const { data, error } = await supabase
      .from('matches')
      .select('joueur1, tours, profiles(pseudo)')
      .eq('mode', mode)
      .eq('joueur1_gagne', true)
      .order('tours', { ascending: true })
      .limit(200);
    if(error){ console.warn('[DaniszAccount] mode leaderboard fetch failed', error); return []; }
    const seen = new Set();
    const rows = [];
    for(const row of data){
      if(seen.has(row.joueur1)) continue;
      seen.add(row.joueur1);
      rows.push({ pseudo: row.profiles ? row.profiles.pseudo : '?', tours: row.tours });
      if(rows.length >= max) break;
    }
    return rows;
  }

  function hasAccount(){ return !!(state.session && state.profile); }
  function getState(){ return state; }
  function onChange(fn){ listeners.push(fn); if(ready) fn(state); }

  window.DaniszAccount = { signUp, signIn, signOut, setPseudo, reportAiMatch, fetchLeaderboard, fetchModeLeaderboard, hasAccount, getState, onChange };
  init().catch(e=>console.error('[DaniszAccount] init failed', e));
})();
