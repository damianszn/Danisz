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
