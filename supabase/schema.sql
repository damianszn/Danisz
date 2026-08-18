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

  update public.profiles
  set parties_jouees = parties_jouees + 1,
      victoires = victoires + case when p_won then 1 else 0 end,
      currency = currency + 1
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
