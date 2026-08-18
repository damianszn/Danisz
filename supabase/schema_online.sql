-- Danisz — 1v1 en ligne, phase 1 : matchmaking + lobby (PAS encore la partie
-- elle-meme). A coller dans le SQL Editor Supabase et executer, APRES
-- schema.sql (depend de public.profiles).
--
-- Portee de cette phase : faire se rencontrer deux joueurs (file d'attente
-- aleatoire OU code d'invitation) et leur donner un identifiant de lobby
-- commun pour ouvrir un canal Supabase Realtime. La synchronisation des
-- coups de la partie elle-meme est une phase suivante, pas geree ici.
--
-- Validation des coups : cote CLIENT pour ce premier jet (decision prise
-- explicitement) -- chaque client applique le moteur de regles deja isole
-- (resolvePlay, canPlayGroup...) et diffuse le resultat a l'adversaire, sans
-- verification serveur. Un joueur qui modifie son propre client pourrait
-- techniquement tricher -- risque accepte pour un usage entre amis. Porter
-- la validation cote serveur (Edge Function) reste possible plus tard sans
-- casser ce schema.

create table public.lobbies (
  id uuid primary key default gen_random_uuid(),
  -- Code d'invitation a 6 caracteres ; NULL = lobby de la file aleatoire.
  code text unique,
  joueur1 uuid not null references public.profiles(id) on delete cascade,
  joueur2 uuid references public.profiles(id) on delete cascade,
  status text not null default 'waiting', -- 'waiting' | 'active' | 'finished' | 'cancelled'
  created_at timestamptz not null default now()
);

alter table public.lobbies enable row level security;

-- Un joueur ne voit que ses propres lobbies (celles ou il est joueur1 ou
-- joueur2), pas la liste complete -- pas de raison d'exposer qui cherche
-- une partie a tout le monde.
create policy "players see their own lobbies"
  on public.lobbies for select
  using (auth.uid() = joueur1 or auth.uid() = joueur2);

-- Pas de policy insert/update/delete directe : tout passe par les RPC
-- ci-dessous (security definer), meme logique anti-triche que
-- record_ai_match dans schema.sql -- un client ne peut pas s'inserer dans
-- la lobby de quelqu'un d'autre en construisant sa propre requete.

-- ---- File d'attente aleatoire ----
-- Cherche la plus ancienne lobby en attente (sans code) creee par un AUTRE
-- joueur ; la rejoint si trouvee, sinon cree la sienne et attend. FOR UPDATE
-- SKIP LOCKED evite qu'un deuxieme appel concurrent choisisse la meme
-- lobby au meme instant (deux joueurs qui cherchent en meme temps).
create or replace function public.join_random_queue()
returns table(lobby_id uuid, opponent_joined boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_existing public.lobbies%rowtype;
  v_new_id uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  select * into v_existing from public.lobbies
    where status = 'waiting' and code is null and joueur1 <> v_uid
    order by created_at asc
    limit 1
    for update skip locked;

  if found then
    update public.lobbies set joueur2 = v_uid, status = 'active' where id = v_existing.id;
    return query select v_existing.id, true;
    return;
  end if;

  -- Evite les doublons si le joueur relance la recherche plusieurs fois
  -- (double-clic, retour puis re-clic...) sans jamais avoir ete apparie.
  delete from public.lobbies where joueur1 = v_uid and status = 'waiting' and code is null;

  insert into public.lobbies (joueur1, status) values (v_uid, 'waiting') returning id into v_new_id;
  return query select v_new_id, false;
end;
$$;

-- Annule sa propre attente (bouton "Annuler" pendant la recherche).
create or replace function public.leave_queue()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  delete from public.lobbies where joueur1 = auth.uid() and status = 'waiting';
end;
$$;

-- ---- Code d'invitation ----
create or replace function public.create_invite_lobby()
returns table(lobby_id uuid, code text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_code text;
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  delete from public.lobbies where joueur1 = v_uid and status = 'waiting';

  v_code := upper(substr(md5(random()::text), 1, 6));
  insert into public.lobbies (joueur1, status, code) values (v_uid, 'waiting', v_code) returning id into v_id;
  return query select v_id, v_code;
end;
$$;

create or replace function public.join_invite_lobby(p_code text)
returns table(lobby_id uuid, joueur1 uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_lobby public.lobbies%rowtype;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  select * into v_lobby from public.lobbies
    where code = upper(p_code) and status = 'waiting'
    for update;

  if not found then
    raise exception 'lobby_not_found';
  end if;
  if v_lobby.joueur1 = v_uid then
    raise exception 'cannot_join_own_lobby';
  end if;

  update public.lobbies set joueur2 = v_uid, status = 'active' where id = v_lobby.id;
  return query select v_lobby.id, v_lobby.joueur1;
end;
$$;

revoke all on function public.join_random_queue() from public;
revoke all on function public.leave_queue() from public;
revoke all on function public.create_invite_lobby() from public;
revoke all on function public.join_invite_lobby(text) from public;
grant execute on function public.join_random_queue() to authenticated;
grant execute on function public.leave_queue() to authenticated;
grant execute on function public.create_invite_lobby() to authenticated;
grant execute on function public.join_invite_lobby(text) to authenticated;

-- Necessaire pour que le joueur en attente soit notifie en temps reel des
-- que quelqu'un rejoint sa lobby (postgres_changes cote client), plutot que
-- d'avoir a re-interroger la table en boucle.
alter publication supabase_realtime add table public.lobbies;

-- ---- Compteur "X en file d'attente" (ecran de matchmaking) ----
-- Un client ne peut SELECT que ses propres lobbies (voir la policy plus
-- haut), donc pas moyen de compter les lobbies en attente des AUTRES
-- joueurs depuis le client. security definer contourne ca proprement en ne
-- renvoyant qu'un compte agrege -- aucune ligne, aucune identite exposee.
-- Ne compte que la file aleatoire publique (code is null) : une lobby avec
-- un code d'invitation attend un ami precis, pas "n'importe qui". Exclut
-- aussi la propre lobby de l'appelant (joueur1 <> auth.uid()) : sinon un
-- joueur qui vient de lancer sa propre recherche se compte lui-meme comme
-- +1, ce qui n'a pas de sens ("X AUTRES joueurs en attente").
create or replace function public.get_queue_count()
returns integer
language sql
security definer
set search_path = public
as $$
  select count(*)::integer from public.lobbies
  where status = 'waiting' and code is null and joueur1 <> auth.uid();
$$;

revoke all on function public.get_queue_count() from public;
grant execute on function public.get_queue_count() to authenticated;

/* =========================================================
   PHASE 4 : Elo + historique des parties 1v1 en ligne.
   profiles.elo existait deja (colonne prevue des le depart, jamais
   utilisee jusqu'ici) -- rien a ajouter cote profils, juste la table de
   log + la fonction qui la remplit et met a jour les deux elo d'un coup.
   ========================================================= */

create table public.online_matches (
  id bigint generated always as identity primary key,
  lobby_id uuid not null references public.lobbies(id) on delete cascade,
  winner uuid not null references public.profiles(id) on delete cascade,
  loser uuid not null references public.profiles(id) on delete cascade,
  winner_elo_before integer not null,
  loser_elo_before integer not null,
  winner_elo_after integer not null,
  loser_elo_after integer not null,
  tours integer not null,
  created_at timestamptz not null default now()
);

alter table public.online_matches enable row level security;

-- Chacun ne voit que les parties ou il a joue (gagnant ou perdant) -- pas
-- de raison d'exposer l'historique complet de tout le monde.
create policy "players see their own online matches"
  on public.online_matches for select
  using (auth.uid() = winner or auth.uid() = loser);

-- Pas de policy insert/update directe : uniquement via report_online_match()
-- ci-dessous (security definer), meme logique que record_ai_match plus haut
-- -- un client ne peut pas s'auto-declarer vainqueur en ecrivant une ligne
-- a la main, ni modifier son propre elo directement.

-- Calcule et applique l'Elo des deux joueurs d'une lobby a la fin d'une
-- partie 1v1 en ligne, enregistre la ligne d'historique, et renvoie le
-- resultat pour affichage immediat cote appelant si besoin.
--
-- p_i_won est du point de vue de l'APPELANT (auth.uid()) : evite d'avoir a
-- lui faire connaitre l'uuid Supabase de son adversaire (jamais recupere
-- cote client jusqu'ici, voir getOpponentPseudo qui ne renvoie que le
-- pseudo) -- l'adversaire est retrouve ici via la ligne lobbies.
--
-- Modele "cote hote uniquement" : seul l'hote (voir js/online.js,
-- MainScene) appelle cette fonction, jamais l'invite -- eviterait un
-- double comptage si les deux clients rapportaient chacun le meme
-- resultat. Coherent avec le reste de l'architecture 1v1 en ligne (l'hote
-- fait autorite, personne ne valide cote serveur -- "trust the client",
-- deja le choix assume pour les coups eux-memes, voir plus haut dans ce
-- fichier).
--
-- Formule Elo standard, K=32 (assez reactif pour un petit groupe de
-- joueurs, pas une ligue competitive) : delta = round(K * (1 - probabilite
-- de victoire attendue du gagnant avant la partie)). Plancher a 1 point :
-- meme un gagnant tres favori doit voir *quelque chose* bouger, un delta a
-- 0 se lirait comme un bug plutot que comme "match totalement attendu".
create or replace function public.report_online_match(p_lobby_id uuid, p_i_won boolean, p_tours integer)
returns table(elo_delta integer, winner_elo_after integer, loser_elo_after integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lobby public.lobbies%rowtype;
  v_opponent uuid;
  v_winner uuid;
  v_loser uuid;
  v_winner_elo integer;
  v_loser_elo integer;
  v_expected double precision;
  v_delta integer;
  v_k constant integer := 32;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  select * into v_lobby from public.lobbies where id = p_lobby_id;
  if not found then
    raise exception 'lobby_not_found';
  end if;
  if auth.uid() <> v_lobby.joueur1 and auth.uid() <> v_lobby.joueur2 then
    raise exception 'not_a_participant';
  end if;

  v_opponent := case when auth.uid() = v_lobby.joueur1 then v_lobby.joueur2 else v_lobby.joueur1 end;
  if v_opponent is null then
    raise exception 'no_opponent';
  end if;

  v_winner := case when p_i_won then auth.uid() else v_opponent end;
  v_loser := case when p_i_won then v_opponent else auth.uid() end;

  select elo into v_winner_elo from public.profiles where id = v_winner;
  select elo into v_loser_elo from public.profiles where id = v_loser;

  v_expected := 1.0 / (1.0 + power(10.0, (v_loser_elo - v_winner_elo) / 400.0));
  v_delta := greatest(1, round(v_k * (1 - v_expected))::integer);

  update public.profiles set elo = elo + v_delta where id = v_winner;
  update public.profiles set elo = elo - v_delta where id = v_loser;

  insert into public.online_matches
    (lobby_id, winner, loser, winner_elo_before, loser_elo_before, winner_elo_after, loser_elo_after, tours)
  values
    (p_lobby_id, v_winner, v_loser, v_winner_elo, v_loser_elo, v_winner_elo + v_delta, v_loser_elo - v_delta, p_tours);

  return query select v_delta, (v_winner_elo + v_delta), (v_loser_elo - v_delta);
end;
$$;

revoke all on function public.report_online_match(uuid, boolean, integer) from public;
grant execute on function public.report_online_match(uuid, boolean, integer) to authenticated;
