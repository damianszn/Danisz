-- Danisz — step 1 schema (accounts + offline high scores)
-- Paste this whole file into the Supabase SQL editor (Project > SQL Editor > New query) and run it.
--
-- Accounts are email + password (Supabase's Email provider, on by default, no dashboard
-- toggle needed). One thing worth deciding: Authentication > Providers > Email > "Confirm
-- email". OFF = signup logs the player in immediately (matches "don't make them
-- reconnect" — lowest friction, what the client code assumes by default). ON = safer
-- (verified addresses) but adds a mandatory email-click step before first login; the
-- client code (js/account.js signUp()) already handles this case gracefully if you'd
-- rather turn it on, it just can't create the profiles row until they've confirmed and
-- signed in for the first time.
--
-- The anonymous-pseudo prototype from the previous version of this file is gone: if you
-- had "Anonymous Sign-Ins" enabled from that, it's no longer used and can be turned back
-- off.
--
-- If you already ran an earlier version of this file (without the `tours` column /
-- 2-argument record_ai_match), run this first to drop the old function signature
-- before re-running the rest below:
--   drop function if exists public.record_ai_match(text, boolean);
--
-- If you already ran the schema WITH the `tours` column (profiles/matches tables
-- already exist) and just need to add `currency`, don't re-run this whole file —
-- table creation would fail since the tables already exist. Instead run only this
-- migration, then the record_ai_match() function below (the CREATE OR REPLACE is
-- safe to re-run as-is, same 3-argument signature):
--   alter table public.profiles add column currency integer not null default 0;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  pseudo text not null unique check (char_length(pseudo) between 3 and 20),
  elo integer not null default 1000,
  parties_jouees integer not null default 0,
  victoires integer not null default 0,
  -- Monnaie in-jeu, +1 par partie terminee (peu importe le mode/la difficulte,
  -- peu importe victoire ou defaite) : un merci pour le temps investi par les
  -- premiers joueurs, pas encore affichee nulle part, en reserve pour une
  -- future feature (boutique, cosmetiques...).
  currency integer not null default 0,
  created_at timestamptz not null default now()
);

create table public.matches (
  id bigint generated always as identity primary key,
  joueur1 uuid not null references public.profiles(id) on delete cascade,
  mode text not null,
  joueur1_gagne boolean not null,
  tours integer not null,
  created_at timestamptz not null default now()
);

-- Index tailored for the upcoming "fewest turns to win, per difficulty" leaderboard.
create index matches_mode_tours_win_idx on public.matches (mode, tours) where joueur1_gagne;

alter table public.profiles enable row level security;
alter table public.matches enable row level security;

-- Leaderboard needs to be readable by everyone, logged in or not.
create policy "profiles are publicly readable"
  on public.profiles for select
  using (true);

-- Players can create their own profile row (pseudo pick), once.
create policy "users can create their own profile"
  on public.profiles for insert
  with check (auth.uid() = id);

-- Deliberately no UPDATE policy on profiles: elo/parties_jouees/victoires can only
-- change through record_ai_match() below, never by a direct client write. This is
-- the anti-cheat boundary for step 1 — a player can't just PATCH their own win count.

create policy "matches are publicly readable"
  on public.matches for select
  using (true);

-- Deliberately no INSERT policy on matches either: only the RPC can write match rows.

-- Records one offline-vs-AI match result and updates the caller's own stats,
-- atomically, as the authenticated user (works for anonymous sessions too —
-- Supabase anonymous sign-in issues a real auth.uid()). p_turns is stored per-match
-- (not aggregated onto profiles) since the eventual leaderboard needs it broken down
-- per difficulty (p_mode), which a single scalar column on profiles couldn't express.
create or replace function public.record_ai_match(p_mode text, p_won boolean, p_turns integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  insert into public.matches (joueur1, mode, joueur1_gagne, tours)
  values (auth.uid(), p_mode, p_won, p_turns);

  -- 3 dans (victoire) / 1 dan (defaite) -- meme bareme que 1v1 en ligne
  -- casual (voir report_online_match dans schema_online.sql), la victoire
  -- classee y rapportant plus (5). DOIT rester en phase avec dansEarned()
  -- cote client (index.html, juste pour l'affichage immediat du toast).
  update public.profiles
  set parties_jouees = parties_jouees + 1,
      victoires = victoires + case when p_won then 1 else 0 end,
      currency = currency + case when p_won then 3 else 1 end
  where id = auth.uid();
end;
$$;

revoke all on function public.record_ai_match(text, boolean, integer) from public;
grant execute on function public.record_ai_match(text, boolean, integer) to authenticated;

-- ---- Suppression de compte (droit a l'effacement RGPD) ----
-- Supprime la ligne auth.users du joueur connecte. profiles (FK vers
-- auth.users, on delete cascade) et par extension matches/lobbies (FK vers
-- profiles, on delete cascade elles aussi -- voir schema_online.sql) suivent
-- automatiquement : un seul point d'entree suffit, pas besoin de nettoyer
-- chaque table a la main. security definer + proprietaire du role qui
-- execute ce script (typiquement postgres, qui a les droits sur le schema
-- auth) : un role authentifie normal n'a pas le droit d'ecrire dans auth
-- directement, cette fonction lui prete ceux du proprietaire pour ce seul
-- geste, strictement limite a auth.uid() (jamais un id fourni par le client).
create or replace function public.delete_user()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  delete from auth.users where id = auth.uid();
end;
$$;

revoke all on function public.delete_user() from public;
grant execute on function public.delete_user() to authenticated;

/* =========================================================
   Bannieres joueur (cosmetique, boutique). Une banniere = 2
   emojis (gauche/droite du pseudo) + une couleur de fond derriere le nom,
   visible par l'adversaire en 1v1 en ligne et sur son propre profil.
   Catalogue fixe cote CLIENT (index.html, BANNER_CATALOG) -- pas de table
   dediee, juste un id text -- mais le PRIX reste cote SERVEUR ici (jamais
   fourni par le client) pour ne pas pouvoir tricher en passant un prix a 0.
   ========================================================= */

alter table public.profiles add column owned_banners text[] not null default '{}';
alter table public.profiles add column equipped_banner text;

-- Achete une banniere avec la monnaie in-jeu (profiles.currency, +1 par
-- partie terminee, voir record_ai_match/report_online_match) : verifie le
-- solde et l'absence de doublon cote serveur, jamais fait confiance au
-- client pour le prix -- catalogue duplique ici volontairement (voir le
-- meme catalogue cote client dans index.html, BANNER_CATALOG) puisqu'il
-- n'y a pas de table banners partagee.
-- Vrai si p_uid detient au moins 1 medaille d'or (1er, classement "dense" --
-- ex-aequo inclus) sur au moins un des 4 classements par difficulte (voir
-- fetchMyMedals()/fetchModeLeaderboard() dans js/account.js pour la version
-- cote client, utilisee pour l'AFFICHAGE -- celle-ci est la verification
-- SERVEUR, seule habilitee a conditionner un achat, jamais un calcul refait
-- cote client). Se contente de LIRE matches (deja public en lecture, voir
-- policy "matches are publicly readable" plus haut) : ne consomme ni ne
-- modifie jamais aucune medaille, purement une condition d'eligibilite.
create or replace function public.player_has_gold_medal(p_uid uuid)
returns boolean
language sql
stable
set search_path = public
as $$
  with best_per_player as (
    select mode, joueur1, min(tours) as best_tours
    from public.matches
    where joueur1_gagne
    group by mode, joueur1
  ),
  best_per_mode as (
    select mode, min(best_tours) as top_tours
    from best_per_player
    group by mode
  )
  select exists (
    select 1
    from best_per_player bp
    join best_per_mode bm on bm.mode = bp.mode and bm.top_tours = bp.best_tours
    where bp.joueur1 = p_uid
  );
$$;

revoke all on function public.player_has_gold_medal(uuid) from public;
grant execute on function public.player_has_gold_medal(uuid) to authenticated;

create or replace function public.purchase_banner(p_banner_id text)
returns table(new_currency integer, owned_banners text[])
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_price integer;
  v_currency integer;
  v_owned text[];
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  v_price := case p_banner_id
    when 'flame' then 5
    when 'skull' then 5
    when 'snake' then 6
    when 'shark' then 8
    when 'sun' then 30
    -- Gratuite, mais reservee a qui a au moins 1 medaille d'or (voir
    -- player_has_gold_medal ci-dessus) -- verifiee juste apres, jamais
    -- juste "gratuite pour tous".
    when 'crown' then 0
    when 'diamond' then 15
    else null
  end;
  if v_price is null then
    raise exception 'unknown_banner';
  end if;

  if p_banner_id = 'crown' and not public.player_has_gold_medal(v_uid) then
    raise exception 'condition_not_met';
  end if;

  -- Alias "p" partout ci-dessous (public.profiles p / p.owned_banners) :
  -- le nom de colonne en sortie de la fonction (returns table(...,
  -- owned_banners text[]) plus haut) cree une variable PL/pgSQL implicite
  -- du meme nom, qui rentre alors en collision avec la vraie colonne
  -- profiles.owned_banners des qu'on la reference sans qualifier -- erreur
  -- Postgres 42702 "column reference is ambiguous", observee en test reel.
  select p.currency, p.owned_banners into v_currency, v_owned from public.profiles p where p.id = v_uid;
  if v_owned @> array[p_banner_id] then
    raise exception 'already_owned';
  end if;
  if v_currency < v_price then
    raise exception 'not_enough_currency';
  end if;

  update public.profiles p
  set currency = p.currency - v_price, owned_banners = array_append(p.owned_banners, p_banner_id)
  where p.id = v_uid;

  select p.currency, p.owned_banners into v_currency, v_owned from public.profiles p where p.id = v_uid;
  return query select v_currency, v_owned;
end;
$$;

-- Equipe (ou retire, p_banner_id null) une banniere DEJA possedee.
create or replace function public.equip_banner(p_banner_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_owned text[];
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  if p_banner_id is not null then
    select owned_banners into v_owned from public.profiles where id = v_uid;
    if not (v_owned @> array[p_banner_id]) then
      raise exception 'not_owned';
    end if;
  end if;
  update public.profiles set equipped_banner = p_banner_id where id = v_uid;
end;
$$;

revoke all on function public.purchase_banner(text) from public;
revoke all on function public.equip_banner(text) from public;
grant execute on function public.purchase_banner(text) to authenticated;
grant execute on function public.equip_banner(text) to authenticated;

/* =========================================================
   Jeux de cartes (cosmetique, boutique). Remplace les 13x4 images de
   rang+suit affichees en partie (voir CARD_DECK_CATALOG + MainScene.texKey()
   dans index.html, assets/cards/decks/<id>/<lettre suit>/<fichier>.png).
   Meme modele que les bannieres ci-dessus : catalogue fixe cote CLIENT
   (affichage uniquement), PRIX toujours cote SERVEUR ici.
   ========================================================= */

alter table public.profiles add column owned_card_decks text[] not null default '{}';
alter table public.profiles add column equipped_card_deck text;

create or replace function public.purchase_card_deck(p_deck_id text)
returns table(new_currency integer, owned_card_decks text[])
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_price integer;
  v_currency integer;
  v_owned text[];
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  v_price := case p_deck_id
    when 'deckerbw' then 100
    when 'kerenelpixel' then 80
    when 'cards2sobre' then 111
    when 'defaultgreen' then 20
    when 'defaultgold' then 50
    else null
  end;
  if v_price is null then
    raise exception 'unknown_deck';
  end if;

  -- Alias "p" partout ci-dessous : meme raison que purchase_banner()
  -- plus haut (colonne de sortie owned_card_decks en collision avec la
  -- variable PL/pgSQL implicite du meme nom -- erreur 42702 ambiguous).
  select p.currency, p.owned_card_decks into v_currency, v_owned from public.profiles p where p.id = v_uid;
  if v_owned @> array[p_deck_id] then
    raise exception 'already_owned';
  end if;
  if v_currency < v_price then
    raise exception 'not_enough_currency';
  end if;

  update public.profiles p
  set currency = p.currency - v_price, owned_card_decks = array_append(p.owned_card_decks, p_deck_id)
  where p.id = v_uid;

  select p.currency, p.owned_card_decks into v_currency, v_owned from public.profiles p where p.id = v_uid;
  return query select v_currency, v_owned;
end;
$$;

-- Equipe (ou retire, p_deck_id null) un deck DEJA possede.
create or replace function public.equip_card_deck(p_deck_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_owned text[];
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  if p_deck_id is not null then
    select owned_card_decks into v_owned from public.profiles where id = v_uid;
    if not (v_owned @> array[p_deck_id]) then
      raise exception 'not_owned';
    end if;
  end if;
  update public.profiles set equipped_card_deck = p_deck_id where id = v_uid;
end;
$$;

revoke all on function public.purchase_card_deck(text) from public;
revoke all on function public.equip_card_deck(text) from public;
grant execute on function public.purchase_card_deck(text) to authenticated;
grant execute on function public.equip_card_deck(text) to authenticated;
