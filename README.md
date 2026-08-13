# Danisz

Jeu de cartes Shithead (variante "Danisz"), 1v1 contre l'IA, en Phaser 3 — 100% front-end, aucun serveur necessaire.

## Publier sur GitHub Pages

1. Cree un nouveau repo sur GitHub (public, pas besoin de cocher "Add a README").
2. Sur ta machine, dans ce dossier (`shithead-game`), lance :
   ```
   git init
   git add .
   git commit -m "Premier commit"
   git branch -M main
   git remote add origin https://github.com/TON-PSEUDO/NOM-DU-REPO.git
   git push -u origin main
   ```
   (Remplace `TON-PSEUDO` et `NOM-DU-REPO` par les tiens. GitHub te donne l'URL exacte a coller a la creation du repo.)
3. Sur la page du repo : **Settings** -> **Pages** (dans le menu de gauche).
4. Sous "Build and deployment", choisis **Deploy from a branch**, branche **main**, dossier **/ (root)**, puis **Save**.
5. Attends 1-2 minutes, GitHub affiche l'URL publique en haut de cette meme page (du genre `https://ton-pseudo.github.io/nom-du-repo/`).

Alternative sans ligne de commande : sur la page du repo fraichement cree, clique **uploading an existing file**, glisse `index.html` et le dossier `assets/` (garde bien la structure de dossiers), commit, puis fais les etapes 3-5 ci-dessus.

## Structure

```
index.html          -> tout le jeu (moteur de regles + rendu Phaser + i18n)
assets/table.jpeg    -> plateau
assets/cards/        -> sprites des cartes (dos + 13 rangs)
```

Aucune dependance a installer : Phaser et les polices (Google Fonts) sont charges depuis un CDN directement dans `index.html`.
